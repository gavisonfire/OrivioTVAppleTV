import SwiftUI
import AVKit
import YouTubeKit

/// Resolves a YouTube video key to something AVPlayer can play. tvOS has no
/// WebKit, so the iframe embed is out — YouTubeKit extracts native streams.
///
/// YouTube only *muxes* audio+video up to ~720p; 1080p and up exist solely as
/// separate adaptive tracks (DASH), so a 1080p trailer means merging a
/// video-only and an audio-only stream into one composition.
///
/// This used to always take the single muxed URL for a fast start, which
/// capped every trailer at 720p (often 360/480p, since the muxed ladder is
/// thin). Resolution wins now: the merge is used whenever it is genuinely
/// sharper than the best muxed stream, and the muxed fast path is kept for the
/// case where it is already as good. The old objection — that merging is slow
/// to start — was mostly the merge loading its two remote assets one after the
/// other; `mergedItem` now loads them concurrently.
enum TrailerResolver {
    /// The highest-resolution natively-playable item: a merged 1080p (or
    /// better) composition when the adaptive ladder beats the muxed one,
    /// otherwise the single muxed progressive URL.
    static func playerItem(youtubeKey: String) async -> AVPlayerItem? {
        guard let streams = try? await YouTube(videoID: youtubeKey, methods: [.local, .remote]).streams else { return nil }
        // isNativelyPlayable keeps only codecs AVPlayer decodes (H.264/AAC),
        // dropping VP9/AV1 webm — so the "highest" video-only is 1080p H.264.
        let playable = streams.filter { $0.isNativelyPlayable }
        let muxed = playable.filterVideoAndAudio().highestResolutionStream()
        let adaptive = playable.filterVideoOnly().highestResolutionStream()
        let muxedHeight = muxed?.videoResolution ?? 0
        let adaptiveHeight = adaptive?.videoResolution ?? 0

        // Merge only when it actually buys resolution. When YouTube happens to
        // mux the same height (or better), the single URL is both sharper-
        // equal and faster to start, so there is nothing to gain.
        // Apple TV HD: never merge. The composition is a second connection +
        // two moov round trips + an AVMutableComposition on a 2-core, 2 GB,
        // 1080p box, to lift a TRAILER from 720p — the muxed single URL is
        // the right trade there.
        if !PerformanceProfile.isLowPower, adaptiveHeight > muxedHeight, let adaptive,
           let audio = playable.filterAudioOnly().highestAudioBitrateStream(),
           let merged = await mergedItem(video: adaptive.url, audio: audio.url) {
            NSLog("[OrivioTrailer] %@: merged %dp (muxed best was %dp)",
                  youtubeKey, adaptiveHeight, muxedHeight)
            return merged
        }
        if let muxed {
            NSLog("[OrivioTrailer] %@: muxed %dp", youtubeKey, muxedHeight)
            return budgeted(AVPlayerItem(asset: asset(for: muxed.url)))
        }
        // No muxed stream at all — merge whatever the adaptive ladder offers,
        // even if the comparison above didn't favour it.
        if let adaptive,
           let audio = playable.filterAudioOnly().highestAudioBitrateStream(),
           let merged = await mergedItem(video: adaptive.url, audio: audio.url) {
            NSLog("[OrivioTrailer] %@: merged %dp (no muxed stream)", youtubeKey, adaptiveHeight)
            return merged
        }
        return nil
    }

