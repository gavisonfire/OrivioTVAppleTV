import SwiftUI

// MARK: - Geometry
//
// The player is laid out to Infuse's tvOS transport, measured off 1920x1080
// captures: a thin full-width bar 95pt up from the bottom edge, the elapsed
// and remaining figures hanging under its two ends, the title on a line 60pt
// above it with the subtitle and audio glyphs at the right end of that same
// line, and "Swipe down for Info" centred at the top. While scrubbing the
// title line goes away and a preview frame rides the playhead.

enum FusionMetrics {
    /// Centre of the bar, measured from the bottom of the screen.
    static let barCentreFromBottom: CGFloat = 95
    /// Bar ends. Infuse runs 86pt in from each edge.
    static let sideInset: CGFloat = 86
    static let trackHeight: CGFloat = 6
    /// Scrub playhead: a white disc with a dark ring inside it.
    static let thumbSize: CGFloat = 28
    /// The fine-tune wheel, drawn in the playhead's place while it turns.
    static let wheelSize: CGFloat = 46
    /// The scrub playhead slit.
    static let slitWidth: CGFloat = 4
    static let slitHeight: CGFloat = 20
    /// Preview frame above the playhead while scrubbing.
    static let sceneWidth: CGFloat = 400
    static let sceneHeight: CGFloat = 225
    static let sceneGap: CGFloat = 30
    /// Bar → time row.
    static let timeGap: CGFloat = 13
    /// Title line → bar.
    static let titleGap: CGFloat = 30
    static let timeFont: CGFloat = 28
    /// Glyph disc (the grey circle behind a focused glyph).
    static let glyphDisc: CGFloat = 62
    static let glyphSpacing: CGFloat = 25
    /// Popover panel width and how far its bottom sits above the glyph line.
    static let popoverWidth: CGFloat = 440
    static let popoverGap: CGFloat = 20

    /// Bottom padding under the time row so the bar lands at `barCentreFromBottom`.
    static var blockBottomPadding: CGFloat {
        barCentreFromBottom - trackHeight / 2 - timeGap - timeRowHeight
    }
    static let timeRowHeight: CGFloat = 34
}

/// What the bar is currently showing.
enum FusionBarMode {
    case idle
    /// A left/right press is accumulating a skip that hasn't committed yet.
    case nudging
    /// Fast-forward / rewind preview sweeping.
    case scanning
    /// Scrubbing with the trackpad.
    case scrubbing
    /// Scrubbing with the fine-tune wheel engaged.
    case fineTuning

    var showsScene: Bool { self == .scanning || self == .scrubbing || self == .fineTuning }
    var showsReadout: Bool { self != .idle }
}

// MARK: - Controls overlay

/// The transport. Shown for `.controls` and `.pauseInfo` (paused — the bar
/// stays up), and for `.audio` / `.subtitles`, which are this same screen
/// with a track popover anchored above the matching glyph.
///
/// Infuse's remote grammar, which the bar follows exactly:
/// - click: play / pause
/// - swipe left/right: scrub (the preview frame follows the finger); click
///   seeks there, Menu cancels
/// - click left/right edge: skip; hold: fast-forward / rewind
/// - up: the glyphs; down: switch the times between elapsed/remaining and
///   start/end clock
/// - swipe down: the info panel (owned by PlayerScreen)
struct FusionPlayerControlsOverlay: View {
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState private var focusedControl: Control?

    enum Control: Hashable {
        case bar
        case subtitlesGlyph
        case audioGlyph
        case popoverRow(String)
    }

    /// Glyphs on screen, left→right.
    private var glyphOrder: [Control] {
        var order: [Control] = []
        if !viewModel.subtitleOptions.isEmpty { order.append(.subtitlesGlyph) }
        if !viewModel.audioOptions.isEmpty { order.append(.audioGlyph) }
        return order
    }

