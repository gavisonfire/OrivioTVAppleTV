import KSPlayer
import SwiftUI
import UIKit

/// Hosts the current engine's video view. KSPlayerLayer swaps the underlying
/// player (native ↔ FFmpeg) during failover and re-parents the new view into
/// the old one's superview itself, so this container just has to attach the
/// current view and clean up strays whenever `videoRefreshID` changes.
///
/// Deliberately NOT `@ObservedObject`: observing the view model made every
/// published change re-run `updateUIView`. The parent passes `refreshID`
/// (bumped only when the engine/player instance may have changed) so SwiftUI
/// re-invokes us exactly when re-attachment could be needed.
struct PlayerVideoView: UIViewRepresentable {
    let viewModel: PlayerViewModel
    let refreshID: UUID
    /// Zoom / aspect-ratio scale and vertical shift, applied as a UIKit
    /// transform on the CONTAINER. At the identity this is exactly no
    /// transform — the Metal video layer keeps its direct scan-out path and
    /// its colour handling — unlike a SwiftUI `scaleEffect`, which wraps the
    /// layer in a compositing transform even at 1.0 (washed-out HDR on the
    /// FFmpeg engine). And because the engine's view is never re-parented,
    /// returning to Normal never leaves a black picture.
    var scale: CGSize = CGSize(width: 1, height: 1)
    var shiftY: CGFloat = 0

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
        applyTransform(to: container)
    }

    private func applyTransform(to container: UIView) {
        let wanted = scale.width == 1 && scale.height == 1 && shiftY == 0
            ? CGAffineTransform.identity
            : CGAffineTransform(translationX: 0, y: shiftY).scaledBy(x: scale.width, y: scale.height)
        guard container.transform != wanted else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            container.transform = wanted
        }
    }

    private func attach(to container: UIView) {
        // Point PiP at whatever the engine ended up rendering into. Done here
        // rather than at load time because the render view only exists once
        // the engine has actually started, and it CHANGES on an engine swap.
        viewModel.refreshPictureInPictureSource()
        // The active engine's render view (KSPlayer's player view or VLC's
        // drawable) — bumped via videoRefreshID when the engine changes.
        guard let videoView = viewModel.activeVideoView else {
            for subview in container.subviews {
                subview.removeFromSuperview()
            }
            return
        }
        for subview in container.subviews where subview !== videoView {
            subview.removeFromSuperview()
        }
        guard videoView.superview !== container else { return }
        videoView.removeFromSuperview()
        container.addSubview(videoView)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

/// Renders the active subtitle cues from KSPlayer's SubtitleModel: text cues
/// bottom-centered in Orivio's caption style, bitmap cues (PGS/VobSub) fitted
/// over the video.
struct SubtitleOverlayView: View {
    @ObservedObject var model: SubtitleModel
    var settings: PlayerSettings = .default

    var body: some View {
        ZStack {
            ForEach(model.parts) { part in
                if let image = part.image {
                    GeometryReader { geo in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: geo.size.width * 0.9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 60)
                    }
                } else if let text = part.text {
                    // Broadcast-caption look, styled from Playback settings:
                    // text color, optional true outline, background plate with
                    // adjustable opacity, and a vertical offset.
                    VStack {
                        Spacer()
                        styledCaption(text)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 9)
                            .background(
                                Color.black.opacity(settings.subtitleBackground
                                    ? Double(settings.subtitleBackgroundOpacity) / 100 : 0),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .padding(.bottom, CGFloat(84 + settings.subtitleVerticalOffset))
                            .frame(maxWidth: 1200)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var textColor: Color { Color(badgeHex: settings.subtitleTextColorHex) ?? .white }
    private var outlineColor: Color { Color(badgeHex: settings.subtitleOutlineColorHex) ?? .black }

    /// The configured caption face at the configured size. A family name that
    /// doesn't resolve on this box falls back to the system font (UIFont is
    /// the check — `Font.custom` itself falls back silently, but through a
    /// body-text metric rather than the caption size).
    private var captionFont: Font {
        let size = CGFloat(settings.subtitleSize)
        let name = settings.subtitleFontName
        if !name.isEmpty, UIFont(name: name, size: size) != nil {
            let custom = Font.custom(name, fixedSize: size)
            return settings.subtitleBold ? custom.bold() : custom
        }
        return .system(size: size, weight: settings.subtitleBold ? .bold : .medium)
    }

    /// One caption line with the configured color and (optionally) a real
    /// outline — SwiftUI has no text stroke, so the outline is the same text
    /// rendered in 8 directions behind the fill. Falls back to a soft double
    /// shadow when the outline is off.
    @ViewBuilder
    private func styledCaption(_ text: NSAttributedString) -> some View {
        let base = Text(AttributedString(text))
            .font(captionFont)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
        if settings.subtitleOutlineEnabled {
            ZStack {
                let w = CGFloat(max(1, settings.subtitleOutlineWidth))
                ForEach(0 ..< 8, id: \.self) { i in
                    let a = Double(i) / 8 * 2 * .pi
                    base.foregroundStyle(outlineColor)
                        .offset(x: cos(a) * w, y: sin(a) * w)
                }
                base.foregroundStyle(textColor)
            }
        } else {
            base.foregroundStyle(textColor)
                .shadow(color: .black.opacity(0.95), radius: 2, y: 1)
                // The soft radius-8 glow is a second offscreen blur composited
                // over the moving video on every displayed frame — enough to
                // cost playback frames on the A8 whenever captions are up. The
                // crisp radius-2 shadow alone keeps them readable there.
                .shadow(color: .black.opacity(PerformanceProfile.isLowPower ? 0 : 0.6),
                        radius: PerformanceProfile.isLowPower ? 0 : 8)
        }
    }
}