    /// Bound AVPlayer's read-ahead on the constrained boxes. With no
    /// preference set it buffers at its own appetite — fine on 4 GB, but a
    /// trailer is a MUTED PREVIEW playing beside a browsing UI on the 2–3 GB
    /// boxes, and its buffer competes with poster decodes for the same RAM.
    @discardableResult
    private static func budgeted(_ item: AVPlayerItem) -> AVPlayerItem {
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            item.preferredForwardBufferDuration = 10
        }
        return item
    }

    /// googlevideo playback URLs are tied to the InnerTube CLIENT that
    /// extracted them (the `c=` query param) — YouTube serves them only to a
    /// matching User-Agent, and AVPlayer's default UA gets "Cannot Open"
    /// (-11828). Rebuild each request with the extracting client's UA.
    private static func asset(for url: URL) -> AVURLAsset {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value
        let userAgent: String
        switch client {
        case "ANDROID_VR":
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        case "ANDROID":
            userAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
        case "ANDROID_MUSIC":
            userAgent = "com.google.android.apps.youtube.music/5.16.51 (Linux; U; Android 11) gzip"
        default:
            userAgent = "Mozilla/5.0"
        }
        return AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]
        ])
    }

    /// Merge a remote video-only and audio-only track into one playable asset.
    ///
    /// `@MainActor` because `AVPlayerItem.init(asset:)` is main-actor isolated
    /// in the current SDK and this was calling it from a nonisolated async
    /// context — a warning today and a hard error under Swift 6. Nothing is
    /// blocked by the annotation: every expensive step in here is an `await`
    /// on AVFoundation's own loaders, which suspend rather than spin, and the
    /// one caller (`playerItem`) is already reached from a `.task` on main.
    @MainActor
    private static func mergedItem(video: URL, audio: URL) async -> AVPlayerItem? {
        let videoAsset = asset(for: video)
        let audioAsset = asset(for: audio)
        let composition = AVMutableComposition()
        do {
            // CONCURRENTLY. Each of these is a network round trip for the
            // asset's moov atom, and running them one after another is most of
            // what made a merged trailer slower to open than a muxed one —
            // which is why the muxed stream (and its 720p ceiling) used to be
            // preferred outright.
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let videoDuration = videoAsset.load(.duration)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)

            guard let vTrack = try await videoTracks.first else { return nil }
            let range = try await CMTimeRange(start: .zero, duration: videoDuration)
            let vComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try vComp?.insertTimeRange(range, of: vTrack, at: .zero)
            if let aTrack = try await audioTracks.first {
                let aComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                // The audio track can be a hair shorter than the video; clamp
                // so `insertTimeRange` can't throw on the tail and lose the
                // whole composition (and with it the 1080p path).
                let audioDuration = try await aTrack.load(.timeRange).duration
                let audioRange = CMTimeRange(start: .zero,
                                             duration: min(range.duration, audioDuration))
                try aComp?.insertTimeRange(audioRange, of: aTrack, at: .zero)
            }
            return budgeted(AVPlayerItem(asset: composition))
        } catch {
            NSLog("[OrivioTrailer] merge failed: %@", String(describing: error))
            return nil
        }
    }

    /// The backdrop trailer behind Home's hero and the Detail page.
    ///
    /// Resolution is chosen the same way `playerItem` chooses it — the merged
    /// adaptive pair when it beats the muxed ladder, which in practice means
    /// 1080p instead of 720p or worse. This used to take the muxed URL
    /// unconditionally "because the preview sits behind heavy scrims", but the
    /// Detail page plays this same item large and un-muted, so the ceiling was
    /// visible there.
    ///
    /// The client-matched User-Agent is baked in — see `asset(for:)`.
    /// Extraction is the slow step (seconds, the remote fallback especially),
    /// and the playback URLs it yields stay valid for hours — so remember
    /// them, and a title the browse comes BACK to starts its preview almost
    /// immediately instead of re-paying the extraction every visit.
    /// Guarded by `backdropCacheLock`: `backdropItem` is nonisolated async,
    /// so Home's hero layer and a Detail page opening at the same moment
    /// mutate these two dictionaries concurrently off the main actor —
    /// unsynchronised Dictionary mutation, i.e. a corrupted hash table.
    private static let backdropCacheLock = NSLock()

    /// What extraction settled on for one key. Both URLs are remembered, not
    /// just one, because the 1080p choice is a PAIR of adaptive streams —
    /// and `muxedFallback` keeps a single self-contained URL around so a
    /// failed merge degrades to a lower-resolution trailer WITH audio rather
    /// than to a silent one.
    private struct BackdropChoice {
        let video: URL
        let audio: URL?
        let muxedFallback: URL?
        let height: Int
        let at: Date
    }
    private static var backdropURLCache: [String: BackdropChoice] = [:]
    /// Conservative slice of googlevideo's ~6h link lifetime.
    private static let backdropURLTTL: TimeInterval = 30 * 60

    /// Keys whose extraction just failed, and when.
    ///
    /// Successes were remembered and failures were not, which is exactly
    /// backwards for load: every time the viewer's focus passed back over a
    /// title we could not extract, we asked YouTube again. Browsing a row of
    /// them is then a burst of failing requests from one address — and a burst
    /// is what earns a bot-check page, whose unparseable HTML is itself the
    /// `regexMatchError` that made the extraction fail. The retry storm feeds
    /// the thing causing it. Short enough that a genuinely transient failure
    /// costs one browse, long enough to stop the storm.
    private static var backdropFailureCache: [String: Date] = [:]
    private static let backdropFailureTTL: TimeInterval = 10 * 60

    static func backdropItem(youtubeKey: String) async -> AVPlayerItem? {
        let (cachedHit, cachedFailure) = backdropCacheLock.withLock {
            (backdropURLCache[youtubeKey], backdropFailureCache[youtubeKey])
        }
        if let hit = cachedHit,
           Date().timeIntervalSince(hit.at) < backdropURLTTL {
            return await backdropPlayerItem(hit)
        }
        if let failedAt = cachedFailure,
           Date().timeIntervalSince(failedAt) < backdropFailureTTL {
            return nil
        }
        // `.local` parses YouTube's own page, so it breaks whenever they
        // reshape it (it throws `regexMatchError`) and it is the first thing
        // to be served a bot-check page when one IP asks for many videos in a
        // row. Passing both methods in ONE call does not reliably fall
        // through — a local parse that throws can take the whole call with it
        // — so the remote extractor gets its own attempt.
        var streams: [YouTubeKit.Stream] = []
        do {
            streams = try await YouTube(videoID: youtubeKey, methods: [.local]).streams
        } catch {
            NSLog("[OrivioTrailer] local extraction failed for %@: %@ — trying remote",
                  youtubeKey, String(describing: error))
            do {
                streams = try await YouTube(videoID: youtubeKey, methods: [.remote]).streams
            } catch {
                NSLog("[OrivioTrailer] extraction failed for %@: %@", youtubeKey, String(describing: error))
                backdropCacheLock.withLock { backdropFailureCache[youtubeKey] = Date() }
                return nil
            }
        }
        let playable = streams.filter { $0.isNativelyPlayable }
        let muxed = playable.filterVideoAndAudio().highestResolutionStream()
        let adaptive = playable.filterVideoOnly().highestResolutionStream()
        let muxedHeight = muxed?.videoResolution ?? 0
        let adaptiveHeight = adaptive?.videoResolution ?? 0

        let choice: BackdropChoice
        // Apple TV HD: same rule as `playerItem` — the muxed single URL over
        // a two-connection composition merge (see the note there).
        if !PerformanceProfile.isLowPower, adaptiveHeight > muxedHeight, let adaptive {
            // 1080p: video-only plus its own audio track, merged at play time.
            choice = BackdropChoice(video: adaptive.url,
                                    audio: playable.filterAudioOnly().highestAudioBitrateStream()?.url,
                                    muxedFallback: muxed?.url,
                                    height: adaptiveHeight, at: Date())
        } else if let muxed {
            choice = BackdropChoice(video: muxed.url, audio: nil, muxedFallback: muxed.url,
                                    height: muxedHeight, at: Date())
        } else if let adaptive {
            choice = BackdropChoice(video: adaptive.url,
                                    audio: playable.filterAudioOnly().highestAudioBitrateStream()?.url,
                                    muxedFallback: nil,
                                    height: adaptiveHeight, at: Date())
        } else {
            backdropCacheLock.withLock { backdropFailureCache[youtubeKey] = Date() }
            return nil
        }
        backdropCacheLock.withLock { backdropURLCache[youtubeKey] = choice }
        NSLog("[OrivioTrailer] backdrop %@: %dp (%@)", youtubeKey, choice.height,
              choice.audio == nil ? "muxed" : "merged")
        return await backdropPlayerItem(choice)
    }

    /// Build the item for a resolved backdrop choice.
    ///
    /// `@MainActor` for the same reason `mergedItem` is: `AVPlayerItem.init`
    /// is main-actor isolated. A merge that fails falls back to the muxed URL
    /// — a lower-resolution trailer that still has SOUND, which matters
    /// because the Detail page un-mutes this item.
    @MainActor
    private static func backdropPlayerItem(_ choice: BackdropChoice) async -> AVPlayerItem? {
        guard let audio = choice.audio else {
            return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
        }
        if let merged = await mergedItem(video: choice.video, audio: audio) {
            return merged
        }
        if let fallback = choice.muxedFallback {
            NSLog("[OrivioTrailer] backdrop merge failed — falling back to the muxed stream")
            return budgeted(AVPlayerItem(asset: asset(for: fallback)))
        }
        return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
    }
}

