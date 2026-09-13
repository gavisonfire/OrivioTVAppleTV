import SwiftUI

/// A channel in the Live TV grid. Either a direct M3U stream (plays straight
/// away) or an add-on catalog entry (resolved through the source picker).
struct LiveChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: String?
    let group: String
    /// Direct stream URL (from the embedded M3U). nil → resolve via `meta`.
    let directURL: String?
    let meta: MetaItem?
    /// Headers / manifest type / DRM the playlist declared for this channel.
    /// Carried all the way to the player — a CDN that checks `User-Agent` or
    /// `Referer` returns 403 without them and the channel looks dead.
    var options: LiveStreamOptions = LiveStreamOptions()

    /// The storable form, for the favourites list.
    var favorite: FavoriteChannel {
        FavoriteChannel(id: id, name: name, logo: logo, group: group,
                        directURL: directURL, metaID: meta?.id, metaType: meta?.type,
                        options: options)
    }

    /// Rebuild a playable channel from a stored favourite. An add-on channel
    /// keeps only enough of its `MetaItem` to be handed back to the source
    /// picker, which re-fetches the real meta anyway.
    init(_ favorite: FavoriteChannel) {
        id = favorite.id
        name = favorite.name
        logo = favorite.logo
        group = favorite.group
        directURL = favorite.directURL
        options = favorite.options ?? LiveStreamOptions()
        if let metaID = favorite.metaID {
            meta = MetaItem(id: metaID, type: favorite.metaType ?? "tv",
                            name: favorite.name, poster: favorite.logo)
        } else {
            meta = nil
        }
    }

    init(id: String, name: String, logo: String?, group: String,
         directURL: String?, meta: MetaItem?,
         options: LiveStreamOptions = LiveStreamOptions()) {
        self.id = id
        self.name = name
        self.logo = logo
        self.group = group
        self.directURL = directURL
        self.meta = meta
        self.options = options
    }
}

/// Live TV / IPTV tab. Merges two sources: `tv`-type catalogs from installed
/// add-ons AND an embedded iptv-org playlist, so there are channels out of the
/// box. Direct (M3U) channels play immediately; add-on channels go through the
/// normal source picker.
@MainActor
final class LiveTVViewModel: ObservableObject {
    struct Section: Identifiable {
        let id: String
        let title: String
        let channels: [LiveChannel]
    }

    @Published var sections: [Section] = []
    @Published var isLoading = false
    @Published var loadingIPTV = false
    private var loaded = false

    func loadIfNeeded(addonManager: AddonManager) async {
        guard !loaded else { return }
        loaded = true
        await load(addonManager: addonManager)
        // A load cancelled by `onDisappear` (tapping a channel mid-load) must
        // not latch: it dropped the IPTV list for the rest of the visit.
        // Neither may a load that came back with NOTHING — a network blip at
        // tab-open latched an empty screen for the whole session, with no
        // retry control anywhere. Empty-and-latched means the next visit
        // simply tries again; a genuinely empty setup re-fetches cheaply.
        if Task.isCancelled || sections.isEmpty { loaded = false }
    }

    /// Two settings changes in quick succession (country, then language)
    /// start two overlapping loads; without this the slower, OLDER one could
    /// publish last and the tab showed the playlist just moved away from.
    private var loadGeneration = 0

    func load(addonManager: AddonManager) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = sections.isEmpty

        // 1) Add-on tv catalogs (fast) — show these first.
        let addonSections = await addonSections(addonManager)
        guard generation == loadGeneration else { return }
        sections = addonSections
        if !addonSections.isEmpty { isLoading = false }

        // 2) The IPTV list — the viewer's own playlist when one is set in
        // Settings → Live TV (it replaces the built-in source entirely),
        // otherwise the language/country iptv-org playlist chosen there.
        loadingIPTV = true
        let settings = LiveTVSettingsStore.shared
        var m3u = await M3UService.channels(from: settings.primaryPlaylistURL)

