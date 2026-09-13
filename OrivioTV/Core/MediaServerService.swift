import Foundation

// MARK: - Model

/// A personal media server the viewer has connected: a Plex Media Server or
/// a Jellyfin server. Its movies and shows show up as a Library tab and play
/// straight from the server's own files.
enum MediaServerKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case plex, jellyfin

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        }
    }
    var icon: String {
        switch self {
        case .plex: return "play.rectangle.on.rectangle.fill"
        case .jellyfin: return "server.rack"
        }
    }
    /// Meta ids for items from this server: `plex:<ratingKey>`, `jellyfin:<Id>`.
    var idPrefix: String { rawValue + ":" }

    static func kind(ofMetaID id: String) -> MediaServerKind? {
        allCases.first { id.hasPrefix($0.idPrefix) }
    }
}

struct MediaServerAccount: Codable, Equatable {
    var kind: MediaServerKind
    /// "http://192.168.1.10:32400" — no trailing slash.
    var serverURL: String
    /// X-Plex-Token for that server, or the Jellyfin access token.
    var token: String
    /// Jellyfin user id (its item endpoints are per user).
    var userID: String? = nil
    var serverName: String? = nil
    var username: String? = nil

    var isConfigured: Bool { !serverURL.isEmpty && !token.isEmpty }
}

/// One movie, show or episode on a media server, with what the player needs.
struct MediaServerItem: Identifiable, Hashable {
    let kind: MediaServerKind
    /// Plex ratingKey / Jellyfin Id.
    let serverItemID: String
    let title: String
    var year: Int? = nil
    var poster: String? = nil
    var backdrop: String? = nil
    var overview: String? = nil
    var isSeries: Bool = false
    var durationSeconds: Double? = nil
    // Episodes only.
    var season: Int? = nil
    var episode: Int? = nil
    var showTitle: String? = nil
    var showID: String? = nil
    /// Plex: the part key ("/library/parts/…"); Jellyfin: unused (the id is
    /// enough to build the stream URL).
    var streamPath: String? = nil
    var fileName: String? = nil

    var id: String { kind.idPrefix + serverItemID }
    var isEpisode: Bool { season != nil || episode != nil }

    /// The app-wide meta shape, so the poster cards and the player can use it.
    var metaItem: MetaItem {
        MetaItem(
            id: id, type: isSeries ? "series" : "movie", name: title,
            poster: poster, background: backdrop ?? poster,
            description: overview, releaseInfo: year.map(String.init),
            runtime: durationSeconds.map { "\(Int($0 / 60)) min" }
        )
    }

    /// The episode shape for a show's `videos`.
    var metaVideo: MetaVideo {
        MetaVideo(id: id, title: title, season: season, episode: episode,
                  thumbnail: poster, overview: overview)
    }
}

// MARK: - Store

/// The connected servers, one of each kind, persisted device-wide.
@MainActor
final class MediaServerStore: ObservableObject {
    @Published var plex: MediaServerAccount? { didSet { if plex != oldValue { save() } } }
    @Published var jellyfin: MediaServerAccount? { didSet { if jellyfin != oldValue { save() } } }

    private static let key = "orivio.mediaservers.v1"
    private struct Blob: Codable { var plex: MediaServerAccount?; var jellyfin: MediaServerAccount? }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let blob = try? JSONDecoder().decode(Blob.self, from: data) {
            plex = blob.plex
            jellyfin = blob.jellyfin
        }
    }

    private func save() {
        let blob = Blob(plex: plex, jellyfin: jellyfin)
        if let data = try? JSONEncoder().encode(blob) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func account(for kind: MediaServerKind) -> MediaServerAccount? {
        switch kind {
        case .plex: return plex?.isConfigured == true ? plex : nil
        case .jellyfin: return jellyfin?.isConfigured == true ? jellyfin : nil
        }
    }

    func set(_ account: MediaServerAccount?, for kind: MediaServerKind) {
        switch kind {
        case .plex: plex = account
        case .jellyfin: jellyfin = account
        }
    }

    /// The kinds with a working connection, in tab order.
    var connected: [MediaServerKind] {
        MediaServerKind.allCases.filter { account(for: $0) != nil }
    }
}

