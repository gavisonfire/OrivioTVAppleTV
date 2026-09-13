import Foundation

/// A favourited Live TV channel, stored whole.
///
/// Deliberately a full snapshot rather than an id: the Favourites row has to
/// draw (and play) a channel BEFORE the IPTV playlist has loaded — on Home it
/// may never load at all, since that tab is not mounted — and an id alone
/// would leave the row blank until a several-megabyte M3U came down. The
/// channel's own fields are all it takes to build a `LiveChannel` again.
struct FavoriteChannel: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var logo: String?
    var group: String
    /// Direct stream URL, for M3U channels. nil for an add-on channel, which
    /// goes back through the source picker via `metaID`.
    var directURL: String?
    /// The add-on catalog item's id, when this came from a `tv` catalog.
    var metaID: String?
    var metaType: String?
    /// Playback options (headers / manifest type / DRM) for a direct-URL
    /// channel. Optional so a favourite stored before this existed still
    /// decodes — and so a favourited channel keeps working when it is replayed
    /// from the favourites row instead of from the playlist, which is the only
    /// place these values would otherwise be available.
    var options: LiveStreamOptions?
    /// Also pinned to the home screen.
    var onHome: Bool = false
    var addedAt: Date = Date()

    /// Tolerant decode: a blob written before a field existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        logo = try? c.decodeIfPresent(String.self, forKey: .logo)
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        directURL = try? c.decodeIfPresent(String.self, forKey: .directURL)
        metaID = try? c.decodeIfPresent(String.self, forKey: .metaID)
        metaType = try? c.decodeIfPresent(String.self, forKey: .metaType)
        options = (try? c.decodeIfPresent(LiveStreamOptions.self, forKey: .options)) ?? nil
        onHome = (try? c.decode(Bool.self, forKey: .onHome)) ?? false
        addedAt = (try? c.decode(Date.self, forKey: .addedAt)) ?? Date()
    }

    init(id: String, name: String, logo: String?, group: String,
         directURL: String?, metaID: String?, metaType: String?,
         options: LiveStreamOptions? = nil,
         onHome: Bool = false, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.logo = logo
        self.group = group
        self.directURL = directURL
        self.metaID = metaID
        self.metaType = metaType
        self.options = options
        self.onHome = onHome
        self.addedAt = addedAt
    }
}

/// Favourited Live TV channels, and which of them are pinned to Home.
///
/// Per profile, like every other personal list (the household's two viewers do
/// not watch the same channels). Profile 1 keeps the unsuffixed key so an
/// existing install carries over, matching `AddonManager` / `LibraryStore`.
@MainActor
final class LiveChannelFavorites: ObservableObject {
    static let shared = LiveChannelFavorites()

    /// Newest first — a channel favourited just now is the one being looked
    /// for, and the row is horizontal, so the front of it is what's on screen.
    @Published private(set) var channels: [FavoriteChannel] = []

    /// Fired on any local edit, so Home can re-render its pinned row.
    var onLocalChange: (() -> Void)?

    private static let storageKey = "orivio.livetv.favorites.v1"
    private static let removedKey = "orivio.livetv.favorites.removed.v1"
    private static let activeProfileKey = "orivio.profiles.active"
    /// Same life as the collections tombstones: long enough to outlive delete
    /// propagation, short enough that a genuine re-favourite always wins.
    private static let removalTombstoneLife: TimeInterval = 30 * 24 * 60 * 60

    /// Unfavourite tombstones, per profile. `applyRemote` is a UNION — an
    /// account blob still carrying a channel this box removed would put it
    /// straight back (and the next push re-uploaded it), so an unfavourite
    /// ping-ponged between devices forever. The tombstone keeps the removal
    /// standing until the account's copy stops listing the channel.
    private var removedAt: [String: Date] = [:]

    private(set) var profileID: Int

    private init() {
        profileID = UserDefaults.standard.object(forKey: Self.activeProfileKey) as? Int ?? 1
        load()
    }

    private var scopedKey: String {
        profileID == 1 ? Self.storageKey : "\(Self.storageKey).p\(profileID)"
    }

    private var scopedRemovedKey: String {
        profileID == 1 ? Self.removedKey : "\(Self.removedKey).p\(profileID)"
    }

    // MARK: - Reads

    func isFavorite(_ id: String) -> Bool { channels.contains { $0.id == id } }
    func isOnHome(_ id: String) -> Bool { channels.first { $0.id == id }?.onHome ?? false }

    /// The channels pinned to the home screen, newest first.
    var homeChannels: [FavoriteChannel] { channels.filter(\.onHome) }

