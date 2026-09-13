import Foundation
import Network

/// Reclaims the player's scratch space in `tmp/` at launch.
///
/// The DV remuxer writes its fMP4 segments to `tmp/dv-remux-<uuid>/` and
/// deletes the directory when the session ends. That deletion is best-effort
/// by construction — it runs as the player is being dismissed, and a remux
/// session is exactly the workload most likely to get the app jetsammed on a
/// 3 GB box, so the process is often gone before the delete completes. Every
/// time that happens the directory is orphaned with no owner left to remove
/// it: found on a real Apple TV 4K (1st gen) as **3.2 GB across 15 leaked
/// directories**, three of them ~1 GB each.
///
/// Nothing else ever cleaned them up. tvOS does purge `tmp/` under storage
/// pressure, but only once the box is nearly full — long after the app has
/// been swapping, stuttering and getting killed. So the sweep has to be ours,
/// and it has to run at LAUNCH: that is the one moment we know for certain
/// that no remuxer owns any of these directories.
///
/// CFNetwork's response spool files (`tmp/CFNetworkDownload_*.tmp`) leak the
/// same way and for the same reason — the app dies with requests in flight —
/// so they are swept on the same pass (179 MB / 12,231 files on that device).
///
/// The hybrid disk cache's file (`Caches/hybrid-cache/current.bin`) is the
/// third case, and the largest of them: `MediaCacheServer.endSession()` deletes
/// it on player teardown, but teardown only runs on a normal exit. A crash, a
/// jetsam kill, or the user force-quitting mid-film leaves TENS OF GIGABYTES
/// stranded, and nothing would ever remove it — the next `beginSession` only
/// clears the file if a cache session actually starts, so turning the feature
/// off (or never playing a cacheable stream again) strands it permanently.
enum PlayerTempSweep {
    private static let remuxPrefix = "dv-remux-"
    private static let spoolPrefix = "CFNetworkDownload_"

    /// Delete every orphaned player scratch directory and network spool file.
    ///
    /// Call once, at launch, BEFORE any playback can start. Runs off the main
    /// thread: this is thousands of unlinks and real filesystem work, and it
    /// must never sit in front of the first frame of UI.
    static func sweepAtLaunch() {
        Task.detached(priority: .utility) { sweep() }
    }

    /// Delete a hybrid-cache file orphaned by a kill. Launch is the one moment
    /// no session can own it: `MediaCacheServer` creates its file inside
    /// `beginSession`, which cannot have run yet.
    private static func sweepHybridCache() {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("hybrid-cache", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ), !entries.isEmpty else { return }
        var reclaimed: Int64 = 0
        for entry in entries {
            reclaimed += Int64(
                (try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
            )
            try? fm.removeItem(at: entry)
        }
        if reclaimed > 0 {
            NSLog("[OrivioSweep] reclaimed %.2f GB of orphaned hybrid cache at launch",
                  Double(reclaimed) / 1e9)
        }
    }

    /// The sweep itself. Synchronous — call it directly only from a background
    /// context (or a test).
    static func sweep() {
        sweepHybridCache()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey]
        ) else { return }

        var reclaimed: Int64 = 0
        var directories = 0
        var spools = 0

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(remuxPrefix) {
                reclaimed += directorySize(of: entry, fm: fm)
                try? fm.removeItem(at: entry)
                directories += 1
            } else if name.hasPrefix(spoolPrefix) {
                reclaimed += Int64(
                    (try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                        .totalFileAllocatedSize ?? 0
                )
                try? fm.removeItem(at: entry)
                spools += 1
            }
        }

        guard directories > 0 || spools > 0 else { return }
        NSLog("[OrivioSweep] reclaimed %.1f MB — %d orphaned remux dirs, %d network spool files",
              Double(reclaimed) / (1024 * 1024), directories, spools)
    }

    private static func directorySize(of url: URL, fm: FileManager) -> Int64 {
        guard let walker = fm.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64(
                (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
            )
        }
        return total
    }
}