// MARK: - Plex

/// plex.tv PIN sign-in, server discovery, and the server's own library API.
enum PlexService {
    static let product = "Orivio TV"

    /// One stable identifier per install: plex.tv ties the PIN and the
    /// resulting token to it.
    static var clientIdentifier: String {
        let key = "orivio.plex.clientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static func headers(token: String? = nil) -> [String: String] {
        var h = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": "1.0",
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Platform": "tvOS",
            "X-Plex-Device": "Apple TV",
            "X-Plex-Device-Name": "Apple TV"
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }

    private static func request(_ url: URL, method: String = "GET", token: String? = nil,
                                timeout: TimeInterval? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    // MARK: Sign-in (plex.tv/link)

    struct Pin {
        let id: Int
        let code: String
        let expiresAt: Date
        /// Where the viewer enters the code.
        static let linkURL = "https://plex.tv/link"
    }

    /// A 4-character code for plex.tv/link.
    static func requestPin() async -> Pin? {
        struct Response: Decodable { let id: Int?; let code: String?; let expiresAt: String? }
        guard let url = URL(string: "https://plex.tv/api/v2/pins?strong=false") else { return nil }
        let req = request(url, method: "POST")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = try? JSONDecoder().decode(Response.self, from: data),
              let id = body.id, let code = body.code else { return nil }
        let expires = body.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? Date().addingTimeInterval(15 * 60)
        return Pin(id: id, code: code, expiresAt: expires)
    }

    /// The account token once the code has been entered; nil while pending.
    static func pollPin(_ pin: Pin) async -> String? {
        struct Response: Decodable { let authToken: String? }
        guard let url = URL(string: "https://plex.tv/api/v2/pins/\(pin.id)") else { return nil }
        let req = request(url)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = try? JSONDecoder().decode(Response.self, from: data),
              let token = body.authToken, !token.isEmpty else { return nil }
        return token
    }

    // MARK: Servers

    struct ServerCandidate: Identifiable {
        struct Connection { let uri: String; let local: Bool; let relay: Bool }
        let id: String
        let name: String
        /// The server-specific token (differs from the account token on a
        /// server shared with you).
        let accessToken: String?
        let connections: [Connection]
    }

    /// The account's servers, from plex.tv.
    static func servers(token: String) async -> [ServerCandidate] {
        struct Resource: Decodable {
            struct Conn: Decodable { let uri: String?; let local: Bool?; let relay: Bool? }
            let name: String?; let provides: String?; let accessToken: String?
            let clientIdentifier: String?; let connections: [Conn]?
        }
        guard let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=0")
        else { return [] }
        let req = request(url, token: token)
        guard let (data, _) = try? await session.data(for: req),
              let resources = try? JSONDecoder().decode([Resource].self, from: data) else { return [] }
        return resources.compactMap { r in
            guard (r.provides ?? "").split(separator: ",").contains("server") else { return nil }
            let conns = (r.connections ?? []).compactMap { c -> ServerCandidate.Connection? in
                guard let uri = c.uri, !uri.isEmpty else { return nil }
                return .init(uri: uri, local: c.local ?? false, relay: c.relay ?? false)
            }
            return ServerCandidate(id: r.clientIdentifier ?? r.name ?? UUID().uuidString,
                                   name: r.name ?? "Plex Media Server",
                                   accessToken: r.accessToken, connections: conns)
        }
    }

    /// The first address that answers: LAN first, then direct remote, then
    /// the relay.
    static func reachableURL(_ server: ServerCandidate, token: String) async -> String? {
        let ordered = server.connections.filter(\.local)
            + server.connections.filter { !$0.local && !$0.relay }
            + server.connections.filter(\.relay)
        for conn in ordered {
            guard let url = URL(string: conn.uri + "/identity") else { continue }
            let req = request(url, token: token, timeout: 5)
            if let (_, response) = try? await session.data(for: req),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return conn.uri
            }
        }
        return nil
    }

    // MARK: Library

