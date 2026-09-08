import Foundation

/// Resolves a collection folder's TMDB / Trakt sources into `MetaItem`s. Shared
/// by the collection BROWSE page (full depth) and HOME rows (first TMDB page
/// only, via `maxTmdbPages`, so rendering a Rows/Combined collection doesn't
/// fire hundreds of TMDB requests per folder on every load).
///
/// Categories are a TMDB/Trakt feature. Add-on catalog sources are NOT resolved
/// here: a folder pointing at an installed add-on's catalog used to fill itself
/// with no TMDB key at all, which made "categories" look like they worked while
/// every TMDB-backed folder sat empty. Existing addon rows are left in storage
/// untouched (so a folder authored on the phone round-trips unchanged) — they
/// simply resolve to nothing, and `blocker(for:providers:)` says so.
/// The services a collection can draw on right now.
///
/// Collections are built entirely out of TMDB and Trakt sources, so with
/// neither connected there is nothing for one to resolve — every folder would
/// open empty. `any` is the switch the whole feature hangs off.
struct CollectionProviders: Equatable {
    /// TMDB has the viewer's API key and is switched on.
    let tmdb: Bool
    /// The viewer is signed in to Trakt.
    let trakt: Bool

    var any: Bool { tmdb || trakt }

    /// TMDB is the one to recommend and the one to prefer when both are live:
    /// it resolves every source type collections can hold (lists, collections,
    /// companies, networks, people, discover queries), and it returns artwork,
    /// descriptions and ids directly. A Trakt list carries titles and ids only
    /// — its posters have to be borrowed from a meta add-on, one lookup per
    /// title, for the first thirty entries and no further.
    var preferredName: String? { tmdb ? "TMDB" : (trakt ? "Trakt" : nil) }

    static let none = CollectionProviders(tmdb: false, trakt: false)
}

enum CollectionResolver {

    /// Why a folder can't fill itself, if it can't.
    ///
    /// This is asked per FOLDER and only when the folder has nothing that can
    /// resolve. A folder holding both a TMDB source and a Trakt list is NOT
    /// blocked when only TMDB is connected — it just quietly uses TMDB, which
    /// is the whole point of favouring TMDB. Reporting "sign in to Trakt"
    /// there (or worse, across the whole collection because one folder
    /// somewhere had a Trakt list) was noise about a source the folder didn't
    /// need.
    enum FolderBlocker: Equatable {
        /// Something in this folder can resolve.
        case none
        case needsTMDB
        case needsTrakt
        /// Has both kinds, and neither service is connected.
        case needsEither
        /// Add-on catalogs only — collections are TMDB/Trakt now.
        case unsupportedSources
        /// The folder has no sources at all.
        case empty
    }

    static func blocker(for folder: OrivioCollectionFolder,
                        providers: CollectionProviders) -> FolderBlocker {
        let sources = folder.effectiveSources
        guard !sources.isEmpty else { return .empty }
        let tmdb = sources.contains(where: \.isTMDBSource)
        let trakt = sources.contains(where: \.isTraktSource)
        // Anything at all that can run right now means the folder is fine.
        if (tmdb && providers.tmdb) || (trakt && providers.trakt) { return .none }
        if tmdb && trakt { return .needsEither }
        if tmdb { return .needsTMDB }
        if trakt { return .needsTrakt }
        return .unsupportedSources
    }