/// Dev-only live probe bus: timestamped EVENTS from anywhere, plus LEVELS
/// pulled on demand from whoever holds them.
///
/// The colour and DV trails are the wrong shape for watching an interaction.
/// They go through `UserDefaults` (a disk-backed write per line, capped at a
/// few dozen entries), which is fine for a handful of decisions per session and
/// useless for a scrub, where the interesting part is dozens of events a second
/// against levels that are moving the whole time.
///
/// So: an in-memory ring for events, a registry of sampler closures for levels,
/// and a monotonically increasing sequence number so a streaming reader can ask
/// for "everything since N" without re-reading what it already has.
///
/// DEBUG only, like the server that serves it. Every call site compiles away in
/// release — `event` in particular sits on the scrub path.
enum PlayerProbe {
    /// Ring capacity. Big enough to hold a whole scrub gesture at full rate —
    /// and, since the live tail only drains it twice a second, big enough that
    /// a burst (a source switch, a failover, a flood of engine states) can
    /// never push an event out before the reader has seen it.
    private static let capacity = 2000

    private static let lock = NSLock()
    private static var ring: [(seq: UInt64, at: Date, tag: String, line: String)] = []
    private static var nextSeq: UInt64 = 1
    static let startedAt = Date()

    /// Record one event. Safe from any thread or queue — the cache server
    /// calls it from its own serial queue, the player from the main actor.
    ///
    /// The message is an autoclosure so it is never even BUILT in release: the
    /// call sites sit on the scrub publish path and in every seek, and a
    /// `String(format:)` per call there is real work for a log nobody can read.
    nonisolated static func event(_ tag: String, _ line: @autoclosure () -> String) {
        #if DEBUG
        lock.lock()
        ring.append((nextSeq, Date(), tag, line()))
        nextSeq &+= 1
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        lock.unlock()
        #endif
    }

    /// Events newer than `seq`, formatted, with the sequence to ask from next.
    static func events(since seq: UInt64, limit: Int = capacity) -> (lines: [String], next: UInt64) {
        #if DEBUG
        lock.lock()
        let fresh = ring.filter { $0.seq > seq }.suffix(limit)
        let next = ring.last?.seq ?? seq
        lock.unlock()
        return (fresh.map { entry in
            String(format: "%8.3f  %-9@ %@",
                   entry.at.timeIntervalSince(startedAt), entry.tag, entry.line)
        }, next)
        #else
        return ([], seq)
        #endif
    }

    // MARK: Counters and sticky notes

    /// Monotonic counters and last-value notes, surfaced as a `[health]` block.
    ///
    /// Events answer "what just happened"; these answer "what has been
    /// happening" — the questions a live session actually turns on. A stall
    /// that fires once is a blip, the same stall forty times in an hour is the
    /// bug, and there is no way to tell those apart by watching a tail scroll
    /// past. Every number here is something that should be ZERO (or one) in a
    /// healthy session, so the block reads as a defect list rather than stats.
    private static var counters: [String: Int] = [:]
    private static var notes: [(key: String, value: String, at: Date)] = []
    /// Insertion order, so the block doesn't reshuffle between reads.
    private static var counterOrder: [String] = []

    /// Bump a counter. Same threading contract as `event`.
    nonisolated static func count(_ name: String, by amount: Int = 1) {
        #if DEBUG
        lock.lock()
        if counters[name] == nil { counterOrder.append(name) }
        counters[name, default: 0] += amount
        lock.unlock()
        #endif
    }

    /// Record a last-known value (with the time it was set). Use for the one
    /// fact whose LATEST value matters — the last error, the URL in play, how
    /// long the open took.
    nonisolated static func note(_ key: String, _ value: @autoclosure () -> String) {
        #if DEBUG
        let v = value()
        lock.lock()
        notes.removeAll { $0.key == key }
        notes.append((key, v, Date()))
        lock.unlock()
        #endif
    }

    /// Drop every counter and note. Called when a new playback session starts
    /// so the numbers describe THIS title, not the afternoon.
    nonisolated static func resetHealth(keeping prefix: String? = nil) {
        #if DEBUG
        lock.lock()
        if let prefix {
            counters = counters.filter { $0.key.hasPrefix(prefix) }
            counterOrder = counterOrder.filter { $0.hasPrefix(prefix) }
            notes = notes.filter { $0.key.hasPrefix(prefix) }
        } else {
            counters = [:]; counterOrder = []; notes = []
        }
        lock.unlock()
        #endif
    }

