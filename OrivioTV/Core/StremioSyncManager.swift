import Combine
import Foundation

@MainActor
final class StremioSyncManager: ObservableObject {
    static weak var shared: StremioSyncManager?

    var onMergedFromStremio: (() async -> Void)?

    private static let autoSyncInterval: TimeInterval = 30

    private let stremio: StremioAccountStore
    private let addonManager: AddonManager
    private let library: LibraryStore
    private let progress: ProgressStore
    private let watched: WatchedStore
    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?

    init(
        stremio: StremioAccountStore,
        addonManager: AddonManager,
        library: LibraryStore,
        progress: ProgressStore,
        watched: WatchedStore
    ) {
        self.stremio = stremio
        self.addonManager = addonManager
        self.library = library
        self.progress = progress
        self.watched = watched
        Self.shared = self

        stremio.$authKey
            .removeDuplicates()
            .sink { [weak self] key in
                self?.handleAuthKey(key)
            }
            .store(in: &cancellables)

        // Removals here must reach Stremio too — the hub fans OUT, not just in.
        progress.onStremioClearProgress = { [weak self] metaID in
            self?.queueProgressClear(metaID)
        }
        // Library removals as well: `datastorePut` cannot express absence, so
        // a title removed from the library here stayed in the Stremio library
        // forever (and came back on the next pull). `onTrackerRemove` fires
        // only on a genuine local removal, never on a merge or a clear.
        library.onTrackerRemove.append { [weak self] item in
            self?.queueLibraryRemoval(item)
        }

        handleAuthKey(stremio.authKey)
    }

    /// A library removal Stremio has not been told about yet.
    struct PendingLibraryRemoval: Codable, Hashable {
        let id: String
        let type: String
        let name: String
    }

    private static let pendingLibraryRemovalKey = "orivio.stremio.pendingLibraryRemovals.v1"