    private var popoverGlyph: Control? {
        switch viewModel.overlay {
        case .subtitles: return .subtitlesGlyph
        case .audio: return .audioGlyph
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 4) {
                Text("Swipe down for Info")
                    .font(.system(size: 22, weight: .medium))
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 30, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 60)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            FusionBottomBlock(
                viewModel: viewModel,
                clock: viewModel.clock,
                forcedScrub: false,
                showsTitle: true
            ) {
                glyphCluster
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()

            // The bar's focus + input target. Deliberately free of any clock
            // observation: rebuilding a focusable on every playback tick makes
            // the focus engine churn, which restarts the auto-hide timer
            // forever and swallows presses.
            barInputTarget
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()

            if let glyph = popoverGlyph {
                popover(for: glyph)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, popoverTrailing(for: glyph))
                    .padding(.bottom, FusionMetrics.barCentreFromBottom + FusionMetrics.trackHeight / 2
                             + FusionMetrics.titleGap + FusionMetrics.glyphDisc + FusionMetrics.popoverGap)
                    .ignoresSafeArea()
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .defaultFocus($focusedControl, .bar)
        .onAppear {
            focusedControl = .bar
            viewModel.controlsFocusOnBar = true
        }
        .onChange(of: focusedControl) { _, new in
            viewModel.restartHideTimer()
            viewModel.controlsFocusOnBar = (new == .bar)
            // Moving off the popover's rows (down onto a glyph or the bar)
            // dismisses it, the way leaving any menu does.
            if popoverGlyph != nil, let new, new != popoverGlyph {
                if case .popoverRow = new { return }
                viewModel.overlay = .controls
            }
        }
        .onChange(of: viewModel.overlay) { old, new in
            // Closing a popover hands focus back to its glyph, never to
            // nothing (which would leave the remote dead).
            if new == .controls, old == .audio { focusedControl = .audioGlyph }
            if new == .controls, old == .subtitles { focusedControl = .subtitlesGlyph }
        }
        .animation(FusionMotion.controlsAppear, value: popoverGlyph)
    }

    // MARK: Glyphs

    /// Subtitles, then audio — the quiet icon pair at the right end of the
    /// title line. Each opens its track popover; pressing again closes it.
    private var glyphCluster: some View {
        HStack(spacing: FusionMetrics.glyphSpacing) {
            if !viewModel.subtitleOptions.isEmpty {
                glyphButton(control: .subtitlesGlyph, label: "Subtitles") {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 28, weight: .regular))
                } action: {
                    viewModel.overlay = viewModel.overlay == .subtitles ? .controls : .subtitles
                }
            }
            if !viewModel.audioOptions.isEmpty {
                glyphButton(control: .audioGlyph, label: "Audio") {
                    InfuseAudioGlyph()
                } action: {
                    viewModel.overlay = viewModel.overlay == .audio ? .controls : .audio
                }
            }
        }
    }

    private func glyphButton<Icon: View>(control: Control, label: String,
                                         @ViewBuilder icon: @escaping () -> Icon,
                                         action: @escaping () -> Void) -> some View {
        Button {
            action()
            viewModel.restartHideTimer()
        } label: {
            FusionHUDGlyph(active: popoverGlyph == control) { icon() }
        }
        .buttonStyle(PlainCardButtonStyle())
        .focused($focusedControl, equals: control)
        .accessibilityLabel(label)
        .onMoveCommand { direction in
            viewModel.noteInput("move \(direction) (\(label))")
            if viewModel.moveSuppressed { return }
            move(direction, from: control)
        }
    }

    private func move(_ direction: MoveCommandDirection, from control: Control) {
        switch direction {
        case .down: focusedControl = .bar
        case .up: viewModel.restartHideTimer()
        case .left, .right:
            let order = glyphOrder
            guard let index = order.firstIndex(of: control) else { return }
            let next = direction == .left ? index - 1 : index + 1
            if order.indices.contains(next) { focusedControl = order[next] }
            else { viewModel.restartHideTimer() }
        @unknown default: break
        }
    }

    // MARK: Bar input

    private var barInputTarget: some View {
        Button {
            viewModel.noteInput("click (bar)")
            if viewModel.scanPreview != nil {
                // A fast-forward preview is up — the press commits it.
                viewModel.togglePlayPause()
                viewModel.restartHideTimer()
            } else {
                // Clicking the bar pauses the picture and drops into scrub
                // mode: the preview frame and the target time ride the
                // playhead until the next click seeks and resumes (Menu puts
                // it back where it was).
                viewModel.beginScrub(pausing: true)
            }
        } label: {
            Color.clear
                .frame(height: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainCardButtonStyle())
        .focused($focusedControl, equals: .bar)
        .padding(.horizontal, FusionMetrics.sideInset)
        .padding(.bottom, FusionMetrics.barCentreFromBottom - 30)
        .onMoveCommand { direction in
            viewModel.noteInput("move \(direction) (bar)")
            if viewModel.moveSuppressed { return }
            switch direction {
            case .left: viewModel.barDirectionalPress(forward: false)
            case .right: viewModel.barDirectionalPress(forward: true)
            case .up:
                if let last = glyphOrder.last { focusedControl = last }
                else { viewModel.restartHideTimer() }
            case .down:
                viewModel.restartHideTimer()
            @unknown default: break
            }
        }
    }

    // MARK: Popovers

    @ViewBuilder
    private func popover(for glyph: Control) -> some View {
        if glyph == .subtitlesGlyph {
            InfuseTrackPopover(
                title: "Subtitles",
                options: viewModel.subtitleOptions,
                selectedID: viewModel.selectedSubtitleID,
                focus: $focusedControl
            ) { option in
                viewModel.selectSubtitle(option)
                viewModel.overlay = .controls
            }
        } else {
            InfuseTrackPopover(
                title: "Audio",
                options: viewModel.audioOptions,
                selectedID: viewModel.selectedAudioID,
                focus: $focusedControl
            ) { option in
                viewModel.selectAudio(option)
                viewModel.overlay = .controls
            }
        }
    }

    /// The popover's right edge sits just inside its glyph's centre.
    private func popoverTrailing(for glyph: Control) -> CGFloat {
        let order = glyphOrder
        let fromRight = order.count - 1 - (order.firstIndex(of: glyph) ?? 0)
        let glyphCentre = FusionMetrics.sideInset + FusionMetrics.glyphDisc / 2
            + CGFloat(fromRight) * (FusionMetrics.glyphDisc + FusionMetrics.glyphSpacing)
        return glyphCentre - 10
    }
}