        // Safety net: if a language is chosen but its iptv-org playlist came
        // back empty (unsupported/unavailable), pull the global list and keep
        // only channels whose country is one where that language is spoken, so
        // non-matching-language channels are still hidden. Never for a custom
        // playlist: falling back to the global list would resurrect the very
        // built-in source the custom URL is meant to replace.
        if !settings.usesCustomPlaylist && !settings.languageCode.isEmpty && m3u.isEmpty {
            let allowed = settings.countriesForLanguage(settings.languageCode)
            if !allowed.isEmpty {
                let global = await M3UService.channels(from: M3UService.iptvOrgURL)
                m3u = global.filter { ch in ch.country.map { allowed.contains($0) } ?? false }
            }
        }

        guard generation == loadGeneration else { return }
        sections = addonSections + m3uSections(m3u)
        loadingIPTV = false
        isLoading = false
    }

    private func addonSections(_ addonManager: AddonManager) async -> [Section] {
        var requests: [(addon: InstalledAddon, catalog: ManifestCatalog)] = []
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? [])
            where catalog.type == "tv" && !catalog.requiresExtra {
                requests.append((addon, catalog))
            }
        }
        guard !requests.isEmpty else { return [] }

        var built: [(Int, Section)] = []
        await withTaskGroup(of: (Int, Section?).self) { group in
            for (i, req) in requests.enumerated() {
                group.addTask {
                    let metas = (try? await StremioAPI.catalog(addon: req.addon, catalog: req.catalog)) ?? []
                    guard !metas.isEmpty else { return (i, nil) }
                    let title = req.catalog.name ?? req.catalog.id.capitalized
                    let channels = metas.map {
                        LiveChannel(id: $0.id, name: $0.name,
                                    logo: $0.logo ?? $0.poster ?? $0.background,
                                    group: title, directURL: nil, meta: $0)
                    }
                    return (i, Section(id: "addon|\(req.addon.id)|\(req.catalog.id)", title: title, channels: channels))
                }
            }
            for await (i, section) in group { if let section { built.append((i, section)) } }
        }
        return built.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func m3uSections(_ channels: [M3UChannel]) -> [Section] {
        guard !channels.isEmpty else { return [] }
        // Preserve first-seen group order.
        var order: [String] = []
        var byGroup: [String: [LiveChannel]] = [:]
        for c in channels {
            if byGroup[c.group] == nil { order.append(c.group) }
            byGroup[c.group, default: []].append(
                LiveChannel(id: c.id, name: c.name, logo: c.logo, group: c.group,
                            directURL: c.url, meta: nil, options: c.options)
            )
        }
        return order.map { g in Section(id: "iptv|\(g)", title: g, channels: byGroup[g] ?? []) }
    }
}

enum ChannelSort: String, CaseIterable, Identifiable {
    case defaultOrder = "Default"
    case nameAsc = "A → Z"
    case nameDesc = "Z → A"
    var id: String { rawValue }
}

struct LiveTVView: View {
    /// The grouped rows skipped the id dedupe the filtered grid does; addon
    /// `tv` catalogs are not `deduplicatedByID()` and a repeated id crashes
    /// the tvOS focus engine inside `ForEach`.
    static func uniqueByID<S: Sequence>(_ channels: S) -> [LiveChannel] where S.Element == LiveChannel {
        var seen = Set<String>()
        return channels.filter { seen.insert($0.id).inserted }
    }
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @ObservedObject private var liveSettings = LiveTVSettingsStore.shared
    @ObservedObject private var favorites = LiveChannelFavorites.shared
    @StateObject private var viewModel = LiveTVViewModel()

    /// Add-on channel → source picker.
    let onSelectChannel: (MetaItem) -> Void
    /// Direct (M3U) channel → play its URL immediately.
    let onPlayDirect: (LiveChannel) -> Void

    @State private var searchText = ""
    @State private var sortMode: ChannelSort = .defaultOrder
    /// The `Section.id` of a group opened via "Show All". "" = the grouped rows
    /// view. Keyed by id, not title: an add-on `tv` catalog and an M3U group
    /// routinely share a title ("News", "Sports", "Movies"), so matching on the
    /// title opened the wrong row's channels.
    @State private var selectedGroupID = ""

    private var settingsKey: String {
        "\(liveSettings.countryCode)|\(liveSettings.languageCode)|\(liveSettings.customPlaylistURL)"
    }