/// A bare `AVPlayerLayer` with no transport chrome — used to play a trailer
/// silently behind the Detail hero. `.resizeAspectFill` so it fills the header
/// like the still backdrop it replaces.
struct BackdropVideoView: UIViewRepresentable {
    /// Optional so a host can keep the layer MOUNTED across previews and just
    /// swap what plays in it. Adding and removing this view mid-browse is a
    /// view-tree structural change, and the focus engine re-resolves on those
    /// — on Home that landed while the viewer was stepping through a row and
    /// left the focus lift stranded on the card they had already left.
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        // Decoration only. Inserting an interactive UIView into the hierarchy
        // makes the focus engine re-resolve, and on the detail page that threw
        // focus off Play and onto the synopsis the moment the backdrop trailer
        // started — the page appeared to grab the highlight on its own a
        // second after it opened. Same rule as the hero artwork.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Full-screen trailer playback. Resolves the YouTube key, then plays through
/// the native tvOS `VideoPlayer` transport. Menu (back) dismisses.
struct TrailerPlayerView: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let trailer: TMDBService.Trailer

    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    // Fully release on dismiss: pausing alone leaves the player
                    // registered as the system "Now Playing" item, so pressing
                    // Play/Pause later summons the tvOS transport overlay over
                    // whatever screen you're on. Clearing the item drops it.
                    .onDisappear {
                        player.pause()
                        player.replaceCurrentItem(with: nil)
                    }
            } else if failed {
                OrivioEmptyState(
                    icon: "play.slash.fill",
                    title: "Trailer unavailable",
                    message: "This trailer couldn't be loaded. Press Menu to go back."
                )
            } else {
                OrivioLoadingView(label: "Loading trailer")
            }
        }
        .onExitCommand { dismiss() }
        // Release on the CONTAINER, not the VideoPlayer branch: dismissing
        // while "Loading trailer" is still up means the VideoPlayer (and its
        // onDisappear) never existed — the resolved player then played on,
        // headless, and became the system Now Playing item.
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        .task {
            guard let item = await TrailerResolver.playerItem(youtubeKey: trailer.youtubeKey) else {
                failed = true
                return
            }
            // Dismissed during the (multi-second) extraction: never start.
            guard !Task.isCancelled else { return }
            let player = AVPlayer(playerItem: item)
            // Start on the first available buffer instead of waiting to build a
            // stall-proof one — a trailer should pop up, not spin.
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            player.play()
        }
    }
}