    /// Resolve ONE folder's items, de-duplicated by id (addon order, then TMDB,
    /// then Trakt). Returns empty when the folder has nothing resolvable.
    static func resolveFolder(
        _ folder: OrivioCollectionFolder,
        addonManager: AddonManager,
        providers: CollectionProviders,
        tmdbLanguage: String,
        maxTmdbPages: Int = Int.max,
        /// First TMDB page of this window (see TMDBService.resolve). >1 means
        /// "continue a streaming load", so addon/Trakt sources — which aren't
        /// paged — are skipped to avoid re-returning what earlier windows
        /// already delivered.
        tmdbStartPage: Int = 1,
        hideUnreleased: Bool = false
    ) async -> [MetaItem] {
        // Only a CONNECTED service resolves, and TMDB wins OUTRIGHT: when TMDB
        // can serve this folder, its Trakt sources aren't consulted at all —
        // TMDB returns artwork, descriptions and resolved ids directly, while
        // a Trakt list needs a per-title meta lookup just to get posters.
        // Trakt resolves only when it is the folder's sole workable service
        // (TMDB disconnected, or a Trakt-only folder).
        let resolvableTmdb = providers.tmdb ? folder.effectiveSources.filter(\.isTMDBSource) : []
        let traktSources = (providers.trakt && resolvableTmdb.isEmpty)
            ? folder.effectiveSources.filter(\.isTraktSource) : []
        guard !resolvableTmdb.isEmpty || !traktSources.isEmpty else { return [] }

        let isContinuation = tmdbStartPage > 1

        // Every source in the folder is fetched CONCURRENTLY. They used to run
        // one after another — each TMDB source, then each Trakt list, every one
        // a full network round-trip — so a folder built from four sources took
        // four round-trips end to end even though none of them depends on the
        // others. Folders were already parallel; the wait was inside each one.
        //
        // Order is preserved by INDEX, not by arrival: the merge below still
        // goes TMDB → Trakt, in each group's own source order, so the
        // de-duplication keeps giving the same winner it always did (first
        // source to claim an id owns it). Concurrency changes when things
        // arrive, never what the folder resolves to.
        func gather(_ count: Int,
                    _ body: @escaping @Sendable (Int) async -> [MetaItem]) async -> [[MetaItem]] {
            guard count > 0 else { return [] }
            var out = [[MetaItem]](repeating: [], count: count)
            await withTaskGroup(of: (Int, [MetaItem]).self) { group in
                for i in 0..<count { group.addTask { (i, await body(i)) } }
                for await (i, items) in group { out[i] = items }
            }
            return out
        }

        async let tmdbResults: [[MetaItem]] = gather(resolvableTmdb.count) { i in
            await TMDBService.resolve(source: resolvableTmdb[i], language: tmdbLanguage,
                                      maxPages: maxTmdbPages, startPage: tmdbStartPage)
        }
        async let traktResults: [[MetaItem]] = isContinuation ? [] : gather(traktSources.count) { i in
            await resolveTrakt(source: traktSources[i], addonManager: addonManager)
        }

        var items: [MetaItem] = []
        var seen = Set<String>()
        for batch in await tmdbResults + traktResults {
            for item in batch where seen.insert(item.id).inserted { items.append(item) }
        }
        return hideUnreleased ? items.filter { !$0.isUnreleased } : items
    }

    /// Trakt list items arrive with no artwork — enrich the first N via the
    /// installed meta add-on (Cinemeta) so the grid still has posters; the rest
    /// still display (title only) rather than being dropped.
    static func resolveTrakt(source: CollectionSourceDTO, addonManager: AddonManager) async -> [MetaItem] {
        guard let traktListId = source.traktListId else { return [] }
        let type = (source.mediaType ?? "movie").lowercased() == "tv" ? "show" : "movie"
        let sortBy = source.sortBy ?? "rank"
        let sortHow = source.sortHow ?? "asc"
        let raw = await TraktService.publicListItems(
            traktListId: traktListId, type: type, sortBy: sortBy, sortHow: sortHow
        )
        // Flatten first: every entry gets its placeholder, and the first 30 get
        // upgraded in place if their meta lookup lands.
        struct Entry { let id: String; let type: String; let placeholder: MetaItem }
        let entries: [Entry] = raw.compactMap { item in
            let metaType = item.isMovie ? "movie" : "series"
            guard let id = item.imdb ?? item.tmdb.map({ "tmdb:\($0)" }) else { return nil }
            return Entry(id: id, type: metaType, placeholder: MetaItem(
                id: id, type: metaType, name: item.title,
                releaseInfo: item.year.map(String.init)
            ))
        }
        guard !entries.isEmpty else { return [] }

        // Resolve the meta add-on ONCE per type rather than per item. It is a
        // main-actor lookup, so doing it inside the loop cost thirty hops onto
        // the main thread — while the main thread is drawing the grid.
        var addonByType: [String: InstalledAddon] = [:]
        for type in Set(entries.prefix(30).map(\.type)) {
            if let first = entries.first(where: { $0.type == type }),
               let addon = await addonManager.metaAddon(for: type, id: first.id) {
                addonByType[type] = addon
            }
        }

        // The enrichment is what made a Trakt list slow: thirty meta fetches,
        // strictly one after another, before a single poster appeared. They are
        // independent lookups — run them together, bounded so a list doesn't
        // open thirty sockets at once.
        let enrichCount = min(entries.count, 30)
        var upgraded = [MetaItem?](repeating: nil, count: enrichCount)
        await withTaskGroup(of: (Int, MetaItem?).self) { group in
            let window = min(8, enrichCount)
            var next = 0
            func start() {
                guard next < enrichCount else { return }
                let i = next
                next += 1
                let entry = entries[i]
                let addon = addonByType[entry.type]
                group.addTask {
                    guard let addon else { return (i, nil) }
                    return (i, try? await StremioAPI.meta(addon: addon, type: entry.type, id: entry.id))
                }
            }
            for _ in 0..<window { start() }
            for await (i, meta) in group {
                start()
                upgraded[i] = meta
            }
        }

        return entries.enumerated().map { index, entry in
            (index < enrichCount ? upgraded[index] : nil) ?? entry.placeholder
        }
    }
}