    var body: some View {
        ZStack {
            ATVBackground()
            content
        }
        .task { await viewModel.loadIfNeeded(addonManager: addonManager) }
        // Reload the IPTV list when the location/language changes in Settings.
        .onChange(of: settingsKey) { _, _ in
            selectedGroupID = ""
            Task { await viewModel.load(addonManager: addonManager) }
        }
    }

    private func play(_ channel: LiveChannel) {
        if channel.directURL != nil { onPlayDirect(channel) }
        else if let meta = channel.meta { onSelectChannel(meta) }
    }

    private var filtering: Bool {
        !searchText.isEmpty || sortMode != .defaultOrder || !selectedGroupID.isEmpty
    }

    private var selectedSection: LiveTVViewModel.Section? {
        viewModel.sections.first { $0.id == selectedGroupID }
    }

    private var displayChannels: [LiveChannel] {
        var pool = selectedGroupID.isEmpty
            ? viewModel.sections.flatMap(\.channels)
            : (selectedSection?.channels ?? [])
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0.id).inserted }
        if !searchText.isEmpty {
            pool = pool.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortMode {
        case .nameAsc:  pool.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: pool.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .defaultOrder: break
        }
        return pool
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.sections.isEmpty {
            OrivioLoadingView(label: "Loading channels…")
        } else if viewModel.sections.isEmpty {
            OrivioEmptyState(
                icon: "tv",
                title: "No channels",
                message: "Couldn't load channels. Check your connection, or install a Live TV / IPTV add-on from Add-ons → Discover."
            )
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                    header
                    controls
                    if filtering {
                        gridContext
                        filteredGrid
                    } else {
                        // Favourites first, above every other group — that is
                        // the whole point of favouriting a channel.
                        favoritesRow
                        ForEach(viewModel.sections) { section in
                            channelRow(section)
                        }
                    }
                }
                .padding(.top, OrivioSpacing.xl)
                .padding(.bottom, OrivioSpacing.huge)
            }
        }
    }

    /// Above the grid: when viewing a single group ("Show All"), a back button
    /// and the group name so you can return to the grouped rows.
    @ViewBuilder
    private var gridContext: some View {
        if !selectedGroupID.isEmpty {
            HStack(spacing: OrivioSpacing.md) {
                Button { selectedGroupID = "" } label: { SeeAllLabel(text: "‹ All Channels") }
                    .buttonStyle(PlainCardButtonStyle())
                Text(selectedSection?.title ?? "")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OrivioSpacing.huge)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live TV")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
            Text(viewModel.loadingIPTV
                 ? "Loading the IPTV channel list…"
                 : "Channels from your add-ons and the built-in IPTV list")
                .font(.system(size: 21))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(.leading, OrivioSpacing.huge)
    }

    private var controls: some View {
        HStack(spacing: OrivioSpacing.lg) {
            HStack(spacing: OrivioSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)
                TextField("Search channels", text: $searchText)
                    .font(.system(size: 23))
            }
            .padding(.horizontal, OrivioSpacing.lg)
            .padding(.vertical, OrivioSpacing.md)
            .background(theme.palette.field, in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
            .frame(maxWidth: 560)

            OrivioDropdown(
                title: "Sort",
                selection: sortMode.rawValue,
                options: ChannelSort.allCases.map { OrivioDropdownOption($0.rawValue) },
                triggerWidth: 240
            ) { sortMode = ChannelSort(rawValue: $0) ?? .defaultOrder }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OrivioSpacing.huge)
    }

    /// Most rows a filtered grid will hand SwiftUI. LazyVGrid materializes
    /// few cells, but `ForEach` still builds and diffs the full identifier
    /// collection every keystroke — five figures of ids per key press on the
    /// iptv-org list was real per-keystroke cost on the A8/A10X, for rows
    /// nobody scrolls 400 cards deep to find. Narrowing the search shows the
    /// rest.
    private static let gridDisplayCap = 400

    private var filteredGrid: some View {
        // Evaluated ONCE per render: the computed property flat-maps, dedupes
        // and (searching) filters the whole merged pool — five figures of
        // channels on the iptv-org list — and it was being run twice per body
        // pass, which read as per-keystroke jank on the A10X.
        let shown = displayChannels
        let capped = shown.count > Self.gridDisplayCap ? Array(shown.prefix(Self.gridDisplayCap)) : shown
        return Group {
            if shown.isEmpty {
                Text(searchText.isEmpty ? "No channels in this group." : "No channels match “\(searchText)”.")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.top, OrivioSpacing.xl)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300, maximum: 300), spacing: OrivioSpacing.lg, alignment: .top)],
                    alignment: .leading,
                    spacing: OrivioSpacing.xl
                ) {
                    ForEach(capped) { channel in
                        Button { play(channel) } label: {
                            ChannelCard(channel: channel,
                                        isFavorite: favorites.isFavorite(channel.id))
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .onPlayPauseCommand { play(channel) }
                        .channelHoldMenu(channel.favorite)
                    }
                }
                .padding(.horizontal, OrivioSpacing.huge)
                if shown.count > capped.count {
                    Text("Showing the first \(capped.count) of \(shown.count) channels — keep typing to narrow the search.")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.palette.textSecondary)
                        .padding(.horizontal, OrivioSpacing.huge)
                }
            }
        }
    }

    /// The pinned Favourites row. Built from the STORED snapshots, not from
    /// `viewModel.sections`, so it is on screen immediately — before the
    /// several-megabyte IPTV playlist has finished loading, and even if the
    /// channel's own group has since disappeared from the playlist.
    @ViewBuilder
    private var favoritesRow: some View {
        if !favorites.channels.isEmpty {
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    RowHeader(title: "Favorites")
                    Spacer()
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
                        ForEach(favorites.channels) { favorite in
                            let channel = LiveChannel(favorite)
                            Button { play(channel) } label: {
                                ChannelCard(channel: channel, isFavorite: true)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .onPlayPauseCommand { play(channel) }
                            .channelHoldMenu(favorite)
                        }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.lg)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func channelRow(_ section: LiveTVViewModel.Section) -> some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                RowHeader(title: section.title)
                Spacer()
                // Every row can open its full channel list.
                Button { selectedGroupID = section.id } label: {
                    SeeAllLabel(text: "Show All")
                }
                .buttonStyle(PlainCardButtonStyle())
                .padding(.trailing, OrivioSpacing.huge)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
                    ForEach(Self.uniqueByID(section.channels.prefix(40))) { channel in
                        Button { play(channel) } label: {
                            ChannelCard(channel: channel,
                                        isFavorite: favorites.isFavorite(channel.id))
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .onPlayPauseCommand { play(channel) }
                        .channelHoldMenu(channel.favorite)
                    }
                }
                .padding(.horizontal, OrivioSpacing.huge)
                .padding(.vertical, OrivioSpacing.lg)
            }
            .scrollClipDisabled()
        }
    }
}