    private struct Container<T: Decodable>: Decodable {
        let container: T
        private enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
    }
    private struct Sections: Decodable {
        let directories: [Directory]?
        private enum CodingKeys: String, CodingKey { case directories = "Directory" }
        struct Directory: Decodable { let key: String?; let type: String?; let title: String? }
    }
    private struct MetadataList: Decodable {
        let items: [Metadata]?
        private enum CodingKeys: String, CodingKey { case items = "Metadata" }
    }
    private struct Metadata: Decodable {
        let ratingKey: String?; let type: String?; let title: String?; let year: Int?
        let thumb: String?; let art: String?; let summary: String?; let duration: Double?
        let index: Int?; let parentIndex: Int?
        let grandparentTitle: String?; let grandparentRatingKey: String?; let grandparentThumb: String?
        let media: [Media]?
        private enum CodingKeys: String, CodingKey {
            case ratingKey, type, title, year, thumb, art, summary, duration, index, parentIndex
            case grandparentTitle, grandparentRatingKey, grandparentThumb
            case media = "Media"
        }
        struct Media: Decodable {
            let parts: [Part]?
            private enum CodingKeys: String, CodingKey { case parts = "Part" }
        }
        struct Part: Decodable { let key: String?; let file: String? }
    }

    private static func get<T: Decodable>(_ account: MediaServerAccount, _ path: String) async -> T? {
        guard let url = URL(string: account.serverURL + path) else { return nil }
        let req = request(url, token: account.token)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            NSLog("[MediaServer] plex GET %@ failed", path)
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func imageURL(_ account: MediaServerAccount, _ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return account.serverURL + path + (path.contains("?") ? "&" : "?") + "X-Plex-Token=" + account.token
    }

    private static func item(_ account: MediaServerAccount, _ m: Metadata) -> MediaServerItem? {
        guard let key = m.ratingKey, let title = m.title else { return nil }
        let part = m.media?.first?.parts?.first
        let isEpisode = m.type == "episode"
        return MediaServerItem(
            kind: .plex, serverItemID: key, title: title, year: m.year,
            poster: imageURL(account, m.thumb),
            backdrop: imageURL(account, m.art ?? (isEpisode ? nil : m.thumb)),
            overview: m.summary, isSeries: m.type == "show",
            durationSeconds: m.duration.map { $0 / 1000 },
            season: isEpisode ? m.parentIndex : nil,
            episode: isEpisode ? m.index : nil,
            showTitle: m.grandparentTitle, showID: m.grandparentRatingKey,
            streamPath: part?.key,
            fileName: part?.file.map { ($0 as NSString).lastPathComponent }
        )
    }

    /// Every movie (or every show) across the server's libraries of that type.
    /// nil = the server didn't answer; [] = it answered with nothing.
    static func libraryItems(_ account: MediaServerAccount, series: Bool) async -> [MediaServerItem]? {
        guard let sections: Container<Sections> = await get(account, "/library/sections") else { return nil }
        let wanted = series ? "show" : "movie"
        var out: [MediaServerItem] = []
        var seen = Set<String>()
        for dir in sections.container.directories ?? [] where dir.type == wanted {
            guard let key = dir.key else { continue }
            guard let list: Container<MetadataList> = await get(account, "/library/sections/\(key)/all") else { continue }
            for m in list.container.items ?? [] {
                if let item = item(account, m), seen.insert(item.id).inserted { out.append(item) }
            }
        }
        return out
    }

    /// Every episode of a show, in season/episode order.
    static func episodes(_ account: MediaServerAccount, showID: String) async -> [MediaServerItem] {
        guard let list: Container<MetadataList> = await get(account, "/library/metadata/\(showID)/allLeaves")
        else { return [] }
        return (list.container.items ?? []).compactMap { item(account, $0) }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    /// One item by ratingKey (a movie, show or episode).
    static func item(_ account: MediaServerAccount, id: String) async -> MediaServerItem? {
        guard let list: Container<MetadataList> = await get(account, "/library/metadata/\(id)") else { return nil }
        return (list.container.items ?? []).compactMap { item(account, $0) }.first
    }

    /// The file itself, played straight off the server.
    static func streamEntry(_ account: MediaServerAccount, _ item: MediaServerItem) -> StreamEntry? {
        guard let path = item.streamPath else { return nil }
        let url = account.serverURL + path + (path.contains("?") ? "&" : "?") + "X-Plex-Token=" + account.token
        let stream = Stream(
            name: "Plex", title: item.title, description: item.fileName,
            url: url, infoHash: nil,
            behaviorHints: StreamBehaviorHints(filename: item.fileName,
                                               proxyHeaders: StreamProxyHeaders(request: ["X-Plex-Token": account.token]))
        )
        return StreamEntry(addonName: account.serverName ?? "Plex", stream: stream)
    }
}

// MARK: - Jellyfin

/// Username/password sign-in and the per-user library API.
enum JellyfinService {
    static let client = "Orivio TV"

    static var deviceID: String {
        let key = "orivio.jellyfin.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static func authorization(token: String?) -> String {
        var value = "MediaBrowser Client=\"\(client)\", Device=\"Apple TV\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
        if let token, !token.isEmpty { value += ", Token=\"\(token)\"" }
        return value
    }

    private static func request(_ url: URL, method: String = "GET", token: String? = nil,
                                body: Data? = nil, timeout: TimeInterval? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authorization(token: token), forHTTPHeaderField: "Authorization")
        if let token, !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// "192.168.1.10:8096" → "http://192.168.1.10:8096"; nil when unusable.
    static func normalizedServerURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return text
    }

    /// The server's name, if it answers.
    static func serverName(_ serverURL: String) async -> String? {
        struct Info: Decodable { let serverName: String?
            private enum CodingKeys: String, CodingKey { case serverName = "ServerName" } }
        guard let url = URL(string: serverURL + "/System/Info/Public") else { return nil }
        let req = request(url, timeout: 8)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
        return info.serverName ?? "Jellyfin"
    }

    /// Sign in; the message explains a failure.
    static func authenticate(serverURL: String, username: String, password: String) async
        -> (account: MediaServerAccount?, message: String) {
        struct Auth: Decodable {
            struct User: Decodable { let id: String?; let name: String?
                private enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" } }
            let accessToken: String?; let user: User?
            private enum CodingKeys: String, CodingKey { case accessToken = "AccessToken", user = "User" }
        }
        guard let url = URL(string: serverURL + "/Users/AuthenticateByName") else {
            return (nil, "That server address doesn't look right.")
        }
        let body = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let req = request(url, method: "POST", body: body)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            return (nil, "Couldn't reach the server. Check the address and that it's on.")
        }
        guard (200..<300).contains(http.statusCode) else {
            return (nil, http.statusCode == 401 ? "Wrong username or password." : "The server answered HTTP \(http.statusCode).")
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data),
              let token = auth.accessToken, let userID = auth.user?.id else {
            return (nil, "The server's reply couldn't be read.")
        }
        let name = await serverName(serverURL)
        return (MediaServerAccount(kind: .jellyfin, serverURL: serverURL, token: token, userID: userID,
                                   serverName: name, username: auth.user?.name ?? username), "Connected.")
    }

    // MARK: Library

    private struct Items: Decodable {
        let items: [Item]?
        private enum CodingKeys: String, CodingKey { case items = "Items" }
    }
    private struct Item: Decodable {
        let id: String?; let name: String?; let type: String?; let productionYear: Int?
        let overview: String?; let runTimeTicks: Int64?; let indexNumber: Int?; let parentIndexNumber: Int?
        let seriesName: String?; let seriesId: String?; let imageTags: [String: String]?
        let backdropImageTags: [String]?; let path: String?; let seriesPrimaryImageTag: String?
        private enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", type = "Type", productionYear = "ProductionYear"
            case overview = "Overview", runTimeTicks = "RunTimeTicks", indexNumber = "IndexNumber"
            case parentIndexNumber = "ParentIndexNumber", seriesName = "SeriesName", seriesId = "SeriesId"
            case imageTags = "ImageTags", backdropImageTags = "BackdropImageTags", path = "Path"
            case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        }
    }

