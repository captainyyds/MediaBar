import AppKit
import ObjectiveC
import PockKit
import QuartzCore

/// Two shapes for the same thing.
///
/// Collapsed it is the cover inside a ring that fills as the track plays: one
/// glyph's worth of bar, so it can sit beside other widgets without crowding
/// them. Expanded it takes the whole strip and lays itself out the way the
/// system's own media controls do — transport at the left, cover, then a tall
/// rounded track between the elapsed and remaining clocks. The choice sticks,
/// because it is a preference about how much room you are willing to give it,
/// not a reaction to what is playing.
final class MediaBarView: NSView {

    /// What the bar asks for before it has been told better.
    ///
    /// The Touch Bar does NOT clamp an over-wide item: it lays the view out at
    /// whatever width was asked for and simply draws the part that fits, so a
    /// track sized to an imaginary width reports the wrong position for every
    /// point along it. The real width has to be asked for — see
    /// `adoptBarWidth()` — and this is only the opening guess, measured on a
    /// 13" Touch Bar with the Control Strip showing.
    static var expandedWidth: CGFloat = 685

    /// The widest Pock region seen so far.
    ///
    /// Expanding always takes the Control Strip, so the width to open at is the
    /// wide one — and the window is not reliably answering at the moment the
    /// toggle happens. Remembering what it said last time is better than
    /// falling back to a guess that is 319pt short.
    private static var widestSeen: CGFloat = 685
    static let collapsedWidth: CGFloat = 34

    /// A track you can hit without looking. The hairline this replaced was 4pt
    /// tall and pinned to the bottom edge, which is the hardest thing to touch
    /// on a strip this short.
    private static let trackHeight: CGFloat = 18
    private static let ringSize: CGFloat = 26
    /// The stroked ring's length, for deciding when a change would show.
    private static let ringCircumference: CGFloat = (ringSize - 3) * .pi
    /// A pill rather than a dot: it reads as a playhead at a glance and gives
    /// the finger a whole column to land on instead of a point.
    private static let knobWidth: CGFloat = 6
    private static let knobHeight: CGFloat = 22
    /// Touch targets, not mouse targets. 26pt was too fine to hit without
    /// looking, which on a bar you glance at is the whole problem.
    private static let control: CGFloat = 44
    private static let inset: CGFloat = 4
    private static let artSize: CGFloat = 24
    private static let clockWidth: CGFloat = 42
    private static let gap: CGFloat = 6
    private static let muteWidth: CGFloat = 40
    private static let volumeWidth: CGFloat = 90
    private static let volumeTrackHeight: CGFloat = 8
    private static let volumeKnobSize: CGFloat = 14

    // MARK: Callbacks

    var onToggleExpand: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// Fraction of the track tapped or dragged to, for seeking.
    var onScrub: ((Double) -> Void)?
    /// Raised when a drag starts, in case the cover has not been fetched yet.
    var onArtworkNeeded: (() -> Void)?
    /// Where along the volume slider the finger is, 0…1.
    var onSetVolume: ((Float) -> Void)?
    var onToggleMute: (() -> Void)?

    // MARK: Views

    private let collapseIcon = NSImageView(frame: .zero)
    private let previousIcon = NSImageView(frame: .zero)
    private let playIcon = NSImageView(frame: .zero)
    private let nextIcon = NSImageView(frame: .zero)
    /// The cover if the app publishes one, the app's own icon if it does not.
    /// For video this is the poster frame, which is as close to Safari's strip
    /// of thumbnails as anything outside the playing app can get.
    private let artView = NSImageView(frame: .zero)
    /// Volume lives here rather than in the Control Strip, because expanded
    /// the bar covers the whole strip and the Control Strip is not there to
    /// fall back on.
    private let muteIcon = NSImageView(frame: .zero)
    private let volumeTrack = CALayer()
    private let volumeFill = CALayer()
    private let volumeKnob = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()
    private let ringTrack = CAShapeLayer()
    private let ringFill = CAShapeLayer()

    private var state: NowPlaying?
    /// Which of the two tracks a finger is currently on, if either.
    private enum DragTarget { case scrub, volume }
    private var dragTarget: DragTarget?
    /// Non-nil only while a finger is down on the scrub track: where the drag
    /// has got to, which the bar shows in place of where playback actually is.
    private var dragFraction: Double?
    /// The sweep the ring was last actually drawn at. Negative forces the next
    /// tick to draw regardless.
    private var drawnRingFraction: CGFloat = -1
    private var cover: NSImage?
    private var appFallback: NSImage?
    private var supportsPrevious = false
    private var supportsNext = false
    private(set) var isExpanded: Bool
    private(set) var presentationWidth: CGFloat