/// The audio glyph: seven thin bars, tallest in the middle — Infuse's
/// spectrum icon, which has no SF Symbol equivalent.
struct InfuseAudioGlyph: View {
    private let heights: [CGFloat] = [0.42, 0.62, 1.0, 0.55, 0.82, 0.38, 0.6]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule().frame(width: 3, height: 28 * h)
            }
        }
        .frame(height: 28, alignment: .bottom)
    }
}

// MARK: - Scrub / peek presentation
//
// `beginScrub()` clears the overlay and raises `isScrubbing`, so the controls
// above are gone by then. This draws the same bar in the same place, without
// the title line — Infuse's scrub view is the bar, the preview frame and the
// times, nothing else. It is inert: every scrub input is handled by
// PlayerScreen's invisible catcher and the trackpad recognizer.

struct FusionInertOverlay: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// True for the scrub view (always in a preview state). False for the
    /// quick-seek HUD, which reads its own mode.
    var forcedScrub = false

    var body: some View {
        FusionBottomBlock(
            viewModel: viewModel,
            clock: viewModel.clock,
            forcedScrub: forcedScrub,
            showsTitle: false
        ) {
            EmptyView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - The block itself

/// Title line + bar + times, plus whatever rides the playhead. Observes the
/// clock (it is the only thing here that needs to repaint on a tick).
private struct FusionBottomBlock<Trailing: View>: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var clock: PlaybackClock
    let forcedScrub: Bool
    let showsTitle: Bool
    @ViewBuilder var trailing: () -> Trailing

    private var mode: FusionBarMode {
        if forcedScrub { return viewModel.wheelEngaged ? .fineTuning : .scrubbing }
        if clock.scanPreview != nil { return .scanning }
        if viewModel.pendingSeekDelta != 0 { return .nudging }
        return .idle
    }

    /// The position the bar is POINTING at: a scan preview, a scrub target, or
    /// playback plus any pending nudge.
    private var target: Double {
        let raw = clock.scanPreview ?? clock.scrubTarget
            ?? (clock.position + viewModel.pendingSeekDelta)
        return min(max(raw, 0), duration)
    }
    private var duration: Double { max(clock.duration, 1) }
    private var fraction: CGFloat { CGFloat(min(max(target / duration, 0), 1)) }
    private var liveFraction: CGFloat { CGFloat(min(max(clock.position / duration, 0), 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                HStack(alignment: .center, spacing: OrivioSpacing.lg) {
                    titleBlock.allowsHitTesting(false)
                    Spacer(minLength: OrivioSpacing.xl)
                    trailing()
                }
                .padding(.bottom, FusionMetrics.titleGap)
            }
            track.allowsHitTesting(false)
            timeRow
                .allowsHitTesting(false)
                .padding(.top, FusionMetrics.timeGap)
        }
        .padding(.horizontal, FusionMetrics.sideInset)
        .padding(.bottom, FusionMetrics.blockBottomPadding)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.displayTitle)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            if let episodeLine = viewModel.episodeLine {
                Text(episodeLine)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
    }

    // MARK: Times

    /// Elapsed at the left, remaining (from the pointed-at position) at the
    /// right — or, on the clock setting, the wall-clock time the film started
    /// and the time it will end. The pointed-at time also sits under the
    /// playhead while it differs from playback.
    private var timeRow: some View {
        let elapsed = clock.position
        let remaining = max(duration - target, 0)
        let clockMode = viewModel.showsClockTimes
        return GeometryReader { geo in
            let w = geo.size.width
            let readoutWidth: CGFloat = 130
            let readoutX = clampedX(w * fraction, width: readoutWidth, in: w)
            // The end figures step aside when the readout sits over them.
            let hidesLeft = mode.showsReadout && readoutX - readoutWidth / 2 < 150
            let hidesRight = mode.showsReadout && readoutX + readoutWidth / 2 > w - 150
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top) {
                    Group {
                        if clockMode {
                            timeText(WatchClock.started(position: elapsed))
                        } else {
                            timeText(TimeFormat.clock(elapsed))
                        }
                    }
                    .opacity(hidesLeft ? 0 : 1)
                    Spacer()
                    Group {
                        if clockMode {
                            timeText(WatchClock.ends(position: target, duration: duration))
                        } else {
                            timeText("-" + TimeFormat.clock(remaining))
                        }
                    }
                    .opacity(hidesRight ? 0 : 1)
                }
                .frame(width: w)
                .animation(.easeInOut(duration: 0.3), value: clockMode)

                if mode.showsReadout {
                    timeText(mode == .nudging
                             ? TimeFormat.signedDelta(viewModel.pendingSeekDelta)
                             : TimeFormat.clock(target))
                        .foregroundStyle(.white)
                        .frame(width: readoutWidth)
                        .position(x: readoutX, y: FusionMetrics.timeRowHeight / 2)
                }
            }
        }
        .frame(height: FusionMetrics.timeRowHeight)
    }

    private func timeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: FusionMetrics.timeFont, weight: .regular).monospacedDigit())
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(1)
            .fixedSize()
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
    }

    // MARK: Track

    /// How far (0…1 of the film) the data on hand reaches ahead of playback:
    /// the hybrid disk cache when it is running, else the engine's own
    /// read-ahead. This is the growing lighter band on the bar.
    private var cacheEnd: CGFloat {
        // From the CLOCK, which publishes it on its own timer — reading the
        // view model's computed value gave SwiftUI nothing to observe, so the
        // band only moved while playback happened to be ticking the position.
        CGFloat(min(max(clock.cacheEnd, 0), 1))
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = FusionMetrics.trackHeight
            let x = w * fraction
            let live = w * liveFraction
            let cached = w * cacheEnd
            // The track is sized HERE, explicitly, and everything that rides
            // it is an overlay. As a ZStack sibling of the 28pt playhead the
            // track took the playhead's height on the device (a fat capsule
            // the moment scrubbing began).
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3))
                // Cache band: from the playhead to the end of what's on
                // hand. Grows across the film as the download runs.
                if cached > live {
                    Rectangle().fill(.white.opacity(0.28))
                        .frame(width: cached - live)
                        .offset(x: live)
                }
                // Played — up to the pointed-at position.
                Rectangle().fill(.white).frame(width: max(x, h))
                ForEach(Array(viewModel.chapterFractions.enumerated()), id: \.offset) { _, f in
                    Rectangle().fill(.black.opacity(0.4))
                        .frame(width: 2, height: h)
                        .offset(x: w * CGFloat(f))
                }
            }
            .frame(width: w, height: h)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                if mode == .fineTuning {
                    // The wheel takes the playhead's place while it is turning.
                    FusionSpinWheel(angle: clock.wheelAngle)
                        .frame(width: FusionMetrics.wheelSize, height: FusionMetrics.wheelSize)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .offset(x: min(max(x - FusionMetrics.wheelSize / 2, 0),
                                       w - FusionMetrics.wheelSize))
                } else if mode.showsScene {
                    // Scrub playhead: a small slit standing on the bar.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white)
                        .frame(width: FusionMetrics.slitWidth, height: FusionMetrics.slitHeight)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .offset(x: min(max(x - FusionMetrics.slitWidth / 2, 0),
                                       w - FusionMetrics.slitWidth))
                }
            }
            .overlay(alignment: .topLeading) {
                // No frame rather than an empty one: the thumbnail pass is
                // skipped on the A8, on HLS, and on huge remuxes.
                if mode.showsScene, let preview = viewModel.thumbnail(at: target) {
                    FusionSceneWindow(image: preview,
                                      rate: mode == .scanning ? viewModel.scanRate : 0)
                        .offset(x: clampedX(x, width: FusionMetrics.sceneWidth, in: w)
                                   - FusionMetrics.sceneWidth / 2,
                                y: -(FusionMetrics.sceneHeight + FusionMetrics.sceneGap)
                                   + (FusionMetrics.trackHeight / 2 - FusionMetrics.thumbSize / 2))
                }
            }
        }
        .frame(height: FusionMetrics.wheelSize)
    }

    private func clampedX(_ x: CGFloat, width: CGFloat, in trackWidth: CGFloat) -> CGFloat {
        min(max(x, width / 2), max(trackWidth - width / 2, width / 2))
    }
}

