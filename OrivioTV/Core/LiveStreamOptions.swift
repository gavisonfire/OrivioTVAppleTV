import Foundation

/// Everything a Live TV channel needs BESIDES its URL in order to actually
/// play: request headers, the manifest kind, and any DRM the playlist declares.
///
/// Real IPTV playlists carry this out-of-band, in directives the parser used to
/// skip outright. A channel whose CDN checks `User-Agent` or `Referer` simply
/// 403s without them, which reads to the viewer as a dead channel — so these
/// lines are the difference between "most links work" and "every link works".
///
/// Kept deliberately small and `Codable`: a favourited channel has to remember
/// its options or it would break the moment it was replayed from the
/// favourites row rather than from the playlist.
struct LiveStreamOptions: Codable, Hashable {
    /// Header name → value, sent with the media request.
    var headers: [String: String] = [:]
    /// `hls` / `dash` / `ism`, when the playlist states it. Only used to
    /// override a guess made from the file extension; a plain extensionless
    /// URL that declares `dash` is the case this exists for.
    var manifestType: String?
    /// DRM scheme the playlist declares, e.g. `com.widevine.alpha` or
    /// `clearkey`. Recorded so playback can say WHY it can't play rather than
    /// failing as a generic error — see `unsupportedDRMReason`.
    var licenseType: String?
    /// The license server URL or key payload. Never logged.
    var licenseKey: String?

    var isEmpty: Bool {
        headers.isEmpty && manifestType == nil && licenseType == nil && licenseKey == nil
    }

    /// Non-empty header map, or nil — the shape `StreamProxyHeaders` wants.
    var requestHeaders: [String: String]? { headers.isEmpty ? nil : headers }

    /// A human explanation when the channel is encrypted with something this
    /// app cannot decrypt, or nil when it is playable.
    ///
    /// ClearKey is deliberately NOT rejected: the key travels in the playlist
    /// itself, so it is a plain AES key rather than a DRM handshake, and the
    /// FFmpeg path can use it. Widevine and PlayReady need a CDM that tvOS
    /// does not expose to third-party apps at all.
    var unsupportedDRMReason: String? {
        guard let type = licenseType?.lowercased(), !type.isEmpty else { return nil }
        if type.contains("clearkey") { return nil }
        if type.contains("widevine") {
            return "This channel is protected by Widevine DRM, which tvOS doesn't let third-party apps decrypt."
        }
        if type.contains("playready") {
            return "This channel is protected by PlayReady DRM, which tvOS doesn't support."
        }
        if type.contains("fairplay") {
            // FairPlay IS an Apple scheme, but it needs a certificate exchange
            // with the provider's key server that a generic IPTV playlist
            // never supplies. Honest message beats a silent failure.
            return "This channel uses FairPlay DRM and needs credentials this playlist doesn't include."
        }
        return "This channel is protected by DRM (\(type)), which isn't supported."
    }

    /// Merge another set in, with `other` winning on conflicts. Used to layer
    /// the URL's own `|`-suffixed parameters over the directive lines.
    mutating func merge(_ other: LiveStreamOptions) {
        for (key, value) in other.headers { headers[key] = value }
        manifestType = other.manifestType ?? manifestType
        licenseType = other.licenseType ?? licenseType
        licenseKey = other.licenseKey ?? licenseKey
    }

    /// Canonical capitalisation for the headers that matter, so two spellings
    /// of the same header can't both be sent.
    ///
    /// Playlists write `user-agent`, `User-Agent` and `USER-AGENT`
    /// interchangeably, and HTTP header names are case-insensitive — but a
    /// dictionary is not, so without this a channel could end up sending two
    /// User-Agent lines, which some CDNs reject outright. The same hazard is
    /// called out on the add-on header path in PlayerViewModel.
    static func canonicalHeaderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "user-agent": return "User-Agent"
        case "referer", "referrer": return "Referer"   // HTTP spells it with one R
        case "origin": return "Origin"
        case "cookie": return "Cookie"
        case "authorization": return "Authorization"
        case "x-forwarded-for": return "X-Forwarded-For"
        default: return trimmed
        }
    }

    mutating func setHeader(_ name: String, _ value: String) {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        headers[Self.canonicalHeaderName(name)] = value
    }

    /// Parse an `a=b&c=d` blob (Kodi's `stream_headers`, and the tail of a
    /// `|`-suffixed URL) into headers.
    mutating func absorbHeaderQuery(_ query: String) {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            setHeader(parts[0], parts[1].removingPercentEncoding ?? parts[1])
        }
    }
}