    nonisolated static func healthLines() -> [String] {
        #if DEBUG
        lock.lock()
        let c = counterOrder.compactMap { name -> String? in
            guard let value = counters[name] else { return nil }
            return "\(name)=\(value)"
        }
        let n = notes.map { note -> String in
            String(format: "%@ = %@  (%.1fs ago)", note.key, note.value,
                   Date().timeIntervalSince(note.at))
        }
        lock.unlock()
        var out: [String] = []
        // Counters wrap at ~100 columns: a terminal is the client.
        var row = ""
        for item in c {
            if row.count + item.count + 2 > 96 { out.append(row); row = "" }
            row += (row.isEmpty ? "" : "  ") + item
        }
        if !row.isEmpty { out.append(row) }
        out.append(contentsOf: n)
        return out
        #else
        return []
        #endif
    }

    // MARK: Levels

    /// Named sampler closures, called on the main actor when a reader asks.
    /// The player registers itself on `init` and clears on `deinit`, so a
    /// finished session's model is never held alive by this.
    @MainActor private static var samplers: [(name: String, sample: () -> [String])] = []

    @MainActor static func register(_ name: String, _ sample: @escaping () -> [String]) {
        samplers.removeAll { $0.name == name }
        samplers.append((name, sample))
    }

    @MainActor static func unregister(_ name: String) {
        samplers.removeAll { $0.name == name }
    }

    /// One block of every registered level, newest state at the moment of the
    /// call. The cache is always included — it outlives any one player.
    /// When the running executable was built.
    ///
    /// Earned its place: four hours of device observation were spent verifying a
    /// fix against a binary that turned out to predate it, because nothing in the
    /// probe said which build was answering. `strings` on the app cannot settle
    /// it (Swift literals do not surface), and "the install said Launched" is not
    /// evidence the install replaced anything.
    static let buildStamp: String = {
        guard let exe = Bundle.main.executableURL,
              let date = try? exe.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }()

    /// Resident footprint in MB, or 0 if the kernel won't say. A 3 GB Apple TV
    /// jetsams the app somewhere north of ~650 MB, and "it just closed" is one
    /// of the most common player complaints — a number climbing across a
    /// session is the difference between guessing and knowing.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    @MainActor static func levels() -> [String] {
        var out: [String] = [
            String(format: "[build] %@   up=%.0fs   mem=%.0fMB",
                   buildStamp, Date().timeIntervalSince(startedAt), footprintMB()),
        ]
        for sampler in samplers {
            let lines = sampler.sample()
            guard !lines.isEmpty else { continue }
            out.append("[\(sampler.name)]")
            out.append(contentsOf: lines.map { "  " + $0 })
        }
        let cache = MediaCacheServer.shared.probeLines
        if !cache.isEmpty {
            out.append("[cache]")
            out.append(contentsOf: cache.map { "  " + $0 })
        }
        // Last, and deliberately so: it is the block to read when nothing in
        // the live state looks wrong but the session still feels broken.
        let health = healthLines()
        if !health.isEmpty {
            out.append("[health]")
            out.append(contentsOf: health.map { "  " + $0 })
        }
        return out
    }
}

extension Bool {
    /// Compact yes/no for probe lines — `true`/`false` doubles the width of
    /// every state line for no gain when a dozen of them share a row.
    var probe: String { self ? "Y" : "n" }
}

/// Dev-only: serves the colour trail over the LAN as plain text.
///
/// The point is to be able to WATCH a playback session live. The alternative —
/// pulling the app container with `devicectl` — briefly backgrounds the app,
/// which pops auto-PiP over whatever is playing and, worse, fires the
/// `didEnterBackground` observer that clears `SessionDisplayMode`'s pin. That
/// destroys the exact state a colour investigation is trying to observe. A
/// read-only socket costs the session nothing.
///
/// Lives here rather than in its own file purely so it needs no project-file
/// change. Debug builds only, read-only, and it parses nothing the client sends.
@MainActor
final class ColorProbeServer {
    static let shared = ColorProbeServer()

    /// High, fixed, and distinct from the add-on import server's 8099.
    private static let port: UInt16 = 8123
    private var listener: NWListener?