    private var pendingLibraryRemovals: [PendingLibraryRemoval] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.pendingLibraryRemovalKey),
                  let decoded = try? JSONDecoder().decode([PendingLibraryRemoval].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.pendingLibraryRemovalKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.pendingLibraryRemovalKey)
            }
        }
    }

    private func queueLibraryRemoval(_ item: SavedLibraryItem) {
        var queue = pendingLibraryRemovals.filter { $0.id != item.id }
        queue.append(PendingLibraryRemoval(id: item.id, type: item.type, name: item.name))
        pendingLibraryRemovals = queue
    }

    /// Identity of the Stremio account the local stores were last synced
    /// with (the email, or a hash of the auth key when no email is known).
    /// Persisted so a DIFFERENT account signing in is recognised across
    /// launches — its first sync must not upload the previous account's
    /// Continue Watching into the new one.
    private static let lastSyncedUserKey = "orivio.stremio.lastSyncedUser.v1"

    private func currentUserIdentity(key: String) -> String {
        if let email = stremio.email?.lowercased(), !email.isEmpty { return "email:" + email }
        return "key:" + StremioSync.fnv64(key)
    }

    deinit {
        syncTask?.cancel()
        autoSyncTask?.cancel()
    }

    /// Titles removed from Continue Watching that Stremio hasn't been told
    /// about yet. Persisted, so a removal survives a failed push or a relaunch
    /// instead of silently coming back on the next pull.
    private static let pendingClearKey = "orivio.stremio.pendingProgressClears.v1"

    private var pendingProgressClears: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.pendingClearKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.pendingClearKey) }
    }

    private func queueProgressClear(_ metaID: String) {
        guard !metaID.isEmpty else { return }
        pendingProgressClears.insert(metaID)
    }

    func syncNow(reason: String = "Manual Stremio sync") {
        runSync(reason: reason, logSkippedBusy: true)
    }

    /// False until the auth-key publisher has delivered its first value, which
    /// at launch is whatever was restored from disk.
    private var sawInitialAuthKey = false

    /// Signature of the Stremio datastore at the last successful pull. A tick
    /// whose signature matches skips the full library fetch entirely.
    private var lastPulledSignature: String?

    private func handleAuthKey(_ key: String?) {
        // A new key means a new account (or a re-link): forget what the
        // previous one was last seen holding and what this device sent it.
        lastPulledSignature = nil
        StremioSync.resetPushCache()
        guard let key, !key.isEmpty else {
            stopAutoSync()
            stremio.setSyncing(false)
            return
        }
        startAutoSync()
        // A key that ARRIVES while the app is running is someone signing in —
        // the publisher's initial value at launch is the restored one, and that
        // stays deferred so a heavyweight sync does not land in app
        // construction. Signing in should show the account's library at once,
        // not up to thirty seconds later.
        if sawInitialAuthKey {
            // Hand the key STRAIGHT to the sync: `@Published` notifies from
            // `willSet`, so `stremio.authKey` still reads nil here on a fresh
            // sign-in and runSync's own guard bounced it with "Connect Stremio
            // first" — the sign-in appeared to sync nothing until the 30s tick.
            runSync(reason: "Stremio sign-in", logSkippedBusy: false, key: key)
        } else {
            sawInitialAuthKey = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.runSync(reason: "Stremio launch", logSkippedBusy: false)
            }
        }
    }

    private func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoSyncInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard stremio.isSignedIn else { continue }
                guard syncTask == nil else { continue }
                // Runs during playback too: the pull is skipped unless
                // Stremio's datastore signature changed, and the push sends
                // only changed rows — mid-film that is one signature request
                // and a one-row put every thirty seconds.
                runSync(reason: "Auto Stremio sync", logSkippedBusy: false)
            }
        }
    }

    private func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        syncTask?.cancel()
        syncTask = nil
    }

    /// - Parameter key: the auth key to sync with, for callers that hold one
    ///   the account has not finished publishing yet (see `handleAuthKey`).
    private func runSync(reason: String, logSkippedBusy: Bool, key: String? = nil) {
        guard let key = key ?? stremio.authKey, !key.isEmpty else {
            stremio.setStatus("Connect Stremio first")
            OrivioSyncDiagnostics.record(.warning, area: "Stremio", "Sync skipped because Stremio is not connected.")
            return
        }
        guard syncTask == nil else {
            if logSkippedBusy {
                OrivioSyncDiagnostics.record(.warning, area: "Stremio", "Sync skipped because another Stremio sync is already running.")
            }
            return
        }

        stremio.setSyncing(true)
        stremio.setStatus("Syncing...")
        let automatic = reason.hasPrefix("Auto")
        if !automatic { OrivioSyncDiagnostics.record(.info, area: "Stremio", "\(reason) started.") }

        syncTask = Task { [weak self] in
            guard let self else { return }
            // A DIFFERENT Stremio account than the one these stores were last
            // synced with. The pull below is additive, so the previous
            // account's rows would survive it and the push at the end would
            // upload them into the new account. Retire what the previous
            // account contributed (its Continue Watching rows carry the
            // "stremio" source) and hold the push back until this run's pull
            // has landed. Library rows have no source tag, so they stay —
            // a saved title is device-wide by design here.
            let identity = self.currentUserIdentity(key: key)
            let lastIdentity = UserDefaults.standard.string(forKey: Self.lastSyncedUserKey)
            // Only a change of the SAME kind of identity is an account change:
            // the key-hash form is a fallback for when the email was unknown,
            // and it becoming known later is the same account.
            let accountChanged = lastIdentity != nil && lastIdentity != identity
                && (lastIdentity?.hasPrefix("key:") == identity.hasPrefix("key:"))
            if accountChanged {
                self.progress.removeRows(syncSource: "stremio")
                self.pendingProgressClears = []
                self.pendingLibraryRemovals = []
                self.lastPulledSignature = nil
                StremioSync.resetPushCache()
                OrivioSyncDiagnostics.record(
                    .warning, area: "Stremio",
                    "A different Stremio account signed in; the previous account's Continue Watching was retired and this run pulls before it pushes."
                )
            }
            // Change detection first. Unchanged since the last pull means the
            // whole-library fetch, the merge and the Orivio nudge that follows
            // it are all skipped; the signature call itself is tiny.
            var signature: String?
            do {
                signature = try await StremioAccountService.fetchLibrarySignature(authKey: key)
            } catch {
                // No signature means no change detection this tick: fall back
                // to the full pull rather than guess.
                NSLog("[OrivioStremio] datastoreMeta unavailable (%@) — full pull", String(describing: error))
            }
            let remoteChanged = signature == nil || signature != lastPulledSignature
            var pullResult = "Stremio unchanged"
            var succeeded = true
            if remoteChanged {
                pullResult = await StremioSync.pull(
                    authKey: key,
                    addonManager: addonManager,
                    library: library,
                    progress: progress,
                    watched: watched
                )
                succeeded = !pullResult.hasPrefix("Couldn't")
                if succeeded { lastPulledSignature = signature }
            } else {
                // The signature covers the `libraryItem` collection only, and
                // the add-on collection lives elsewhere — an add-on installed
                // on stremio.com never changes it. Fetch that (one small
                // request) even on an "unchanged" tick, or add-ons added on
                // another device never arrive here.
                if let descriptors = try? await StremioAccountService.fetchAddonCollection(authKey: key),
                   !descriptors.isEmpty {
                    let states = descriptors
                        .filter { !$0.transportUrl.isEmpty }
                        .map { AddonManager.RemoteAddonState(manifestURL: $0.transportUrl, enabled: true) }
                    _ = await addonManager.applyRemote(addons: states, reconcile: false)
                }
            }
            var finalResult = pullResult
            if succeeded, accountChanged {
                // The pull landed: the stores now hold this account's data.
                // Its first push runs on the next tick.
                UserDefaults.standard.set(identity, forKey: Self.lastSyncedUserKey)
                progress.removeLocalOnlyProgress()
                await onMergedFromStremio?()
                progress.removeLocalOnlyProgress()
                OrivioSyncDiagnostics.record(.info, area: "Stremio", "\(reason): \(pullResult) (first pull for this account; push deferred to the next tick).")
                stremio.setStatus(pullResult)
                stremio.setSyncing(false)
                syncTask = nil
                return
            } else if accountChanged {
                OrivioSyncDiagnostics.record(.failure, area: "Stremio", "\(reason): \(pullResult) — the new account's first pull failed; it retries next tick.")
            }
            if succeeded {
                if lastIdentity == nil || lastIdentity != identity {
                    UserDefaults.standard.set(identity, forKey: Self.lastSyncedUserKey)
                }
                if remoteChanged {
                    progress.removeLocalOnlyProgress()
                    await onMergedFromStremio?()
                    progress.removeLocalOnlyProgress()
                }
                let clears = pendingProgressClears
                let removals = pendingLibraryRemovals
                // Signature just before the push: if a remote change lands
                // between this and the post-push refetch, it must NOT be
                // folded into "what we last pulled" or it would never be
                // pulled (see below).
                let beforePush = try? await StremioAccountService.fetchLibrarySignature(authKey: key)
                let push = await StremioSync.pushCombined(
                    authKey: key,
                    addonManager: addonManager,
                    library: library,
                    progress: progress,
                    watched: watched,
                    clearedProgressIDs: clears,
                    removedLibraryItems: removals
                )
                // Only drop the queue once the LIBRARY push actually landed —
                // the cleared ids ride in that payload. This used to test the
                // summary string for a "Couldn't" prefix that `pushCombined`
                // never produces, so a failed push still emptied the queue and
                // the title the user removed came back on the next pull.
                if !clears.isEmpty, push.libraryPushed {
                    pendingProgressClears.subtract(clears)
                }
                if !removals.isEmpty, push.libraryPushed {
                    let sent = Set(removals)
                    pendingLibraryRemovals = pendingLibraryRemovals.filter { !sent.contains($0) }
                }
                finalResult = "\(pullResult) · \(push.summary)"
                // Our own push changed the datastore: refresh the signature so
                // the next tick does not mistake our write for a remote change
                // and re-pull the whole library — but ONLY when nothing else
                // changed the datastore during this run. Adopting the post-push
                // signature unconditionally absorbed any change another client
                // made between the pull and here, and that change was never
                // pulled until something else moved.
                if push.changedRows > 0,
                   let beforePush, beforePush == lastPulledSignature,
                   let after = try? await StremioAccountService.fetchLibrarySignature(authKey: key) {
                    lastPulledSignature = after
                }
                // A quiet automatic tick stays out of the diagnostics log —
                // one "unchanged" line every thirty seconds is noise.
                if automatic, !remoteChanged, push.changedRows == 0 {
                    stremio.setStatus("Up to date")
                    stremio.setSyncing(false)
                    syncTask = nil
                    return
                }
            }
            stremio.setStatus(finalResult)
            stremio.setSyncing(false)
            OrivioSyncDiagnostics.record(
                succeeded ? .success : .failure,
                area: "Stremio",
                finalResult
            )
            syncTask = nil
        }
    }
}