    // MARK: - Mutations

    func toggleFavorite(_ channel: FavoriteChannel) {
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels.remove(at: index)
            removedAt[channel.id] = Date()
            persistRemoved()
        } else {
            var entry = channel
            entry.addedAt = Date()
            channels.insert(entry, at: 0)
            // Favouriting again is an explicit undo of the removal.
            if removedAt.removeValue(forKey: channel.id) != nil { persistRemoved() }
        }
        persist()
    }

    /// Pin/unpin an already-favourited channel on Home. Favouriting first is
    /// the rule the hold menu enforces — "Add to Home" only appears on a
    /// channel that is already a favourite — but a channel pinned directly
    /// still becomes one, rather than sitting on Home and nowhere else.
    func toggleOnHome(_ channel: FavoriteChannel) {
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index].onHome.toggle()
        } else {
            var entry = channel
            entry.addedAt = Date()
            entry.onHome = true
            channels.insert(entry, at: 0)
        }
        persist()
    }

    // MARK: - Profile scope

    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        load()
    }

    /// Forget a deleted profile's favourites so a recycled profile id doesn't
    /// inherit them (`ProfileStore.purgeProfileData` sweeps the `.p<id>` key
    /// too; this covers the in-memory copy when the deleted profile is live).
    func forgetProfile(_ id: Int) {
        UserDefaults.standard.removeObject(forKey: "\(Self.storageKey).p\(id)")
        if id == profileID { load() }
    }

    // MARK: - Sync bridge

    /// The list as it rides in the account's per-profile preferences blob.
    var snapshot: [FavoriteChannel] { channels }

    /// Apply the account's copy. Additive on ids the device already knows
    /// (local `onHome` wins nothing — the remote row is the newer authority
    /// for its own fields), union on the rest, so favouriting on one box and
    /// pinning on another can't erase each other.
    /// Grace before a local row absent from the account snapshot is removed:
    /// long enough for this box's own just-added favourite to reach the
    /// account, short enough that a delete made elsewhere lands promptly.
    private static let deletionGrace: TimeInterval = 3 * 60

    func applyRemote(_ remote: [FavoriteChannel]) {
        // Tombstones expire on TIME only. Pruning them the moment the account
        // stopped listing the channel un-protected the removal one pull after
        // our own push — another device's next whole-blob push re-listed the
        // channel and it resurrected within two sync cycles.
        let cutoff = Date().addingTimeInterval(-Self.removalTombstoneLife)
        let survivors = removedAt.filter { $0.value >= cutoff }
        if survivors.count != removedAt.count { removedAt = survivors; persistRemoved() }
        let remoteIDs = Set(remote.map(\.id))
        var byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Deletion reconcile: the blob is a full snapshot, so a local row the
        // account no longer lists was unfavourited elsewhere — drop it, with
        // a grace window so a favourite added seconds ago (own push still in
        // flight) is never culled. Union-only apply meant a removal made on
        // another box NEVER reached this one.
        for (id, local) in byID where !remoteIDs.contains(id) {
            guard local.addedAt < Date().addingTimeInterval(-Self.deletionGrace) else { continue }
            byID.removeValue(forKey: id)
        }
        for entry in remote {
            // A channel this box unfavourited stays gone — the union would
            // otherwise resurrect it on every pull (and re-upload it on the
            // next push) for as long as any other device still lists it.
            if let tombstone = removedAt[entry.id], tombstone > entry.addedAt { continue }
            if let local = byID[entry.id], local.addedAt > entry.addedAt { continue }
            byID[entry.id] = entry
        }
        let merged = byID.values.sorted { $0.addedAt > $1.addedAt }
        guard merged != channels else { return }
        channels = merged
        // Persist WITHOUT `onLocalChange` — this came from the account, and
        // echoing it back would arm a push of what we just received.
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: scopedKey)
        }
    }

    // MARK: - Persistence

    private func load() {
        let rawRemoved = UserDefaults.standard.dictionary(forKey: scopedRemovedKey) as? [String: Double] ?? [:]
        removedAt = rawRemoved.mapValues { Date(timeIntervalSince1970: $0) }
        guard let data = UserDefaults.standard.data(forKey: scopedKey),
              let decoded = try? JSONDecoder().decode([FavoriteChannel].self, from: data) else {
            channels = []
            return
        }
        channels = decoded.sorted { $0.addedAt > $1.addedAt }
    }

    private func persistRemoved() {
        UserDefaults.standard.set(removedAt.mapValues { $0.timeIntervalSince1970 },
                                  forKey: scopedRemovedKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: scopedKey)
        }
        onLocalChange?()
    }
}