// MARK: - Scene window

/// The preview frame above the playhead while scrubbing: a rounded 16:9
/// still with a hairline edge and a soft shadow.
private struct FusionSceneWindow: View {
    let image: UIImage
    /// Scan speed; 0 hides the chip.
    let rate: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(width: FusionMetrics.sceneWidth, height: FusionMetrics.sceneHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.7), radius: 14, y: 6)

            if rate != 0 {
                HStack(spacing: 5) {
                    Image(systemName: rate > 0 ? "forward.fill" : "backward.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text("\(abs(rate))×")
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(8)
            }
        }
        .frame(width: FusionMetrics.sceneWidth, height: FusionMetrics.sceneHeight)
    }
}

/// Fine-tune wheel indicator: a ring with a knob where your finger is on the
/// trackpad. No progress arc — the knob is the position that matters.
private struct FusionSpinWheel: View {
    /// The finger's angle as `atan2(y, x)` over the GameController pad, where
    /// +y is the TOP of the pad.
    let angle: Double

    var body: some View {
        // Infuse's jog wheel: a white disc, a thick dark ring with a white
        // hole in the middle, and a small dark knob riding the white rim
        // where the finger is. Proportions measured off Infuse's own wheel.
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let knob = size * 0.15
            let knobRadius = size * 0.36
            ZStack {
                Circle().fill(.white)
                Circle()
                    .stroke(.black.opacity(0.92), lineWidth: size * 0.15)
                    .frame(width: size * 0.44, height: size * 0.44)
                Circle().fill(.black.opacity(0.92))
                    .frame(width: knob, height: knob)
                    // The pad reports +y at its TOP; SwiftUI's y grows DOWNWARD.
                    .offset(x: knobRadius * CGFloat(cos(angle)),
                            y: -knobRadius * CGFloat(sin(angle)))
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Glyph

/// One HUD glyph: a bare white symbol at rest, a grey disc behind it when
/// focused or when its popover is open.
private struct FusionHUDGlyph<Icon: View>: View {
    @Environment(\.isFocused) private var isFocused
    let active: Bool
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        icon()
            .foregroundStyle(.white)
            .frame(width: FusionMetrics.glyphDisc, height: FusionMetrics.glyphDisc)
            .background {
                if isFocused || active {
                    Circle().fill(.white.opacity(0.26))
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            .focusLift(OrivioFocus.control, isFocused)
    }
}

// MARK: - Track popover

/// The subtitle / audio picker anchored above its glyph: a dark rounded
/// panel with a small-caps header, one row per track, a checkmark on the
/// active one, and a white pill on the focused row that runs a little wider
/// than the panel itself.
private struct InfuseTrackPopover: View {
    let title: String
    let options: [TrackOption]
    let selectedID: String?
    @FocusState.Binding var focus: FusionPlayerControlsOverlay.Control?
    let onSelect: (TrackOption) -> Void

    private let rowHeight: CGFloat = 66

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .medium))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 70)
                .padding(.top, 26)
                .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(options) { option in
                            Button {
                                onSelect(option)
                            } label: {
                                InfusePopoverRow(
                                    title: option.id == "sub-off" ? "None" : option.displayName,
                                    selected: option.id == selectedID,
                                    height: rowHeight
                                )
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .focused($focus, equals: .popoverRow(option.id))
                            .id(option.id)
                        }
                    }
                }
                // Long track lists scroll INSIDE the panel; the pill's 10pt
                // overhang is inside this wider clip, so nothing spills.
                .frame(width: FusionMetrics.popoverWidth + 20,
                       height: rowHeight * CGFloat(min(max(options.count, 1), 7)))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, -10)
                .onAppear {
                    if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: FusionMetrics.popoverWidth)
        .background {
            if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(hex: 0x141416).opacity(0.94))
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.black.opacity(0.7))
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .onAppear {
            // Open on the active track, so the first press is never a hunt.
            focus = .popoverRow(selectedID ?? options.first?.id ?? "")
        }
    }
}

private struct InfusePopoverRow: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool
    let height: CGFloat

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .medium))
                .opacity(selected ? 1 : 0)
                .frame(width: 26)
            Text(title)
                .font(.system(size: 26, weight: isFocused ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isFocused ? .black : (selected ? .white.opacity(0.92) : .white.opacity(0.55)))
        .padding(.leading, 34)
        .padding(.trailing, 24)
        .frame(width: FusionMetrics.popoverWidth + 20, height: height)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
        }
        .padding(.horizontal, -10)
    }
}