    private static func get<T: Decodable>(_ account: MediaServerAccount, _ path: String) async -> T? {
        guard let url = URL(string: account.serverURL + path) else { return nil }
        let req = request(url, token: account.token)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            NSLog("[MediaServer] jellyfin GET %@ failed", path)
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func imageURL(_ account: MediaServerAccount, itemID: String, kind: String, tag: String?) -> String? {
        var url = account.serverURL + "/Items/\(itemID)/Images/\(kind)?maxHeight=720&api_key=\(account.token)"
        if let tag { url += "&tag=\(tag)" }
        return url
    }

    private static func item(_ account: MediaServerAccount, _ i: Item) -> MediaServerItem? {
        guard let id = i.id, let name = i.name else { return nil }
        let isEpisode = i.type == "Episode"
        let primary = i.imageTags?["Primary"]
        let poster: String? = primary != nil
            ? imageURL(account, itemID: id, kind: "Primary", tag: primary)
            : (isEpisode && i.seriesId != nil ? imageURL(account, itemID: i.seriesId!, kind: "Primary", tag: i.seriesPrimaryImageTag) : nil)
        let backdrop: String? = (i.backdropImageTags?.isEmpty == false)
            ? imageURL(account, itemID: id, kind: "Backdrop", tag: i.backdropImageTags?.first)
            : nil
        return MediaServerItem(
            kind: .jellyfin, serverItemID: id, title: name, year: i.productionYear,
            poster: poster, backdrop: backdrop, overview: i.overview,
            isSeries: i.type == "Series",
            durationSeconds: i.runTimeTicks.map { Double($0) / 10_000_000 },
            season: isEpisode ? i.parentIndexNumber : nil,
            episode: isEpisode ? i.indexNumber : nil,
            showTitle: i.seriesName, showID: i.seriesId,
            streamPath: nil,
            fileName: i.path.map { ($0 as NSString).lastPathComponent }
        )
    }

    /// nil = the server didn't answer; [] = it answered with nothing. Paged —
    /// a flat Limit silently truncated big libraries at the cap.
    static func libraryItems(_ account: MediaServerAccount, series: Bool) async -> [MediaServerItem]? {
        guard let userID = account.userID else { return [] }
        let type = series ? "Series" : "Movie"
        let page = 1000
        var out: [MediaServerItem] = []
        var seen = Set<String>()
        var start = 0
        while start < 20_000 {   // safety ceiling
            let path = "/Users/\(userID)/Items?IncludeItemTypes=\(type)&Recursive=true"
                + "&Fields=Overview,ProductionYear,RunTimeTicks,Path&SortBy=SortName&SortOrder=Ascending"
                + "&Limit=\(page)&StartIndex=\(start)"
            guard let list: Items = await get(account, path) else {
                // The FIRST page failing means the server is unreachable; a
                // later page failing still delivers what arrived.
                return start == 0 ? nil : out
            }
            let batch = (list.items ?? []).compactMap { item(account, $0) }.filter { seen.insert($0.id).inserted }
            out.append(contentsOf: batch)
            if (list.items ?? []).count < page { break }
            start += page
        }
        return out
    }

    static func episodes(_ account: MediaServerAccount, showID: String) async -> [MediaServerItem] {
        guard let userID = account.userID else { return [] }
        let path = "/Shows/\(showID)/Episodes?UserId=\(userID)&Fields=Overview,RunTimeTicks,Path"
        guard let list: Items = await get(account, path) else { return [] }
        return (list.items ?? []).compactMap { item(account, $0) }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    static func item(_ account: MediaServerAccount, id: String) async -> MediaServerItem? {
        guard let userID = account.userID else { return nil }
        guard let i: Item = await get(account, "/Users/\(userID)/Items/\(id)") else { return nil }
        return item(account, i)
    }

    /// The original file (`static=true`), no transcode.
    static func streamEntry(_ account: MediaServerAccount, _ item: MediaServerItem) -> StreamEntry? {
        let url = account.serverURL + "/Videos/\(item.serverItemID)/stream?static=true&api_key=\(account.token)"
        let stream = Stream(
            name: "Jellyfin", title: item.title, description: item.fileName,
            url: url, infoHash: nil,
            behaviorHints: StreamBehaviorHints(filename: item.fileName,
                                               proxyHeaders: StreamProxyHeaders(request: ["X-Emby-Token": account.token]))
        )
        return StreamEntry(addonName: account.serverName ?? "Jellyfin", stream: stream)
    }
}

// MARK: - Playback

/// Builds player requests for server items, and resumes them from Continue
/// Watching — the ids (`plex:…`, `jellyfin:…`) mean nothing to the add-ons
/// the normal resume path scrapes.
enum MediaServerPlayback {
    static func streamEntry(_ account: MediaServerAccount, _ item: MediaServerItem) -> StreamEntry? {
        switch account.kind {
        case .plex: return PlexService.streamEntry(account, item)
        case .jellyfin: return JellyfinService.streamEntry(account, item)
        }
    }

    static func episodes(_ account: MediaServerAccount, showID: String) async -> [MediaServerItem] {
        switch account.kind {
        case .plex: return await PlexService.episodes(account, showID: showID)
        case .jellyfin: return await JellyfinService.episodes(account, showID: showID)
        }
    }

    static func item(_ account: MediaServerAccount, id: String) async -> MediaServerItem? {
        switch account.kind {
        case .plex: return await PlexService.item(account, id: id)
        case .jellyfin: return await JellyfinService.item(account, id: id)
        }
    }

    /// A movie.
    static func request(movie: MediaServerItem, account: MediaServerAccount,
                        resumePosition: Double?) -> PlaybackRequest? {
        guard let entry = streamEntry(account, movie) else { return nil }
        return PlaybackRequest(meta: movie.metaItem, video: nil, entry: entry,
                               allEntries: [entry], resumePosition: resumePosition)
    }

    /// An episode, with the show's whole episode list riding along so Up Next
    /// and the in-player episode list work, and a resolver that hands the
    /// player the next episode's file instead of an add-on sweep.
    static func request(episode: MediaServerItem, show: MediaServerItem, episodes: [MediaServerItem],
                        account: MediaServerAccount, resumePosition: Double?) -> PlaybackRequest? {
        guard let entry = streamEntry(account, episode) else { return nil }
        var meta = show.metaItem
        meta = MetaItem(id: meta.id, type: "series", name: meta.name, poster: meta.poster,
                        background: meta.background, logo: nil, description: meta.description,
                        releaseInfo: meta.releaseInfo, videos: episodes.map(\.metaVideo))
        let byID = Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var request = PlaybackRequest(meta: meta, video: episode.metaVideo, entry: entry,
                                      allEntries: [entry], resumePosition: resumePosition)
        request.directEpisodeResolver = { video in
            guard let item = byID[video.id] else { return nil }
            return streamEntry(account, item)
        }
        return request
    }

    /// Continue Watching → play again from the server.
    @MainActor
    static func resume(_ progress: WatchProgress, store: MediaServerStore, fromBeginning: Bool) async -> PlaybackRequest? {
        guard let kind = MediaServerKind.kind(ofMetaID: progress.metaID),
              let account = store.account(for: kind) else { return nil }
        let position: Double? = fromBeginning ? nil : progress.positionSeconds
        let metaServerID = String(progress.metaID.dropFirst(kind.idPrefix.count))
        if progress.season != nil || progress.episode != nil {
            let episodeServerID = progress.id.hasPrefix(kind.idPrefix)
                ? String(progress.id.dropFirst(kind.idPrefix.count)) : nil
            async let showFetch = item(account, id: metaServerID)
            async let episodesFetch = episodes(account, showID: metaServerID)
            guard let show = await showFetch else { return nil }
            let episodes = await episodesFetch
            let episode = episodes.first { $0.serverItemID == episodeServerID }
                ?? episodes.first { $0.season == progress.season && $0.episode == progress.episode }
            guard let episode else { return nil }
            return request(episode: episode, show: show, episodes: episodes, account: account,
                           resumePosition: position)
        }
        guard let movie = await item(account, id: metaServerID) else { return nil }
        return request(movie: movie, account: account, resumePosition: position)
    }
}
