import AppKit

/// What the system says is playing, and where it has got to.
///
/// The position is not asked for repeatedly. MediaRemote gives an anchor —
/// the elapsed time as of a particular instant — and the wall clock carries it
/// forward from there. A progress bar can therefore animate at any frame rate
/// it likes without another call, which is what keeps this cheap.
struct NowPlaying: Equatable {
    var title: String?
    var artist: String?
    var appBundleID: String?
    var appName: String?
    var duration: Double = 0
    var anchorElapsed: Double = 0
    var anchorAt: Double = 0
    var rate: Double = 0
    var hasArtwork = false
    /// Transport codes the app said it answers. Anything absent is a control
    /// the page never registered, so the button for it stays dark.
    var commands: Set<Int> = []

    func supports(_ command: NowPlayingSource.Command) -> Bool {
        commands.isEmpty || commands.contains(command.rawValue)
    }

    /// The command that gets you the state the button is offering.
    var playPauseCommand: NowPlayingSource.Command { isPlaying ? .pause : .play }

    var isPlaying: Bool { rate > 0 }

    /// Where playback is right now, carried from the anchor.
    var position: Double {
        guard anchorAt > 0 else { return anchorElapsed }
        let carried = anchorElapsed + (Date().timeIntervalSince1970 - anchorAt) * rate
        guard duration > 0 else { return max(carried, 0) }
        return min(max(carried, 0), duration)
    }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return position / duration
    }

    /// The publishing app's icon, so the bar says what it is showing without
    /// spending any width on the name.
    var appIcon: NSImage? {
        guard let id = appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Runs the Now Playing helper and hands back what it read.
///
/// The helper is a dylib loaded into `/usr/bin/python3` rather than a tool of
/// our own: MediaRemote answers Apple-signed interpreters and returns nothing
/// to everything else. Each read costs about twenty milliseconds, and because
/// the anchor makes the position self-advancing, reads are needed only often
/// enough to notice a track change — not to animate.
final class NowPlayingSource {

    private let helperPath: String?
    private var inFlight = false
    private var artworkKey: String?
    private var artworkImage: NSImage?
    private var artworkInFlight = false

    init(bundle: Bundle) {
        helperPath = bundle.path(forResource: "libnowplaying", ofType: "dylib")
    }

    /// Reads once. Nothing stays resident: every interpreter able to reach
    /// MediaRemote has to load Foundation and AppKit with it, which is a
    /// seventeen-megabyte floor no choice of language gets under. Spending a
    /// little CPU on demand is the cheaper trade when the machine has cores to
    /// spare and memory it would rather keep.
    func read(completion: @escaping (NowPlaying?) -> Void) {
        guard !inFlight, let helperPath else { return }
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = Self.parse(Self.callHelper(helperPath, symbol: "snapshot"))
            DispatchQueue.main.async {
                self?.inFlight = false
                completion(state)
            }
        }
    }

    /// The current track's cover, at most once per track.
    ///
    /// Artwork is tens of kilobytes and constant for as long as the track is,
    /// so it is keyed on the track and kept until that changes. Nothing calls
    /// this while the bar is collapsed: there is nowhere to show a cover in a
    /// ring, so the bytes would be fetched to be thrown away.
    func artwork(for state: NowPlaying, completion: @escaping (NSImage?) -> Void) {
        let key = [state.title, state.artist].compactMap { $0 }.joined(separator: "\u{1f}")
        if key == artworkKey { completion(artworkImage); return }
        guard state.hasArtwork, !artworkInFlight, let helperPath else { completion(nil); return }
        artworkInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.callHelper(helperPath, symbol: "artwork")
            var image: NSImage?
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let encoded = object["artwork"] as? String,
               let bytes = Data(base64Encoded: encoded) {
                image = NSImage(data: bytes)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.artworkInFlight = false
                self.artworkKey = key
                self.artworkImage = image
                completion(image)
            }
        }
    }

    /// Runs one of the helper's exports and hands back the line it printed.
    ///
    /// Perl, not Python, for the paths that run on a timer: its interpreter
    /// starts in about four milliseconds against Python's nineteen, which on a
    /// reading that costs eighteen in total is most of the difference.
    /// Commands still go through Python below — Perl's `dl_install_xsub`
    /// cannot pass arguments to a plain C function, and a command runs only
    /// when a button is pressed.
    private static func callHelper(_ helperPath: String, symbol: String) -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [
            "-e",
            """
            use DynaLoader;
            my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1;
            my $sym = DynaLoader::dl_find_symbol($lib, $ARGV[1]) or exit 1;
            DynaLoader::dl_install_xsub("main::run", $sym);
            run();
            """,
            helperPath,
            symbol,
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return Data() }

        // Neither `readDataToEndOfFile` nor `waitUntilExit` has a deadline of
        // its own, and the caller holds an `inFlight` flag across both. One
        // wedged interpreter would therefore stop the bar updating for the rest
        // of the session with nothing to recover it. A reading takes about
        // eighty milliseconds; two seconds means something is wrong, and
        // killing it closes the pipe so the read below returns.
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        return data
    }

    /// MediaRemote's own transport codes.
    ///
    /// Play and pause are used in preference to toggle. Toggle flips whatever
    /// the state happens to be, so a stale reading — and readings are up to ten
    /// seconds old while the bar is collapsed — can flip it the wrong way. The
    /// directional pair is idempotent: pressing play on something already
    /// playing leaves it playing, so the worst a stale belief costs is a
    /// redundant command rather than the opposite of what was asked for.
    enum Command: Int {
        case play = 0, pause = 1, next = 4, previous = 5
    }

    /// Commands go through the same interpreter host as reads, for the same
    /// reason: MediaRemote ignores anything else.
    func send(_ command: Command) {
        call("s.command(\(command.rawValue))")
    }

    /// Declaring `argtypes` is not optional: without it ctypes passes the
    /// offset as an int and the helper seeks to nonsense.
    func seek(to seconds: Double) {
        call("s.seekTo.argtypes = [ctypes.c_double]; s.seekTo(\(seconds))")
    }

    private func call(_ body: String) {
        guard let helperPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            // `body` is the whole statement, not a suffix. It used to be
            // pasted after an "s." here, which silently turned the seek into
            // `s.s.seekTo` — a lookup for a symbol named "s" that threw before
            // anything was sent, into a stderr going to /dev/null.
            task.arguments = ["-c", "import ctypes; s = ctypes.CDLL(\"\(helperPath)\"); \(body)"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    private static func parse(_ data: Data) -> NowPlaying? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              object["playing"] as? Bool == true else { return nil }

        var state = NowPlaying()
        state.title = object["title"] as? String
        state.artist = object["artist"] as? String
        state.appBundleID = object["app"] as? String
        state.appName = object["appname"] as? String
        state.duration = object["duration"] as? Double ?? 0
        state.anchorElapsed = object["elapsedtime"] as? Double ?? 0
        state.anchorAt = object["anchor"] as? Double ?? 0
        state.rate = object["playbackrate"] as? Double ?? 0
        state.hasArtwork = (object["artworkbytes"] as? Int ?? 0) > 0
        state.commands = Set((object["commands"] as? [Int]) ?? [])
        return state
    }
}