    func start() {
        #if DEBUG
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: port) else { return }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            // One read is enough to see the request line, which is all that
            // picks the route.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, _, _ in
                let head = chunk.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                Task { @MainActor in
                    switch path {
                    case let p where p.hasPrefix("/live"):
                        Self.stream(on: connection, eventsOnly: false)
                    case let p where p.hasPrefix("/events"):
                        Self.stream(on: connection, eventsOnly: true)
                    // `/mark?<anything>` drops a labelled line into the event
                    // stream. During a live session the observer and the
                    // person watching are not the same person: "it just
                    // froze" arrives seconds after the fact, over a tail that
                    // has scrolled on. A mark is an anchor in the ONE clock
                    // both sides share, so the complaint can be lined up with
                    // the events around it afterwards instead of estimated.
                    case let p where p.hasPrefix("/mark"):
                        let note = p.split(separator: "?", maxSplits: 1).dropFirst().first
                            .map { $0.replacingOccurrences(of: "+", with: " ")
                                     .removingPercentEncoding ?? String($0) } ?? "mark"
                        PlayerProbe.event("MARK", "──────── \(note) ────────")
                        Self.sendText(on: connection, "marked: \(note)\n")
                    case let p where p.hasPrefix("/health"):
                        Self.sendText(on: connection,
                                      PlayerProbe.healthLines().joined(separator: "\n") + "\n")
                    case let p where p.hasPrefix("/probe"):
                        Self.sendText(on: connection, PlayerProbe.levels()
                            .joined(separator: "\n") + "\n\n"
                            + PlayerProbe.events(since: 0, limit: 120).lines.joined(separator: "\n") + "\n")
                    default:
                        Self.send(on: connection)
                    }
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        #endif
    }

    /// Live tail: an HTTP response with NO Content-Length that simply never
    /// ends, so `curl` prints it as it arrives. Levels every half second (the
    /// rate a scrub is worth watching at), events the moment they land.
    ///
    /// Deliberately not SSE or JSON — the client for this is a terminal.
    private static func stream(on connection: NWConnection, eventsOnly: Bool) {
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        let banner = "=== orivio live probe — \(eventsOnly ? "events" : "levels + events") ===\n"
        connection.send(content: Data(head.utf8) + Data(banner.utf8),
                        completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            Task { @MainActor in tick(on: connection, since: 0, eventsOnly: eventsOnly, ticks: 0) }
        })
    }

    @MainActor
    private static func tick(on connection: NWConnection, since: UInt64,
                             eventsOnly: Bool, ticks: Int) {
        var body = ""
        let fresh = PlayerProbe.events(since: since)
        if !fresh.lines.isEmpty { body += fresh.lines.joined(separator: "\n") + "\n" }
        // Levels every fourth tick (~2s) rather than every one: they are two
        // dozen lines, and at 2 Hz they would bury the events, which are the
        // part that says what just happened.
        if !eventsOnly, ticks % 4 == 0 {
            let stamp = String(format: "%8.3f", Date().timeIntervalSince(PlayerProbe.startedAt))
            body += "\n\(stamp)  ---- levels ----\n"
            body += PlayerProbe.levels().joined(separator: "\n") + "\n\n"
        }
        let payload = body.isEmpty ? "" : body
        let send: (@escaping () -> Void) -> Void = { done in
            guard !payload.isEmpty else { done(); return }
            connection.send(content: Data(payload.utf8), completion: .contentProcessed { error in
                if error != nil { connection.cancel() } else { done() }
            })
        }
        send {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in
                    tick(on: connection, since: fresh.next, eventsOnly: eventsOnly, ticks: ticks + 1)
                }
            }
        }
    }

    private static func sendText(on connection: NWConnection, _ text: String) {
        let body = Data(text.utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func send(on connection: NWConnection) {
        var trail = UserDefaults.standard.stringArray(forKey: "dev.colorTrail") ?? []
        // The DV trail as well. It lives under its own key, so every line the
        // native-DV path writes — "display settled at Nfps" above all — was
        // invisible to this endpoint and readable only on a console-attached
        // device, which is exactly the situation this server exists to avoid.
        let dv = UserDefaults.standard.stringArray(forKey: "dev.dvTrail") ?? []
        if !dv.isEmpty {
            trail.append("--- dv trail ---")
            trail.append(contentsOf: dv)
        }
        // Live cache state on every read — the trail only records EVENTS, and
        // "how much has actually downloaded" is a level, not an event.
        trail.append(MediaCacheServer.shared.statusLine)
        let body = Data((trail.joined(separator: "\n") + "\n").utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