    override init(frame frameRect: NSRect) {
        isExpanded = UserDefaults.standard.bool(forKey: "MediaBarExpanded")
        presentationWidth = isExpanded ? Self.expandedWidth : Self.collapsedWidth
        super.init(frame: frameRect)
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)

        // One weight and one point size across all four, so they read as a set
        // rather than four glyphs that happen to sit next to each other.
        configure(collapseIcon, "arrow.down.right.and.arrow.up.left", alpha: 0.75)
        configure(previousIcon, "backward.fill", alpha: 0.9)
        configure(playIcon, "pause.fill", alpha: 1)
        configure(nextIcon, "forward.fill", alpha: 0.9)
        configure(muteIcon, "speaker.wave.2.fill", alpha: 0.9)

        // Lighter than the scrub track on purpose: two tracks of equal weight
        // side by side read as one control split in half.
        volumeTrack.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        volumeTrack.cornerRadius = Self.volumeTrackHeight / 2
        volumeTrack.masksToBounds = true
        volumeFill.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.75).cgColor
        volumeTrack.addSublayer(volumeFill)
        volumeKnob.backgroundColor = NSColor.white.cgColor
        volumeKnob.cornerRadius = Self.volumeKnobSize / 2
        volumeKnob.shadowColor = NSColor.black.cgColor
        volumeKnob.shadowOpacity = 0.5
        volumeKnob.shadowRadius = 2
        volumeKnob.shadowOffset = .zero

        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.wantsLayer = true
        artView.layer?.masksToBounds = true

        // The title rides on the track, so the fill runs behind it rather than
        // the two competing for the middle of the bar.
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.alignment = .center
        titleLabel.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            return shadow
        }()

        for clock in [elapsedLabel, remainingLabel] {
            clock.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            clock.textColor = NSColor(calibratedWhite: 1, alpha: 0.6)
            clock.usesSingleLineMode = true
        }
        elapsedLabel.alignment = .right
        remainingLabel.alignment = .left

        track.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        track.cornerRadius = Self.trackHeight / 2
        track.masksToBounds = true
        fill.backgroundColor = NSColor.systemBlue.cgColor
        track.addSublayer(fill)

        for ring in [ringTrack, ringFill] {
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 3
            ring.lineCap = .round
        }
        ringTrack.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.2).cgColor
        ringFill.strokeColor = NSColor.systemBlue.cgColor
        ringFill.strokeEnd = 0

        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = Self.knobWidth / 2
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.5
        knob.shadowRadius = 2
        knob.shadowOffset = .zero

        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        layer?.addSublayer(volumeTrack)
        layer?.addSublayer(volumeKnob)
        layer?.addSublayer(ringTrack)
        layer?.addSublayer(ringFill)
        [collapseIcon, previousIcon, playIcon, nextIcon, artView,
         titleLabel, elapsedLabel, remainingLabel, muteIcon].forEach(addSubview)

        let tap = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)

        // A pan, not just a tap, so the position can be chosen by ear: the bar
        // follows the finger and only commits on release.
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = .direct
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let glyphSize: CGFloat = 20
    private static let glyphPointSize: CGFloat = 14

    private func configure(_ view: NSImageView, _ symbol: String, alpha: CGFloat) {
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.glyphPointSize, weight: .medium))
        view.contentTintColor = NSColor(calibratedWhite: 1, alpha: alpha)
        view.imageScaling = .scaleProportionallyDown
    }

    override var intrinsicContentSize: NSSize { NSSize(width: presentationWidth, height: 30) }

    // MARK: Geometry

    /// Where the transport buttons and the elapsed clock end.
    private var trackLeft: CGFloat {
        Self.inset + Self.glyphSize + 2 + Self.control * 3 + Self.gap + Self.artSize + Self.gap
            + Self.clockWidth + Self.gap
    }

    /// Where the volume controls begin: mute, then the slider.
    private var volumeLeft: CGFloat {
        bounds.width - Self.inset - Self.muteWidth - Self.gap - Self.volumeWidth
    }

    private var volumeSliderFrame: CGRect {
        CGRect(
            x: volumeLeft + Self.muteWidth + Self.gap,
            y: (bounds.height - Self.volumeTrackHeight) / 2,
            width: Self.volumeWidth, height: Self.volumeTrackHeight
        )
    }

    private var trackRight: CGFloat { volumeLeft - Self.gap - Self.clockWidth - Self.gap }

    private var trackFrame: CGRect {
        CGRect(
            x: trackLeft, y: (bounds.height - Self.trackHeight) / 2,
            width: max(trackRight - trackLeft, 20), height: Self.trackHeight
        )
    }

    // MARK: Content

    func apply(_ next: NowPlaying?) {
        state = next
        let playing = next?.isPlaying ?? false
        playIcon.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))

        // Dim rather than hide: the layout stays put as you move between
        // apps, and a dark button reads as "not offered here" instead of
        // "broken".
        previousIcon.alphaValue = next?.supports(.previous) ?? false ? 1 : 0.25
        nextIcon.alphaValue = next?.supports(.next) ?? false ? 1 : 0.25
        supportsPrevious = next?.supports(.previous) ?? false
        supportsNext = next?.supports(.next) ?? false

        if let next {
            appFallback = next.appIcon
            titleLabel.stringValue = [next.title, next.artist].compactMap { $0 }.joined(separator: " — ")
        } else {
            appFallback = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            cover = nil
            titleLabel.stringValue = "Nothing playing"
        }
        showArt()
        refreshVolumeState()
        let accent = (next == nil || !playing) ? NSColor.systemGray : NSColor.systemBlue
        fill.backgroundColor = accent.cgColor
        ringFill.strokeColor = accent.cgColor
        needsLayout = true
        drawnRingFraction = -1
        tick()
    }

    /// The cover for the current track, once it has been fetched.
    func setArtwork(_ image: NSImage?) {
        cover = image
        showArt()
    }

    private func showArt() { artView.image = cover ?? appFallback }

    /// The mute glyph says what pressing it will undo, so it has to follow the
    /// system rather than only its own presses — the volume keys and other
    /// apps change this too.
    func refreshVolumeState() {
        let muted = SystemVolume.isMuted
        muteIcon.image = NSImage(
            systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: Self.glyphPointSize, weight: .medium))
        muteIcon.contentTintColor = muted
            ? NSColor.systemOrange
            : NSColor(calibratedWhite: 1, alpha: 0.9)
        // A finger on the slider outranks the system: re-reading mid-drag would
        // fight whoever is holding it.
        guard dragTarget != .volume else { return }
        drawVolume(muted ? 0 : (SystemVolume.level ?? 0))
    }

    private func drawVolume(_ level: Float) {
        guard isExpanded else { return }
        let box = volumeSliderFrame
        let value = CGFloat(min(max(level, 0), 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        volumeFill.frame = CGRect(x: 0, y: 0, width: box.width * value, height: box.height)
        let size = Self.volumeKnobSize
        volumeKnob.frame = CGRect(
            x: min(max(box.minX + box.width * value - size / 2, box.minX - 1), box.maxX - size + 1),
            y: (bounds.height - size) / 2, width: size, height: size
        )
        CATransaction.commit()
    }

    /// Advances from the anchor. Pure local arithmetic, no system call.
    func tick() {
        // A drag wins over playback: while a finger is down the bar shows where
        // it is going, not where the track has got to.
        let fraction = CGFloat(dragFraction ?? state?.fraction ?? 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isExpanded {
            let box = trackFrame
            fill.frame = CGRect(x: 0, y: 0, width: box.width * fraction, height: box.height)
            // At rest the boundary between the filled and unfilled halves is
            // the position indicator, and a white pill on top of it only gets
            // in the way — it lands in the middle of a word as often as not.
            // It appears under the finger instead, where the title has dimmed
            // to make room for it.
            knob.isHidden = dragFraction == nil
            let width = Self.knobWidth + 4
            let centre = box.minX + box.width * fraction
            knob.frame = CGRect(
                x: min(max(centre - width / 2, box.minX), box.maxX - width),
                y: (bounds.height - Self.knobHeight) / 2,
                width: width, height: Self.knobHeight
            )
            knob.cornerRadius = width / 2
        } else if abs(fraction - drawnRingFraction) * Self.ringCircumference >= 0.5 {
            // Changing `strokeEnd` re-strokes the whole path, and costs the
            // same whether anyone can see the difference or not. On a track of
            // any length a second of playback moves the ring by a fraction of
            // a point — 0.02pt on an hour-long stream — so the ring is only
            // asked to move once the movement would be visible. Nothing is
            // lost: the sweep still tracks the anchor exactly, it just stops
            // redrawing to say the same thing.
            drawnRingFraction = fraction
            ringFill.strokeEnd = fraction
        }
        CATransaction.commit()

        guard isExpanded else { return }
        guard let state, state.duration > 0 else {
            elapsedLabel.stringValue = ""
            remainingLabel.stringValue = ""
            return
        }
        let shown = dragFraction.map { $0 * state.duration } ?? state.position
        elapsedLabel.stringValue = Self.clock(shown)
        remainingLabel.stringValue = "-" + Self.clock(state.duration - shown)
    }

    /// Flips the play glyph ahead of confirmation, so a press reads as heard.
    func showPlaying(_ playing: Bool) {
        playIcon.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        UserDefaults.standard.set(expanded, forKey: "MediaBarExpanded")
        presentationWidth = expanded ? Self.widestSeen : Self.collapsedWidth
        Self.setControlStripHidden(expanded)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
    }

    /// Takes the Control Strip only while the bar is open, and gives it back on
    /// the way out.
    ///
    /// Pock's own layout style decides whether the strip is there, and this
    /// widget runs inside Pock, so its standard defaults *are* Pock's. Writing
    /// the style is therefore half the job; the other half is making Pock act
    /// on it, and there are two ways to do that.
    ///
    /// - parameter live: re-present the bar in place. Pock decides whether the
    ///   Control Strip shares the strip at the moment it presents, so
    ///   dismissing and presenting the *same* `NSTouchBar` — same object, same
    ///   items, same views — changes the layout with nothing rebuilt. Posting
    ///   `shouldReloadPock` also works but tears down and recreates every
    ///   widget, which is what makes the toggle flicker. Pass `false` at
    ///   start-up, when there is no bar to re-present yet and a rebuild costs
    ///   nothing anyway.
    static func setControlStripHidden(_ hidden: Bool, live: Bool = true) {
        let style = hidden ? "fullWidth" : "withControlStrip"
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "layoutStyle") != style else { return }
        defaults.set(style, forKey: "layoutStyle")
        if live, present(placement: hidden ? 1 : 0) { return }
        NotificationCenter.default.post(name: NSNotification.Name("shouldReloadPock"), object: nil)
    }

    /// Shows Pock's own Touch Bar again at the given placement.
    ///
    /// Placement is the entire difference between the two layouts — 0 shares
    /// the strip with the Control Strip, 1 takes all of it — and nothing is
    /// rebuilt either way: it is the same `NSTouchBar`, the same items, the
    /// same views, shown again with one argument changed.
    ///
    /// Pock's own `presentOnTop:` always passes 1, which is why going through
    /// it could take the Control Strip away and never give it back. So this
    /// calls the underlying AppKit method directly, reaching Pock's bar through
    /// the same door PockKit uses: its `TouchBarHelper`, found by name at
    /// runtime. Every step is checked, so a future Pock that renames any of it
    /// makes this return false instead of crashing, and the caller falls back
    /// to the reload that always works.
    /// Whether macOS draws its close box at the left of a system-modal Touch
    /// Bar. Pock keeps it off; presenting without turning it off again leaves
    /// an ✕ in front of the bar that quits Pock's bar when pressed.
    private static func setCloseBoxVisible(_ visible: Bool) {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
            RTLD_NOW
        ), let symbol = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        typealias Show = @convention(c) (DarwinBoolean) -> Void
        unsafeBitCast(symbol, to: Show.self)(DarwinBoolean(visible))
    }

    @discardableResult
    private static func present(placement: Int) -> Bool {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pock"
        let target = name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
        let navSelector = Selector(("mainNavigationController"))
        guard let helper = objc_getClass("\(target).TouchBarHelper") as? NSObjectProtocol,
              helper.responds(to: navSelector),
              let nav = helper.perform(navSelector)?.takeUnretainedValue()
                  as? PKTouchBarNavigationController,
              let bar = nav.rootController?.touchBar
        else { return false }

        let selector = Selector(("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"))
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else { return false }

        // Presenting a bar that is already on screen does not move it: the
        // placement is fixed at the moment it goes up, so it has to come down
        // first. Through Pock's own `dismissFromTop:`, not AppKit's
        // `dismissSystemModalTouchBar:` — the raw one tears the items down with
        // it and leaves the widget deallocated, while Pock's keeps its own
        // bookkeeping intact and the widget alive. Measured both ways.
        let dismissSelector = Selector(("dismissFromTop:"))
        guard helper.responds(to: dismissSelector) else { return false }
        helper.perform(dismissSelector, with: bar)

        // Set before presenting as well as after: the close box is decided as
        // the bar goes up, so asking for it to be gone afterwards is a request
        // to remove something already drawn.
        setCloseBoxVisible(false)

        typealias Present = @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString?) -> Void
        let present = unsafeBitCast(method_getImplementation(method), to: Present.self)
        present(NSTouchBar.self, selector, bar, placement, nil)
        setCloseBoxVisible(false)

        // Presenting is two steps, and replacing the first meant losing the
        // second. macOS puts a close box at the left of any system-modal Touch
        // Bar; Pock takes it away again immediately afterwards, which is why
        // one never appears on its own presentations. Skipping that left an ✕
        // sitting in front of the bar after the first expand or collapse.
        let hideCloseBox = Selector(("hideCloseButtonIfNeeded"))
        if helper.responds(to: hideCloseBox) { helper.perform(hideCloseBox) }
        return true
    }

    // MARK: Layout

    /// Takes the Touch Bar's real width if the window is willing to say what it
    /// is. Returns true when the width changed, meaning this layout pass is
    /// working from a stale size and another one is already on its way.
    private func adoptBarWidth() -> Bool {
        guard isExpanded,
              let width = window?.contentView?.bounds.width,
              width > 120, abs(width - presentationWidth) > 0.5
        else { return false }
        presentationWidth = width
        Self.widestSeen = max(Self.widestSeen, width)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
        return true
    }

    override func layout() {
        super.layout()
        // Asking the window is the only way to learn the real width, and it
        // answers zero about half the time on the first pass — so ask on every
        // pass until it gives a believable number. Changing width here schedules
        // another pass; the guard on `presentationWidth` stops it looping.
        if adoptBarWidth() { return }
        let expanded = isExpanded
        [collapseIcon, previousIcon, playIcon, nextIcon, titleLabel, elapsedLabel, remainingLabel,
         muteIcon].forEach { $0.isHidden = !expanded }
        volumeTrack.isHidden = !expanded
        volumeKnob.isHidden = !expanded
        track.isHidden = !expanded
        knob.isHidden = !expanded || dragFraction == nil
        ringTrack.isHidden = expanded
        ringFill.isHidden = expanded

        guard expanded else {
            layoutCollapsed()
            return
        }

        // Every glyph gets the same box, on the same centre line as the cover
        // and the clocks. They were on three different centres before.
        let glyph = Self.glyphSize
        let glyphY = (bounds.height - glyph) / 2
        var x = Self.inset
        collapseIcon.frame = NSRect(x: x, y: glyphY, width: glyph, height: glyph)
        x += glyph + 2
        for icon in [previousIcon, playIcon, nextIcon] {
            icon.frame = NSRect(x: x + (Self.control - glyph) / 2, y: glyphY, width: glyph, height: glyph)
            x += Self.control
        }
        x += Self.gap
        artView.isHidden = false
        artView.layer?.cornerRadius = 3
        artView.frame = NSRect(
            x: x, y: (bounds.height - Self.artSize) / 2,
            width: Self.artSize, height: Self.artSize
        )

        let box = trackFrame
        track.frame = box
        // 16pt, not the 14 the glyphs nominally need: the title wants 13.56pt
        // and the clock grows to the same while a drag is in progress, which
        // happens without a re-layout. A box measured to the millimetre clips
        // the descenders the moment anything changes weight.
        let line: CGFloat = 16
        let lineY = (bounds.height - line) / 2
        elapsedLabel.frame = NSRect(
            x: box.minX - Self.gap - Self.clockWidth, y: lineY, width: Self.clockWidth, height: line
        )
        remainingLabel.frame = NSRect(x: box.maxX + Self.gap, y: lineY, width: Self.clockWidth, height: line)
        titleLabel.frame = NSRect(x: box.minX + 10, y: lineY, width: box.width - 20, height: line)

        muteIcon.frame = NSRect(
            x: volumeLeft + (Self.muteWidth - glyph) / 2, y: glyphY, width: glyph, height: glyph
        )
        volumeTrack.frame = volumeSliderFrame
        refreshVolumeState()
        tick()
    }

    /// Collapsed: the cover inside a ring that fills as it plays.
    private func layoutCollapsed() {
        let size = Self.ringSize
        let originX = (bounds.width - size) / 2
        let originY = (bounds.height - size) / 2
        let art = size - 9
        artView.isHidden = false
        artView.layer?.cornerRadius = art / 2
        artView.frame = NSRect(x: originX + 4.5, y: originY + 4.5, width: art, height: art)

        let box = CGRect(x: originX, y: originY, width: size, height: size).insetBy(dx: 1.5, dy: 1.5)
        let path = CGPath(ellipseIn: box, transform: nil)
        for ring in [ringTrack, ringFill] {
            ring.frame = bounds
            ring.path = path
        }
        // Start the sweep at twelve o'clock rather than three.
        ringFill.transform = CATransform3DIdentity
        ringFill.setAffineTransform(.identity)
        ringFill.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringFill.frame = bounds
        // The path was just rebuilt, so whatever was drawn before is gone.
        drawnRingFraction = -1
        tick()
    }

    // MARK: Input

    @objc private func handleTap(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: self)
        guard isExpanded else {
            onToggleExpand?()
            return
        }
        var x = Self.inset
        if point.x < x + Self.glyphSize + 2 { onToggleExpand?(); return }
        x += Self.glyphSize + 2
        if point.x < x + Self.control { if supportsPrevious { onPrevious?() }; return }
        x += Self.control
        if point.x < x + Self.control { onPlayPause?(); return }
        x += Self.control
        if point.x < x + Self.control { if supportsNext { onNext?() }; return }

        // The right end belongs to volume: the mute glyph, then the slider.
        if point.x >= volumeLeft {
            if point.x < volumeLeft + Self.muteWidth { onToggleMute?(); return }
            onSetVolume?(Float(volumeFraction(at: point.x)))
            return
        }

        // The cover and the clocks are not seek targets — only the track is.
        guard point.x >= trackFrame.minX - Self.gap else { return }
        onScrub?(fraction(at: point.x))
    }

    /// Drag to choose a position; the bar follows the finger and only commits
    /// on release, so overshooting costs nothing.
    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        guard isExpanded else { return }
        let x = gesture.location(in: self).x
        switch gesture.state {
        case .began:
            if x >= volumeLeft + Self.muteWidth {
                dragTarget = .volume
                onSetVolume?(Float(volumeFraction(at: x)))
                drawVolume(Float(volumeFraction(at: x)))
            } else if x >= trackFrame.minX - Self.gap, x < volumeLeft {
                dragTarget = .scrub
                dragFraction = fraction(at: x)
                onArtworkNeeded?()
                setScrubbing(true)
                tick()
            }
            // Anywhere else is a button, and a swipe across one is a mis-swipe.
        case .changed:
            switch dragTarget {
            case .volume:
                // Volume follows the finger as it moves. Seeking does not:
                // committing every intermediate position would have the player
                // chasing a scrub it can never catch up with.
                let value = Float(volumeFraction(at: x))
                onSetVolume?(value)
                drawVolume(value)
            case .scrub:
                dragFraction = fraction(at: x)
                tick()
            case nil:
                break
            }
        case .ended, .cancelled, .failed:
            let committed = gesture.state == .ended
            let wasScrub = dragTarget == .scrub
            let target = dragFraction
            dragTarget = nil
            dragFraction = nil
            if wasScrub {
                setScrubbing(false)
                tick()
                if committed, let target { onScrub?(target) }
            } else {
                refreshVolumeState()
            }
        default:
            break
        }
    }

    /// Dragging brightens the clock you are steering by and fades the title
    /// behind it. Nothing moves: a layout that rearranges itself under the
    /// finger is harder to aim than one that only changes weight.
    private func setScrubbing(_ on: Bool) {
        titleLabel.alphaValue = on ? 0.45 : 1
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: on ? 11 : 10, weight: on ? .semibold : .regular)
        elapsedLabel.textColor = on ? .white : NSColor(calibratedWhite: 1, alpha: 0.6)
    }

    /// Where along the track a touch lands. Measured against the track itself,
    /// not the whole view: the buttons take the first third of the bar, and
    /// counting from the view's edge made the start of every track unreachable.
    private func volumeFraction(at x: CGFloat) -> Double {
        let box = volumeSliderFrame
        guard box.width > 0 else { return 0 }
        return Double(min(max((x - box.minX) / box.width, 0), 1))
    }

    private func fraction(at x: CGFloat) -> Double {
        let box = trackFrame
        guard box.width > 0 else { return 0 }
        return Double(min(max((x - box.minX) / box.width, 0), 1))
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