/// How a Live TV URL should be opened.
enum LiveStreamKind {
    /// Anything AVPlayer can open directly (HLS, progressive MP4).
    case native
    /// Needs the FFmpeg demuxer: DASH, raw MPEG-TS, RTMP/RTSP/UDP/RTP, and
    /// anything whose container AVPlayer doesn't read.
    case demuxer
    /// A page link that has to be resolved to a media URL first (YouTube).
    case resolvable
}

enum LiveStreamClassifier {
    /// Schemes AVFoundation cannot open at all. FFmpeg handles every one of
    /// these, so they must never be routed to the native player — with the
    /// engine preference set to Native they would otherwise fail outright
    /// instead of falling back.
    static let demuxerOnlySchemes: Set<String> = [
        "rtmp", "rtmpe", "rtmps", "rtmpt", "rtsp", "rtsps", "rtp",
        "udp", "mms", "mmsh", "mmst", "srt", "rist"
    ]

    /// Containers AVPlayer reads natively. Everything else goes to FFmpeg.
    private static let nativeExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov", "mp3", "aac"]

    static func isYouTube(_ raw: String) -> Bool { youTubeID(from: raw) != nil }

    /// The 11-character video id in any of YouTube's link shapes, or nil.
    ///
    /// Live channels in community playlists are routinely just a YouTube link
    /// — a 24/7 news stream, a relay. Handing that URL to a media player gets
    /// an HTML page, so it has to be extracted first (the app already does
    /// exactly this for trailers).
    static func youTubeID(from raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let host = url.host?.lowercased() else { return nil }
        let isYouTubeHost = host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be")
            || host.hasSuffix("youtube-nocookie.com")
        guard isYouTubeHost else { return nil }

        if host.hasSuffix("youtu.be") {
            let id = url.lastPathComponent
            return isPlausibleID(id) ? id : nil
        }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, isPlausibleID(v) {
            return v
        }
        // /embed/<id>, /live/<id>, /shorts/<id>, /v/<id>
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, ["embed", "live", "shorts", "v"].contains(parts[0].lowercased()),
           isPlausibleID(parts[1]) {
            return parts[1]
        }
        return nil
    }

    private static func isPlausibleID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// How to open this URL, given whatever the playlist declared about it.
    static func kind(for raw: String, options: LiveStreamOptions) -> LiveStreamKind {
        if isYouTube(raw) { return .resolvable }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let scheme = URL(string: trimmed)?.scheme?.lowercased()
            ?? trimmed.split(separator: ":").first.map { $0.lowercased() } ?? ""
        if demuxerOnlySchemes.contains(scheme) { return .demuxer }

        // An explicit manifest_type outranks the extension: a DASH manifest
        // served from an extensionless URL is common, and guessing "native"
        // for it means AVPlayer opens an XML document and reports a decode
        // failure.
        if let manifest = options.manifestType?.lowercased() {
            if manifest.contains("dash") || manifest.contains("mpd") || manifest.contains("ism") {
                return .demuxer
            }
            if manifest.contains("hls") { return .native }
        }
        let ext = (URL(string: trimmed)?.pathExtension ?? "").lowercased()
        if ext.isEmpty { return .demuxer }
        return nativeExtensions.contains(ext) ? .native : .demuxer
    }

    /// Strip the `|Header=Value&Header2=Value2` suffix some playlists append
    /// to the URL itself, returning the bare URL plus the options it carried.
    ///
    /// This is a real convention (VLC and several IPTV apps honour it), and
    /// left in place the pipe makes the whole string an invalid URL — so the
    /// channel fails to open for a reason nothing reports.
    static func splitPipedOptions(_ raw: String) -> (url: String, options: LiveStreamOptions) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let pipe = trimmed.firstIndex(of: "|") else { return (trimmed, LiveStreamOptions()) }
        var options = LiveStreamOptions()
        options.absorbHeaderQuery(String(trimmed[trimmed.index(after: pipe)...]))
        return (String(trimmed[trimmed.startIndex..<pipe]), options)
    }
}
