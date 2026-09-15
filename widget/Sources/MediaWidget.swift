import AppKit
import PockKit

/// Whatever is playing, on the Touch Bar.
///
/// Nothing here knows about any particular application. It reads the system's
/// Now Playing session, so a browser, a music app or a video player all show up
/// the same way — and an app that starts playing takes over the bar without any
/// code being added for it.
public final class MediaWidget: NSObject, PKWidget {

    @available(*, deprecated, message: "Identifier is read from the bundle's Info.plist")
    public static var identifier: String = "com.captainyyds.mediabar"

    @objc public var identifier: NSTouchBarItem.Identifier = NSTouchBarItem.Identifier("com.captainyyds.mediabar")
    public var customizationLabel = "Media Bar"
    public var view: NSView!

    private static weak var shared: MediaWidget?

    /// One timer, ticking every second. The tick itself is free — it redraws
    /// the bar from the anchor with no call to anything — and a counter decides
    /// how often a tick also pays for a reading.
    private static let tickInterval: TimeInterval = 1.0

    /// A reading costs about eighteen milliseconds of CPU and nothing at rest.
    ///
    /// None of it buys the progress bar: the position is carried from the
    /// anchor by arithmetic, at whatever rate the bar redraws. A reading is
    /// only how a change made somewhere else — a track ending, a pause pressed
    /// in the app — gets noticed. Measured, once a second while expanded came
    /// to 1.8% of a core against 0.32% for everything the widget actually drew,
    /// so the frequency was nearly the whole cost and bought three seconds of
    /// latency on an event that is rare. Commands pressed here still confirm
    /// themselves after 0.45s and do not wait for this.
    private static let activeTicks = 3
    private static let restingTicks = 10

    private let barView: MediaBarView
    private let source: NowPlayingSource
    private var timer: Timer?
    private var lastKnown: NowPlaying?
    private var ticksSinceRead = 0

    override public required init() {
        barView = MediaBarView(frame: NSRect(x: 0, y: 0, width: MediaBarView.collapsedWidth, height: 30))
        source = NowPlayingSource(bundle: Bundle(for: MediaBarView.self))
        super.init()
        view = barView
        // Pock builds more than one instance of a widget over a session — the
        // bar and the customisation palette each get one, and re-presenting the
        // bar makes another. Only the newest may read: an older instance whose
        // view is long gone still owns a live timer, and each one was paying
        // for its own helper call on its own schedule, against its own empty
        // cache. Two instances doubled the cost; three tripled it.
        MediaWidget.shared?.stop()
        MediaWidget.shared = self


        barView.onToggleExpand = { [weak self] in
            guard let self else { return }
            self.barView.setExpanded(!self.barView.isExpanded)
            self.read()
        }
        barView.onPlayPause = { [weak self] in
            guard let self else { return }
            self.act(self.lastKnown?.playPauseCommand ?? .play)
        }
        barView.onNext = { [weak self] in self?.act(.next) }
        barView.onPrevious = { [weak self] in self?.act(.previous) }
        barView.onArtworkNeeded = { [weak self] in self?.refreshArtwork() }
        // Volume answers immediately and then confirms, same as transport: the
        // system is the authority, but the glyph should not wait on it.
        barView.onToggleMute = { [weak self] in
            SystemVolume.toggleMute()
            self?.barView.refreshVolumeState()
        }
        barView.onSetVolume = { level in
            // Setting a level is also unmuting: a slider that moves while the
            // output stays silent is a control that lies.
            if SystemVolume.isMuted, level > 0 { SystemVolume.setMuted(false) }
            SystemVolume.setLevel(level)
        }
        barView.onScrub = { [weak self] fraction in
            guard let self, let duration = self.lastKnown?.duration, duration > 0 else { return }
            self.source.seek(to: duration * fraction)
        }
    }

    // MARK: Lifecycle

    // All four, not the two that looked sufficient. `PKWidget` declares the
    // full set and Pock uses `viewWillDisappear` on some teardown paths, so a
    // widget that only answers `viewDidDisappear` is never told to stop on
    // those — which is how an instance whose view was long gone kept its timer
    // running and its readings going.
    @objc public static func viewWillAppear() { shared?.start() }
    @objc public static func viewDidAppear() { shared?.start() }
    @objc public static func viewWillDisappear() { shared?.stop() }
    @objc public static func viewDidDisappear() { shared?.stop() }
    @objc public func viewWillAppear() { start() }
    @objc public func viewDidAppear() { start() }
    @objc public func viewWillDisappear() { stop() }
    @objc public func viewDidDisappear() { stop() }

    private var healedControlStrip = false

    private func start() {
        // Idempotent: Pock sends both `viewWillAppear` and `viewDidAppear` for
        // one appearance, and starting twice would pay for two readings and
        // leave the second timer to be cancelled by the first line.
        guard timer == nil else { return }
        // Pock may have been quit while the bar was open, which would leave the
        // Control Strip hidden with nothing expanded to justify it. Put the
        // style back in step with the shape — but once the bar is up, and
        // through the live path.
        //
        // This used to run from `init`, which asked Pock to rebuild before it
        // had finished building. Pock makes a fresh widget for every
        // presentation and never tells the discarded one its view is gone, so
        // the previous generation stayed alive with its timer still running:
        // measured at two instances after one reload, each reading on its own
        // schedule against its own empty cache.
        if !healedControlStrip {
            healedControlStrip = true
            let expanded = barView.isExpanded
            DispatchQueue.main.async { MediaBarView.setControlStripHidden(expanded) }
        }
        read()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            // Belt as well as braces: a timer that outlives its turn as the
            // current instance does nothing rather than reading in the dark.
            guard let self, MediaWidget.shared === self else { return }
            self.barView.tick()
            self.ticksSinceRead += 1
            if self.ticksSinceRead >= self.readEveryTicks { self.read() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Fast only when it would be seen: open, and playing.
    private var readEveryTicks: Int {
        let playing = lastKnown?.isPlaying ?? false
        return (barView.isExpanded && playing) ? Self.activeTicks : Self.restingTicks
    }

    private func read() {
        ticksSinceRead = 0
        source.read { [weak self] state in
            guard let self else { return }
            self.lastKnown = state
            self.barView.apply(state)
            self.refreshArtwork()
        }
    }

    /// The cover, in both shapes: it fills the ring when collapsed and sits
    /// beside the transport when expanded, so it is worth having either way.
    /// The source keeps it per track, so this costs one reading per track
    /// change rather than one per call.
    private func refreshArtwork() {
        guard let state = lastKnown else { return }
        source.artwork(for: state) { [weak self] image in self?.barView.setArtwork(image) }
    }

    private func act(_ command: NowPlayingSource.Command) {
        // Show the new state at once rather than after the round trip. The
        // confirming read corrects it a moment later if the app disagrees, but
        // the button no longer feels dead on press.
        if command == .play || command == .pause {
            barView.showPlaying(command == .play)
        }
        source.send(command)
        // No subscription now, so confirm the app agreed rather than letting
        // the optimistic glyph stand unchecked until the next reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.read() }
    }
}