/// A landscape channel tile — logo on a dark plate with the name underneath.
/// Equatable so a focus step — which writes the row's @FocusState and re-runs
/// the row body — skips the bodies of unchanged tiles instead of rebuilding
/// every one in the row. Focus visuals come through \.isFocused, which
/// bypasses the == gate.
private struct ChannelCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channel == rhs.channel && lhs.isFavorite == rhs.isFavorite
    }

    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    let channel: LiveChannel
    /// Passed IN rather than read from the store here: this view's `==` is
    /// what lets a focus step skip unchanged tiles, so anything that changes
    /// what it draws has to be part of the comparison.
    var isFavorite: Bool = false

    private let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            ZStack {
                theme.palette.backgroundCard
                if let logo = channel.logo {
                    RemoteImage(url: logo, contentMode: .fit, maxDimension: width)
                        .padding(OrivioSpacing.md)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 46))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            // A favourited channel is marked wherever it appears, so the hold
            // menu's state is legible without opening it.
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .padding(8)
                }
            }
            .shadow(color: .black.opacity(perf.settings.cardShadows && isFocused ? 0.65 : 0),
                    radius: perf.settings.cardShadows && isFocused ? 22 : 0, y: 10)

            MarqueeText(
                text: channel.name,
                font: .system(size: 22, weight: .medium),
                color: isFocused ? theme.palette.textPrimary : theme.palette.textSecondary,
                active: isFocused
            )
            .frame(width: width, alignment: .leading)
        }
        .focusLift(OrivioFocus.card, isFocused)
    }
}
