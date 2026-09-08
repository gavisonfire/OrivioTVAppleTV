import Foundation
import Network

/// The hybrid disk cache: a localhost HTTP proxy between the player engines
/// and a direct-file stream, Infuse-style.
///
/// The in-memory read-ahead buffer tops out at a few hundred MB on tvOS (see
/// `BufferProfile` — RAM is the ceiling, and jetsam is the penalty), so a deep
/// seek always lands beyond the buffer and stalls on the network. This server
/// downloads the WHOLE file to the app's caches directory at full line speed
/// while playback runs, and serves the engines' range requests from disk — so
/// once a region has downloaded, seeking into it is instant, and a fully
/// downloaded film seeks like a local file.
///
/// Design constraints that shaped it:
/// * One session at a time (one film), replaced on the next `beginSession`.
///   The cache file lives in Caches (purgeable by the OS, cleared eagerly on
///   session end) — nothing survives that shouldn't.
/// * Direct http(s) files only. HLS playlists never qualify (their URLs are
///   many small files, useless to cache this way) and are screened out by
///   extension before a session starts.
/// * Fail OPEN: anything unexpected — origin refuses ranges mid-flight, disk
///   fills, downloader dies — flips the session to redirect mode, and every
///   subsequent request is answered with a 307 to the origin. The engines
///   follow redirects, so the worst case is exactly today's direct playback.
/// * A deep forward seek REPOSITIONS the downloader to the seek point (the
///   viewer's position wins over sequential completeness); the gap left
///   behind is filled after the tail finishes.
/// * SLIDING WINDOW: a film bigger than the free disk still caches — the
///   download fills up to a budget (free space minus slack), then pauses;
///   as playback advances, blocks well behind the playhead are hole-punched
///   out of the sparse file (APFS `F_PUNCHHOLE`) and the download resumes.
///   The window keeps a rewind margin behind the viewer; a request for bytes
///   the window has already passed is answered with a redirect to the origin
///   (fail open, per request). Needs a range-capable origin.
///
/// Everything runs on one serial queue — listener, connections, and the
/// URLSession delegate all target it, so there is no shared-state locking to
/// get wrong.
final class MediaCacheServer {
    static let shared = MediaCacheServer()

    private let q = DispatchQueue(label: "orivio.hybridcache")
    private static let port: UInt16 = 8097
    /// Serving chunk: big enough to saturate a LAN hop, small enough to keep
    /// per-connection memory trivial.
    private static let chunk = 1 << 20

    // MARK: Session state (queue-confined)

    private var origin: URL?
    private var token = ""
    private var fileURL: URL?
    private var writeHandle: FileHandle?
    private var totalLength: Int64 = -1          // -1 until the first response
    /// Sorted, merged, non-overlapping half-open byte ranges present on disk.
    private var ranges: [(start: Int64, end: Int64)] = []
    /// Origin answered 200 to a ranged request → it can't seek; the download
    /// still caches sequentially but jumps are impossible.
    private var rangeCapable = true
    /// Terminal failure → answer everything with a redirect to the origin.
    private var redirectAll = false
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The download POOL. One connection is throttled by the provider, not by
    /// the link — several pulling different chunks is how a 22 GB remux keeps
    /// ahead of playback instead of losing to it by half.
    private var workers: [SegmentDownloader] = []
    /// How many workers may hold a live request right now. Starts gentle,
    /// grows by one per completed chunk, and HALVES when the origin answers
    /// 429/503 — the provider's ceiling is discovered, not assumed.
    private var parallelLimit = 2
    /// No ramp-up (and retries wait) until this passes.
    private var throttledUntil = Date.distantPast
    /// Next byte to hand out. Chunks are assigned in order from here, so the
    /// contiguous coverage the reader needs grows from the front even though
    /// the fetches complete out of order.
    private var fetchCursor: Int64 = 0

    // MARK: Sliding window (queue-confined)

    /// The most bytes this session may hold on disk at once. Equal to the
    /// file size in full-file mode; smaller when `windowed`.
    private var budget: Int64 = 0
    /// The file doesn't fit whole — cache a sliding window of it instead.
    private var windowed = false
    /// The download hit the budget and is waiting for playback to advance.
    private var pausedForSpace = false
    /// `F_PUNCHHOLE` failed once — stop evicting (the window can't slide;
    /// what's cached stays useful, the download just ends at the budget).
    private var evictionBroken = false
    /// Total bytes hole-punched this session, for diagnostics.
    private var evictedTotal: Int64 = 0
    /// Where each live reader currently is, so eviction never pulls bytes out
    /// from under the slowest one.
    private var readOffsets: [ObjectIdentifier: Int64] = [:]
    /// The most recent MINIMUM of the active media readers — the playhead
    /// estimate that survives the moments between range requests when no
    /// reader happens to be connected. (A high-water mark was wrong twice
    /// over: an engine's open probes the file at far offsets, and one such
    /// read dragged the "playhead" deep into the film, mispointing both the
    /// request routing and the sliding window's eviction.)
    private var lastReadOffset: Int64 = 0

    /// Free-space slack always left for the system and other apps.
    private static let slackBytes: Int64 = 1500 * 1_048_576
    /// A window smaller than this isn't worth running.
    private static let minWindowBytes: Int64 = 2048 * 1_048_576
    /// Never evict the container header (MKV SeekHead/Tracks, MP4 moov-at-
    /// front): an engine reopen re-reads it.
    private static let headerProtectBytes: Int64 = 8 * 1_048_576
    /// Rewind margin kept on disk behind the slowest reader.
    private static let keepBehindBytes: Int64 = 256 * 1_048_576
    /// Don't hole-punch dribbles; wait until at least this much is evictable.
    private static let minEvictBytes: Int64 = 64 * 1_048_576
    /// Pause the download when within this margin of the budget…
    private static let writeHeadroomBytes: Int64 = 32 * 1_048_576
    /// …and resume only once at least this much has been freed (hysteresis).
    private static let resumeHeadroomBytes: Int64 = 256 * 1_048_576
    /// An uncovered request this far past the frontier is a deep seek (jump);
    /// anything nearer is about to arrive sequentially anyway.
    private static let jumpAheadSlopBytes: Int64 = 4 * 1_048_576

    /// Ceiling on concurrent range requests. Debrid providers rate-limit per
    /// CONNECTION, so parallelism multiplies throughput — but past the
    /// provider's per-account ceiling it answers 429 instead. `parallelLimit`
    /// ramps toward this and backs off when throttled; this is only the cap.
    private static let workerCount = 5
    /// How far ahead of an active reader the pool tries to stay before doing
    /// background fill. The demand side of the demand-driven pool.
    private static let readerLookaheadBytes: Int64 = 96 * 1_048_576
    /// Bytes per assignment. Large enough that a request's latency is
    /// amortised, small enough that a slow worker can't hold the contiguous
    /// edge back for long — the reader can only advance through bytes that
    /// have MERGED with the coverage in front of it.
    private static let chunkBytes: Int64 = 8 * 1_048_576

    /// A bounded range request this far from the frontier is metadata, not
    /// playback — MKV cues and MP4 moov tables sit at the END of the file and
    /// the demuxer reads them repeatedly while probing. Fetch those on the
    /// side instead of dragging the sequential download to them.
    private static let sideFetchMaxBytes: Int64 = 8 * 1_048_576
    /// Side fetches in flight, keyed by start offset (also the de-dup — the
    /// demuxer asks for the same cue block more than once).
    private var sideFetchers: [Int64: SideFetcher] = [:]
    /// Their byte spans, so chunk assignment treats them as claimed.
    private var sideFetchSpans: [Int64: Int64] = [:]
    /// The end of the CONTIGUOUS run of cached bytes in front of the reader —
    /// the only frontier that means anything to a player, since it can only
    /// advance through bytes that have merged with what it is already reading.
    ///
    /// Emphatically NOT `ranges.last?.end`: once a side fetch has pulled the
    /// container index in from the tail, the last range ENDS AT THE END OF THE
    /// FILE. Every subsequent request then looked like it was safely behind
    /// the download, so a cue read in the middle of the file neither jumped
    /// nor side-fetched — it just waited for bytes that were hundreds of
    /// megabytes away, and the engine hung there. Nor is it "the last byte
    /// written": with a parallel pool those land out of order.
    private var downloadHead: Int64 { coverageEnd(from: minActiveRead()) }

    /// Dev diagnostics: how many proxy requests have been narrated to the
    /// trail. Bounded — an engine makes hundreds and the trail holds 40 lines.
    private var loggedRequests = 0
    private func requestTrail(_ line: String) {
        guard loggedRequests < 18 else { return }
        loggedRequests += 1
        PlayerViewModel.colorTrail("proxy \(line)")
    }

    // MARK: - HUD snapshot

    /// A lock-guarded copy of the session's coverage, readable from the main
    /// actor every clock tick without touching the server queue — the player's
    /// cache bar draws from this.
    private let snapshotLock = NSLock()
    private var snapshotRanges: [(start: Int64, end: Int64)] = []
    private var snapshotTotal: Int64 = -1
    /// Why the session failed, when it has — published so the UI can stop
    /// pretending a cache is live and fall back to the engine's buffer band.
    private var snapshotFailure: String?
    /// Queue-confined master copy of the failure reason.
    private var failureReason: String?
    private var snapshotWindow: String?
    private var snapshotPool = ""
    /// How far the download is AHEAD of the furthest reader. Negative or tiny
    /// means the download is barely keeping up (or losing) and nothing else
    /// should be competing with it for the connection, the disk or the CPU.
    private var snapshotLead: Int64 = 0

    private func publishSnapshot() {
        snapshotLock.lock()
        snapshotRanges = ranges
        snapshotTotal = totalLength
        snapshotFailure = failureReason
        snapshotWindow = windowed
            ? "window budget=\(budget) paused=\(pausedForSpace) evicted=\(evictedTotal)\(evictionBroken ? " EVICTION BROKEN" : "")"
            : nil
        snapshotLead = downloadHead - minActiveRead()
        snapshotPool = "pool=\(workers.count(where: { !$0.isIdle }))/\(parallelLimit)"
        snapshotLock.unlock()
    }

    /// One-line state for diagnostics (the dev probe endpoint): totals, how
    /// much is on disk, and the failure reason when the session has bailed.
    var statusLine: String {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard snapshotTotal != -1 || snapshotFailure != nil || !snapshotRanges.isEmpty else {
            return "cache: no session"
        }
        let onDisk = snapshotRanges.reduce(Int64(0)) { $0 + ($1.end - $1.start) }
        var line = "cache: total=\(snapshotTotal) onDisk=\(onDisk) ranges=\(snapshotRanges.count)"
            + " lead=\(snapshotLead / 1_048_576)MB \(snapshotPool)"
        if let window = snapshotWindow { line += " " + window }
        if let failure = snapshotFailure { line += " FAILED: \(failure)" }
        return line
    }

    /// How far (as a fraction of the whole file) the on-disk cache extends
    /// CONTIGUOUSLY from the given playback fraction — what the growing cache
    /// bar shows ahead of the playhead. 0 when no session is live. Byte↔time
    /// mapping is linear, which is exactly as honest as any player's buffer
    /// bar for variable-bitrate files.
    /// A hybrid-cache session is running (a file is being written for the
    /// current stream). Read from the snapshot so it is safe on the main actor.
    var hasLiveSession: Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        // A failed session is not live: leaving this true suppressed even the
        // engine-buffer fallback band, so a disk-space bail-out erased the
        // band entirely instead of degrading to the normal sliver.
        return snapshotTotal > 0 && snapshotFailure == nil
    }

    func coverageFraction(fromTimeFraction f: Double) -> Double {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard snapshotTotal > 0 else { return 0 }
        let byte = Int64(min(max(f, 0), 1) * Double(snapshotTotal))
        for range in snapshotRanges where range.start <= byte && byte <= range.end {
            return Double(range.end) / Double(snapshotTotal)
        }
        // The linear time→byte estimate can land a little short of where the
        // engine is actually reading (variable bitrate, container header).
        // The segment being written just ahead of the playhead IS the cache
        // the viewer is watching grow — show it rather than nothing.
        if let ahead = snapshotRanges.first(where: { $0.start > byte }),
           ahead.start - byte < snapshotTotal / 50 {
            return Double(ahead.end) / Double(snapshotTotal)
        }
        return 0
    }

    /// How far the download is ahead of the furthest reader, in bytes. The
    /// honest measure of whether the cache is winning: on a high-bitrate remux
    /// it can be pinned near zero, and anything else touching the file then
    /// makes playback worse rather than better.
    var readerLeadBytes: Int64 {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotLead
    }

    /// Covered byte ranges as 0…1 fractions of the file — what a scheduler
    /// needs to run work over ONLY the parts already on disk (the scrub
    /// preview pass). Empty until the file's length is known.
    var coveredFractions: [(start: Double, end: Double)] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard snapshotTotal > 0 else { return [] }
        let total = Double(snapshotTotal)
        return snapshotRanges.map { (Double($0.start) / total, Double($0.end) / total) }
    }

    /// The cache-only twin of the playback URL for the live session. Reads on
    /// this lane are served solely from bytes already on disk: they never
    /// reposition the downloader, never wait for the network (an uncovered
    /// request is answered 416 immediately, a coverage edge closes the
    /// connection), and never count as playback for the sliding window's
    /// eviction. Built for the scrub-preview pass, whose seeks all over the
    /// file would otherwise drag the sequential download around with them.
    var thumbnailURL: URL? {
        q.sync {
            guard !token.isEmpty, listener != nil, let origin else { return nil }
            let ext = origin.pathExtension.lowercased()
            let name = ext.isEmpty ? "v" : "v.\(ext)"
            return URL(string: "http://127.0.0.1:\(Self.port)/t/\(token)/\(name)")
        }
    }

    // MARK: - Public API (called from the main actor)

    /// Start caching `origin` and return the localhost URL to play instead,
    /// or nil when the stream doesn't qualify (non-http, already proxied,
    /// HLS/playlist) or the listener can't start. Ends any previous session.
    func beginSession(origin: URL) -> URL? {
        guard let scheme = origin.scheme?.lowercased(), scheme == "http" || scheme == "https",
              origin.host != "127.0.0.1", origin.host != "localhost" else { return nil }
        let ext = origin.pathExtension.lowercased()
        guard ext != "m3u8", ext != "m3u" else { return nil }
        return q.sync {
            // RE-ENTRY FOR THE SAME FILM keeps the live session and hands back
            // the SAME url. Two reasons, and the first is severe:
            //
            // 1. The token is a fresh UUID per session, so restarting here
            //    minted a NEW proxy url every time — and the player's
            //    "don't do this again" guards (`dvFirstTried`, `dvFailedURLs`,
            //    `probedURLs`) are all keyed on the url string. None of them
            //    could ever match, so a DV-first attempt retried forever. Worse,
            //    the teardown killed the connection feeding the engine that had
            //    just been started, which failed it over into another load —
            //    a self-sustaining reload loop in which nothing ever played.
            // 2. Even without that, throwing away a partly-downloaded film on
            //    an engine swap or a failover is pure waste.
            if self.origin == origin, !token.isEmpty, listener != nil,
               writeHandle != nil, failureReason == nil {
                return proxyURL(for: origin)
            }
            teardownSessionLocked()
            guard startListenerLocked() else { return nil }
            self.origin = origin
            token = UUID().uuidString
            redirectAll = false
            rangeCapable = true
            totalLength = -1
            ranges = []
            loggedRequests = 0
            sideFetchers = [:]
            sideFetchSpans = [:]
            budget = 0
            windowed = false
            pausedForSpace = false
            evictionBroken = false
            evictedTotal = 0
            readOffsets = [:]
            lastReadOffset = 0
            let dir = Self.cacheDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("current.bin")
            try? FileManager.default.removeItem(at: file)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
            fileURL = file
            writeHandle = handle
            fetchCursor = 0
            parallelLimit = 2
            throttledUntil = .distantPast
            ensurePool()
            return proxyURL(for: origin)
        }
    }

    /// The playback url for the live session. Keeps the origin's extension:
    /// the engine router picks native-vs-FFmpeg by it, and losing ".mkv" would
    /// send Matroska to AVPlayer.
    private func proxyURL(for origin: URL) -> URL? {
        let ext = origin.pathExtension.lowercased()
        let name = ext.isEmpty ? "v" : "v.\(ext)"
        return URL(string: "http://127.0.0.1:\(Self.port)/m/\(token)/\(name)")
    }

    /// Stop downloading, drop every connection, delete the cache file.
    func endSession() {
        q.sync { teardownSessionLocked() }
    }

    // MARK: - Session teardown (on q)

    private func teardownSessionLocked() {
        for worker in workers { worker.cancel() }
        workers = []
        fetchCursor = 0
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        try? writeHandle?.close()
        writeHandle = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        origin = nil
        token = ""
        ranges = []
        totalLength = -1
        failureReason = nil
        budget = 0
        windowed = false
        pausedForSpace = false
        evictionBroken = false
        evictedTotal = 0
        readOffsets = [:]
        lastReadOffset = 0
        sideFetchers = [:]
        sideFetchSpans = [:]
        parallelLimit = 2
        throttledUntil = .distantPast
        publishSnapshot()
    }

    /// Fetch a small, far-away byte range on its own connection, leaving the
    /// sequential downloader exactly where it is.
    ///
    /// Repositioning the main downloader for a container's index (what `jump`
    /// does) abandons the download that is feeding playback, and the two then
    /// pull against each other: the demuxer re-reads the cues, the downloader
    /// is yanked to the tail again, and the front creeps forward a few KB at a
    /// time. That is a startup that never finishes, not a slow one.
    private func sideFetch(start: Int64, endExclusive: Int64, attempt: Int = 0) {
        guard let origin, writeHandle != nil, !redirectAll else { return }
        guard sideFetchers[start] == nil else { return }   // already in flight
        // NEVER drop the request on the floor: the connection that triggered
        // it is sitting in `serve` waiting for those bytes, and with nobody
        // fetching them it waits out the full 60s stall timeout — the
        // intermittent "sometimes it just doesn't play". At capacity, wait a
        // beat and try again; capacity is small on purpose, because these
        // connections count against the same provider ceiling as the pool.
        guard sideFetchers.count < 3 else {
            q.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.sideFetch(start: start, endExclusive: endExclusive, attempt: attempt)
            }
            return
        }
        sideFetchSpans[start] = endExclusive
        sideFetchers[start] = SideFetcher(
            origin: origin, start: start, endExclusive: endExclusive, queue: q
        ) { [weak self] data in
            guard let self else { return }
            self.sideFetchers[start] = nil
            self.sideFetchSpans[start] = nil
            if let data, self.writeHandle != nil {
                self.downloaderWrote(data, at: start, isSideFetch: true)
            } else if attempt < 3 {
                // Backed-off retry — a 429 here clears in seconds.
                self.q.asyncAfter(deadline: .now() + Double(attempt + 1) * 2) { [weak self] in
                    self?.sideFetch(start: start, endExclusive: endExclusive, attempt: attempt + 1)
                }
            } else {
                self.requestTrail("SIDE-FETCH failed at \(start) — reader will fail over")
            }
        }
    }

    private static func cacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("hybrid-cache", isDirectory: true)
    }

    // MARK: - Listener (on q)

    private func startListenerLocked() -> Bool {
        if listener != nil { return true }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Localhost only — this is a private pipe to the player, not a
            // LAN service like the phone-paste server.
            params.requiredInterfaceType = .loopback
            guard let port = NWEndpoint.Port(rawValue: Self.port) else { return false }
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.q.async { self?.accept(connection) }
            }
            listener.start(queue: q)
            self.listener = listener
            return true
        } catch {
            NSLog("[OrivioCache] listener failed: %@", "\(error)")
            return false
        }
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state, let connection {
                self?.q.async { self?.drop(connection) }
            }
        }
        connection.start(queue: q)
        readRequest(connection, buffer: Data())
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        readOffsets.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if error != nil { self.drop(connection); return }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || buffer.count > 32 * 1024 { self.drop(connection) }
                else { self.readRequest(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            self.route(head, on: connection)
        }
    }

    // MARK: - Request handling (on q)

    private func route(_ head: String, on connection: NWConnection) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2 else { drop(connection); return }
        let method = String(requestParts[0])
        let path = String(requestParts[1])
        guard method == "GET" || method == "HEAD" else {
            sendSimple(connection, "405 Method Not Allowed"); return
        }
        let cacheOnly = path.hasPrefix("/t/\(token)/")
        guard !token.isEmpty, path.hasPrefix("/m/\(token)/") || cacheOnly else {
            sendSimple(connection, "404 Not Found"); return
        }
        var requestedRange: (Int64, Int64?)?   // (start, inclusive end?)
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix("range:"), let eq = line.range(of: "bytes=") else { continue }
            let spec = line[eq.upperBound...].split(separator: "-", maxSplits: 1,
                                                    omittingEmptySubsequences: false)
            guard let first = spec.first, let start = Int64(first.trimmingCharacters(in: .whitespaces))
            else { continue }
            let end = spec.count > 1 ? Int64(spec[1].trimmingCharacters(in: .whitespaces)) : nil
            requestedRange = (start, end)
        }
        // The first origin response tells us the length; wait briefly for it.
        awaitMetadata(deadline: Date().addingTimeInterval(20)) { [weak self] ready in
            guard let self else { return }
            guard ready, !self.redirectAll, self.totalLength > 0 else {
                // The cache-only lane never redirects to the origin — its whole
                // contract is "disk or nothing".
                if cacheOnly { self.sendSimple(connection, "503 Service Unavailable") }
                else { self.sendRedirect(connection) }
                return
            }
            self.beginResponse(connection, method: method, range: requestedRange, cacheOnly: cacheOnly)
        }
    }

    private func awaitMetadata(deadline: Date, _ completion: @escaping (Bool) -> Void) {
        if totalLength > 0 || redirectAll { completion(true); return }
        guard Date() < deadline else { completion(false); return }
        q.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.awaitMetadata(deadline: deadline, completion)
        }
    }

    private func beginResponse(_ connection: NWConnection, method: String, range: (Int64, Int64?)?, cacheOnly: Bool = false) {
        let total = totalLength
        let start = min(max(range?.0 ?? 0, 0), total)
        let endExclusive = range.map { min(($0.1 ?? (total - 1)) + 1, total) } ?? total
        guard start < endExclusive else { sendSimple(connection, "416 Range Not Satisfiable"); return }

        requestTrail("\(cacheOnly ? "/t" : "/m") \(method) start=\(start) end=\(endExclusive)"
            + " covEnd=\(coverageEnd(from: start)) head=\(downloadHead) ranges=\(ranges.count)")
        // Cache-only lane: what's on disk or a fast refusal — no jump, no
        // redirect, no waiting on the network.
        if cacheOnly {
            if coverageEnd(from: start) == start, start < total, method != "HEAD" {
                sendSimple(connection, "416 Range Not Satisfiable")
                return
            }
        }
        // Route an uncovered request. Small bounded reads are container
        // metadata (MKV cues, MP4 tables) and get their own connection; a big
        // or open-ended read is a PLAYBACK reader, which registers its
        // position below and is then fed by the demand side of the pool —
        // nothing repositions, nothing thrashes, and several concurrent probe
        // readers each just become demand.
        else if rangeCapable, coverageEnd(from: start) == start, start < total {
            if endExclusive - start <= Self.sideFetchMaxBytes {
                requestTrail("SIDE-FETCH \(start)..<\(endExclusive)")
                sideFetch(start: start, endExclusive: endExclusive)
            } else if windowed,
                      let windowStart = ranges.first(where: { $0.end > Self.headerProtectBytes })?.start,
                      start < windowStart {
                // Behind the sliding window — those bytes were EVICTED and the
                // window will not go back for them; this reader gets the
                // origin directly.
                sendRedirect(connection)
                return
            }
        }
        let mediaRead = !cacheOnly && endExclusive - start > Self.sideFetchMaxBytes

        let contentType: String
        switch origin?.pathExtension.lowercased() {
        case "mp4", "m4v": contentType = "video/mp4"
        case "mkv": contentType = "video/x-matroska"
        case "avi": contentType = "video/x-msvideo"
        case "ts": contentType = "video/mp2t"
        default: contentType = "application/octet-stream"
        }
        var head = range == nil
            ? "HTTP/1.1 200 OK\r\n"
            : "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(endExclusive - 1)/\(total)\r\n"
        head += """
        Content-Type: \(contentType)\r
        Content-Length: \(endExclusive - start)\r
        Accept-Ranges: bytes\r
        Connection: close\r
        \r

        """
        // Only PLAYBACK readers steer eviction, demand and the playhead
        // estimate. Metadata reads must not: one cue read at the tail of a
        // 22 GB file dragged the "playhead" to the end of the film, which
        // broke the request routing (mid-file reads waited on bytes nobody
        // was fetching) and pointed eviction at everything the real reader
        // still needed.
        if mediaRead {
            readOffsets[ObjectIdentifier(connection)] = start
            kickPool()   // fresh demand — put idle capacity on it now
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.q.async {
                if error != nil || method == "HEAD" { self.finish(connection); return }
                guard let fileURL = self.fileURL,
                      let reader = try? FileHandle(forReadingFrom: fileURL) else {
                    self.drop(connection); return
                }
                self.serve(connection, reader: reader, offset: start,
                           endExclusive: endExclusive, stalledSince: nil,
                           cacheOnly: cacheOnly, mediaRead: mediaRead)
            }
        })
    }

    /// Pump bytes from the cache file to the player as they become available.
    /// Backpressure is the send-completion; availability gaps poll at 80ms —
    /// crude, but local, cheap, and immune to lost-wakeup bugs.
    private func serve(_ connection: NWConnection, reader: FileHandle,
                       offset: Int64, endExclusive: Int64, stalledSince: Date?,
                       cacheOnly: Bool = false, mediaRead: Bool = false) {
        guard connections[ObjectIdentifier(connection)] != nil else {
            try? reader.close(); return
        }
        if offset >= endExclusive {
            try? reader.close()
            finish(connection)
            return
        }
        let available = min(coverageEnd(from: offset), endExclusive)
        guard available > offset else {
            // Cache-only lane: the coverage edge is the end of the story —
            // close rather than wait for the network to catch up.
            if cacheOnly {
                try? reader.close()
                drop(connection)
                return
            }
            // Nothing on disk here yet. If the download has died this will
            // never change — cut the connection so the engine's own failover
            // takes over (its retry meets `redirectAll` and plays direct).
            if redirectAll || (stalledSince.map { Date().timeIntervalSince($0) > 60 } ?? false) {
                requestTrail("STALL-DROP at \(offset) (covEnd=\(coverageEnd(from: offset)))")
                try? reader.close()
                drop(connection)
                return
            }
            if stalledSince == nil { requestTrail("waiting at \(offset) head=\(downloadHead)") }
            // A READER WAITING IS ALSO PROGRESS. `resumeIfRoom` used to be
            // called only from the send-completion path — i.e. only while
            // bytes were actually flowing — so a window that had filled to its
            // budget while a reader sat waiting for bytes just past the edge
            // could never slide: the download stayed parked waiting for
            // playback to advance, and playback waited for the download. The
            // cache stopped dead until the 60s stall timeout killed the
            // connection. Publish where this reader is and try to make room.
            if mediaRead {
                readOffsets[ObjectIdentifier(connection)] = offset
                lastReadOffset = readOffsets.values.min() ?? offset
                publishSnapshot()
                resumeIfRoom()
            }
            // Equally: an all-idle pool leaves nobody fetching what this
            // reader is waiting for.
            if !pausedForSpace, workers.allSatisfy(\.isIdle) { kickPool() }
            q.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.serve(connection, reader: reader, offset: offset,
                            endExclusive: endExclusive, stalledSince: stalledSince ?? Date(),
                            cacheOnly: cacheOnly, mediaRead: mediaRead)
            }
            return
        }
        let count = Int(min(Int64(Self.chunk), available - offset))
        try? reader.seek(toOffset: UInt64(offset))
        guard let data = try? reader.read(upToCount: count), !data.isEmpty else {
            try? reader.close(); drop(connection); return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.q.async {
                if error != nil { try? reader.close(); self.drop(connection); return }
                let next = offset + Int64(data.count)
                if mediaRead {
                    self.readOffsets[ObjectIdentifier(connection)] = next
                    self.lastReadOffset = self.readOffsets.values.min() ?? next
                    self.resumeIfRoom()
                }
                self.serve(connection, reader: reader, offset: next,
                           endExclusive: endExclusive, stalledSince: nil,
                           cacheOnly: cacheOnly, mediaRead: mediaRead)
            }
        })
    }

    private func finish(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.q.async { self?.drop(connection) }
        })
    }

    private func sendSimple(_ connection: NWConnection, _ status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.q.async { self?.drop(connection) }
        })
    }

    /// Fail-open path: hand the engine the origin and get out of the way.
    private func sendRedirect(_ connection: NWConnection) {
        guard let origin else { sendSimple(connection, "404 Not Found"); return }
        let head = "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(origin.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.q.async { self?.drop(connection) }
        })
    }

    // MARK: - Range bookkeeping (on q)

    /// How far the on-disk data extends CONTIGUOUSLY from `offset`.
    private func coverageEnd(from offset: Int64) -> Int64 {
        for range in ranges where range.start <= offset && offset < range.end {
            return range.end
        }
        return offset
    }

    private func addRange(start: Int64, end: Int64) {
        guard end > start else { return }
        ranges.append((start, end))
        ranges.sort { $0.start < $1.start }
        var merged: [(start: Int64, end: Int64)] = []
        for range in ranges {
            if var last = merged.last, range.start <= last.end {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        ranges = merged
        publishSnapshot()
    }


    // MARK: - Downloader callbacks (on q)

    /// What a worker should do with the response it just received.
    enum ResponseVerdict {
        case allow
        /// Throttled (429/503) or transiently broken: keep the segment, retry
        /// it after the delay. The provider's ceiling was discovered, not
        /// fatal — one 429 used to kill the entire cache session.
        case retryLater(TimeInterval)
        /// Origin ignored the Range header mid-file: restart from zero.
        case restartAtZero
        /// The session is over (failSession already ran) — stand down.
        case abandon
    }

    fileprivate func downloaderGotResponse(_ response: HTTPURLResponse, requestedOffset: Int64) -> ResponseVerdict {
        switch response.statusCode {
        case 206:
            // "bytes X-Y/TOTAL"
            if totalLength <= 0,
               let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
               let totalPart = contentRange.split(separator: "/").last,
               let total = Int64(totalPart) {
                totalLength = total
                publishSnapshot()
                guard configureBudget() else { return .abandon }
                fillPool()
            }
            return .allow
        case 200:
            if requestedOffset > 0 {
                // Origin ignored the Range header — it can't seek. What's
                // cached so far still serves; jumps are off the table.
                rangeCapable = false
                return .restartAtZero
            }
            rangeCapable = false
            totalLength = response.expectedContentLength
            guard totalLength > 0 else {
                failSession("origin sent no content length")
                return .abandon
            }
            publishSnapshot()
            guard configureBudget() else { return .abandon }
            fillPool()
            return .allow
        case 429, 503:
            // Too many connections for this provider: halve the parallelism,
            // hold the ramp for a while, and retry the same chunk shortly.
            parallelLimit = max(1, parallelLimit / 2)
            throttledUntil = Date().addingTimeInterval(8)
            requestTrail("origin throttled (\(response.statusCode)) — backing off to \(parallelLimit) connection\(parallelLimit == 1 ? "" : "s")")
            publishSnapshot()
            return .retryLater(4)
        default:
            failSession("origin answered \(response.statusCode)")
            return .abandon
        }
    }

    fileprivate func downloaderWrote(_ data: Data, at offset: Int64, isSideFetch: Bool = false) {
        guard let writeHandle else { return }
        do {
            try writeHandle.seek(toOffset: UInt64(offset))
            try writeHandle.write(contentsOf: data)
            addRange(start: offset, end: offset + Int64(data.count))
        } catch {
            failSession("disk write failed: \(error.localizedDescription)")
            return
        }
        // Sliding window: approach the budget, slide or pause. The headroom
        // absorbs the chunks URLSession has already queued for delivery.
        if windowed, usedBytes() + Self.writeHeadroomBytes > budget {
            evictBehind()
            if usedBytes() + Self.writeHeadroomBytes > budget { pauseForSpaceIfNeeded() }
        }
    }

    /// A throttled worker asks to resume through the SERVER, not by itself:
    /// a self-timed restart bypassed `parallelLimit`, so five workers that
    /// were 429'd together all came back together — re-tripping the very
    /// ceiling the back-off had just discovered. The abandoned segment isn't
    /// lost either way: with no task it is unclaimed, and the next
    /// `pickChunk` hands it out again.
    fileprivate func downloaderThrottled(_ worker: SegmentDownloader,
                                         resumeAt offset: Int64, end: Int64?,
                                         after delay: TimeInterval) {
        q.asyncAfter(deadline: .now() + delay) { [weak self, weak worker] in
            guard let self, !self.redirectAll, !self.pausedForSpace else { return }
            guard let worker, worker.isIdle else { return }
            if self.workers.count(where: { !$0.isIdle }) < self.parallelLimit {
                worker.start(at: offset, endExclusive: end)
            } else {
                self.kickPool()
            }
        }
    }

    fileprivate func downloaderFinishedSegment(_ worker: SegmentDownloader) {
        // A finished chunk is evidence the provider is happy at this rate —
        // grow toward the ceiling, then put every idle worker (this one
        // included) onto whatever needs fetching most.
        if Date() > throttledUntil, parallelLimit < Self.workerCount {
            parallelLimit += 1
        }
        kickPool()
    }

    fileprivate func downloaderFailed(_ worker: SegmentDownloader) {
        // One worker dying is not the session dying — the others carry on and
        // the pool is topped back up. Only losing ALL of them is terminal.
        retire(worker)
        if workers.isEmpty { failSession("every download connection failed") }
    }

    fileprivate func retire(_ worker: SegmentDownloader) {
        worker.cancel()
        workers.removeAll { $0 === worker }
    }

    // MARK: - Download pool (on q)

    /// Make sure the pool exists, then put idle capacity to work.
    private func ensurePool() {
        guard !redirectAll, writeHandle != nil, let origin else { return }
        let target = rangeCapable ? Self.workerCount : 1
        while workers.count < target {
            workers.append(SegmentDownloader(server: self, origin: origin, queue: q))
        }
        kickPool()
    }

    /// Deferred `kickPool` — for callers running inside a worker's own
    /// delegate callback, where starting siblings would re-enter.
    private func fillPool() {
        q.async { [weak self] in self?.kickPool() }
    }

    /// Assign work to idle workers, demand first, until the adaptive
    /// parallelism limit or the work runs out.
    private func kickPool() {
        guard !redirectAll, !pausedForSpace, writeHandle != nil else { return }
        for worker in workers where worker.isIdle {
            guard workers.count(where: { !$0.isIdle }) < parallelLimit else { return }
            guard assignChunk(to: worker) else { return }
        }
    }

    /// Hand `worker` the most useful unclaimed chunk. False = nothing to do.
    @discardableResult
    private func assignChunk(to worker: SegmentDownloader) -> Bool {
        guard !redirectAll, !pausedForSpace, writeHandle != nil else { return false }
        // BOOTSTRAP. The file's length is only learned from the first
        // response's Content-Range, so the opening request goes out WITHOUT
        // it — requiring the length first meant every worker parked waiting
        // for a fact only a worker could learn, and nothing ever downloaded.
        guard totalLength > 0 else {
            guard workers.first === worker else { return false }
            worker.start(at: fetchCursor, endExclusive: fetchCursor + Self.chunkBytes)
            return true
        }
        guard rangeCapable else {
            // No ranges: one open-ended stream from zero is all the origin
            // allows — and only while something is actually missing, or a
            // finished stream's completion would start the whole download
            // over from the top, forever.
            guard nextUnclaimedGap(from: 0) != nil else { return false }
            worker.start(at: 0, endExclusive: nil)
            return true
        }
        guard let gap = pickChunk() else {
            if workers.allSatisfy(\.isIdle) {
                NSLog("[OrivioCache] %@ (%lld bytes)",
                      windowed ? "window reaches the end of the file" : "file fully cached",
                      totalLength)
            }
            return false
        }
        worker.start(at: gap.start, endExclusive: gap.end)
        return true
    }

    /// The most useful chunk to fetch next. DEMAND FIRST: the active reader
    /// with the least contiguous road ahead of it gets fed before any
    /// background filling — that is what lets a freshly opened engine (which
    /// probes at several offsets at once) come up without anyone repositioning
    /// anything. Then the background cursor, then hole-filling.
    private func pickChunk() -> (start: Int64, end: Int64)? {
        var best: (lead: Int64, gap: (start: Int64, end: Int64))?
        for readerOffset in readOffsets.values {
            let edge = coverageEnd(from: readerOffset)
            let lead = edge - readerOffset
            guard lead < Self.readerLookaheadBytes,
                  let gap = nextUnclaimedGap(from: edge),
                  gap.start < readerOffset + Self.readerLookaheadBytes
            else { continue }
            if best == nil || lead < best!.lead { best = (lead, gap) }
        }
        if let best { return bounded(best.gap) }
        if let gap = nextUnclaimedGap(from: fetchCursor) {
            let chunk = bounded(gap)
            fetchCursor = max(fetchCursor, chunk.end)
            return chunk
        }
        // Holes left behind by seeks — but never behind the sliding window.
        if let gap = nextUnclaimedGap(from: windowed ? minActiveRead() : 0) {
            return bounded(gap)
        }
        return nil
    }

    private func bounded(_ gap: (start: Int64, end: Int64)) -> (start: Int64, end: Int64) {
        (gap.start, min(gap.start + Self.chunkBytes, gap.end))
    }

    /// First byte at or after `cursor` that is neither on disk NOR already
    /// being fetched. Ignoring in-flight segments here was the duplicate-
    /// download bug: two workers pulling the same bytes, halving throughput
    /// and doubling the connection count the provider sees.
    private func nextUnclaimedGap(from cursor: Int64) -> (start: Int64, end: Int64)? {
        guard totalLength > 0 else { return nil }
        var spans = ranges
        for worker in workers {
            if let pending = worker.pendingSegment { spans.append(pending) }
        }
        for (start, end) in sideFetchSpans { spans.append((start, end)) }
        spans.sort { $0.start < $1.start }
        var probe = max(0, min(cursor, totalLength))
        for span in spans where span.end > probe {
            if span.start > probe { return (probe, min(span.start, totalLength)) }
            probe = max(probe, span.end)
        }
        return probe < totalLength ? (probe, totalLength) : nil
    }

    private func failSession(_ reason: String) {
        // Fail OPEN, but never silently: the reason reaches the colour trail
        // (readable live over the dev probe endpoint) and the snapshot, so
        // the UI knows the cache is gone and the band can fall back honestly.
        NSLog("[OrivioCache] session failed: %@ — redirecting to origin", reason)
        PlayerViewModel.colorTrail("cache session failed: \(reason) — direct playback from origin")
        failureReason = reason
        redirectAll = true
        for worker in workers { worker.cancel() }
        workers = []
        publishSnapshot()
    }

    /// Decide what this session may hold on disk, now that the file's size is
    /// known. A film that fits whole gets the original full-file behaviour; a
    /// bigger one gets a sliding window when the origin can seek; only a box
    /// too full for even a useful window falls back to direct playback.
    private func configureBudget() -> Bool {
        guard let dir = fileURL?.deletingLastPathComponent() else { return false }
        // Plain capacity — the "important usage" variant doesn't exist on tvOS.
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let free = values?.volumeAvailableCapacity.map(Int64.init) else {
            budget = totalLength   // unknowable — behave as before and hope
            return true
        }
        let available = max(0, free - Self.slackBytes)
        let totalGB = Double(totalLength) / 1e9
        let freeGB = Double(free) / 1e9
        if totalLength <= available {
            budget = totalLength
            windowed = false
            publishSnapshot()
            return true
        }
        guard rangeCapable else {
            failSession(String(format: "file is %.1f GB with %.1f GB free, and the origin can't seek — a sliding window needs range requests", totalGB, freeGB))
            return false
        }
        guard available >= Self.minWindowBytes else {
            failSession(String(format: "not enough space even for a sliding window (file is %.1f GB, %.1f GB free)", totalGB, freeGB))
            return false
        }
        budget = available
        windowed = true
        publishSnapshot()
        let line = String(format: "cache: sliding window — %.1f GB of the %.1f GB file, evicting behind playback", Double(budget) / 1e9, totalGB)
        NSLog("[OrivioCache] %@", line)
        PlayerViewModel.colorTrail(line)
        return true
    }

    /// Bytes currently held on disk.
    private func usedBytes() -> Int64 {
        ranges.reduce(0) { $0 + ($1.end - $1.start) }
    }

    /// The slowest live reader's position — the point eviction must respect.
    private func minActiveRead() -> Int64 {
        readOffsets.values.min() ?? lastReadOffset
    }

    /// Punch the byte range out of the sparse cache file, returning the
    /// blocks to the filesystem. Bounds are block-aligned inward; the caller
    /// removes exactly the same aligned span from `ranges`.
    private func punchHole(from start: Int64, to end: Int64) -> Bool {
        guard let fd = writeHandle?.fileDescriptor else { return false }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0,
                                fp_offset: off_t(start), fp_length: off_t(end - start))
        return fcntl(fd, F_PUNCHHOLE, &hole) == 0
    }

    /// Evict cached bytes behind the slowest reader (keeping the header and a
    /// rewind margin) so the window can slide forward. Returns bytes freed.
    @discardableResult
    private func evictBehind() -> Int64 {
        guard windowed, !evictionBroken else { return 0 }
        let blockSize: Int64 = 4096
        let protect = max(Self.headerProtectBytes, minActiveRead() - Self.keepBehindBytes)
        var freed: Int64 = 0
        var kept: [(start: Int64, end: Int64)] = []
        for range in ranges {
            // Aligned inward so the punched span and the bookkeeping match.
            let evictStart = (max(range.start, Self.headerProtectBytes) + blockSize - 1) / blockSize * blockSize
            let evictEnd = min(range.end, protect) / blockSize * blockSize
            guard evictEnd - evictStart >= Self.minEvictBytes else { kept.append(range); continue }
            guard punchHole(from: evictStart, to: evictEnd) else {
                evictionBroken = true
                NSLog("[OrivioCache] F_PUNCHHOLE failed — window can't slide, capping at budget")
                PlayerViewModel.colorTrail("cache: hole punch failed — window frozen at budget")
                kept.append(range)
                continue
            }
            freed += evictEnd - evictStart
            if evictStart > range.start { kept.append((range.start, evictStart)) }
            if range.end > evictEnd { kept.append((evictEnd, range.end)) }
        }
        if freed > 0 {
            ranges = kept
            evictedTotal += freed
            publishSnapshot()
        }
        return freed
    }

    /// The download reached the budget: stop the network until playback has
    /// advanced far enough to evict something.
    private func pauseForSpaceIfNeeded() {
        guard !pausedForSpace else { return }
        pausedForSpace = true
        for worker in workers { worker.cancelSegment() }
        publishSnapshot()
        NSLog("[OrivioCache] window full (%lld of %lld) — download paused until playback advances", usedBytes(), budget)
    }

    /// Called as reads advance: if the download is parked on a full window,
    /// try to slide it and pick the download back up.
    private func resumeIfRoom() {
        guard pausedForSpace else { return }
        evictBehind()
        guard usedBytes() + Self.resumeHeadroomBytes <= budget else { return }
        pausedForSpace = false
        kickPool()
        publishSnapshot()
        NSLog("[OrivioCache] window slid — download resumed")
    }
}

// MARK: - Segment downloader

/// One bounded range fetch on its own connection, for data far from the
/// sequential frontier (a container's index).
///
/// Delegate-based rather than a completion-handler `dataTask`, for one
/// specific reason: a completion handler buffers the ENTIRE response before
/// anything can inspect it, so an origin that ignores the Range header and
/// answers 200 with the whole file would be held in memory in full — a 4 GB
/// remux is a jetsam kill on a 3 GB box, and writing it at the requested
/// offset would corrupt the cache besides. Here the response is inspected
/// first and anything but a 206 is cancelled before a byte is buffered.
private final class SideFetcher: NSObject, URLSessionDataDelegate {
    private let span: Int64
    private let completion: (Data?) -> Void
    private var session: URLSession!
    private var buffer = Data()
    private var finished = false

    init(origin: URL, start: Int64, endExclusive: Int64, queue: DispatchQueue,
         completion: @escaping (Data?) -> Void) {
        span = endExclusive - start
        self.completion = completion
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: origin)
        request.setValue("bytes=\(start)-\(endExclusive - 1)", forHTTPHeaderField: "Range")
        session.dataTask(with: request).resume()
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            completionHandler(.cancel)
            finish(nil)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if Int64(buffer.count) > span {   // origin sending more than asked
            dataTask.cancel()
            finish(nil)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil && !buffer.isEmpty ? buffer : nil)
    }

    private func finish(_ data: Data?) {
        guard !finished else { return }
        finished = true
        session.invalidateAndCancel()
        completion(data)
    }
}

/// One URLSession pulling the origin at full speed, one segment at a time,
/// writing straight through to the cache file. `jump(to:)` abandons the
/// current segment for the viewer's seek point; `MediaCacheServer` restarts
/// it on the gaps afterwards.
private final class SegmentDownloader: NSObject, URLSessionDataDelegate {
    private weak var server: MediaCacheServer?
    private let origin: URL
    private let q: DispatchQueue
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var writeOffset: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var segmentEnd: Int64?
    private var retries = 0
    private var cancelled = false

    /// No segment in hand — the pool may assign one.
    var isIdle: Bool { task == nil && !cancelled }

    /// The bytes this worker is still expected to deliver, so chunk
    /// assignment treats them as claimed rather than fetching them twice.
    var pendingSegment: (start: Int64, end: Int64)? {
        guard task != nil else { return nil }
        return (writeOffset, segmentEnd ?? writeOffset + 64 * 1_048_576)
    }

    /// Stand down until the pool has work again.
    func park() {
        task?.cancel()
        task = nil
    }

    /// Abandon the current segment WITHOUT retiring: a seek moved the pool, or
    /// the sliding window ran out of budget. Distinct from `cancel()`, which
    /// tears the worker down for good.
    func cancelSegment() {
        task?.cancel()
        task = nil
    }

    init(server: MediaCacheServer, origin: URL, queue: DispatchQueue) {
        self.server = server
        self.origin = origin
        self.q = queue
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30       // idle, not total
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    /// Begin (or re-begin) downloading from `offset` (on q).
    func start(at offset: Int64, endExclusive: Int64? = nil) {
        task?.cancel()
        segmentEnd = endExclusive
        requestedOffset = offset
        writeOffset = offset
        var request = URLRequest(url: origin)
        if let endExclusive {
            request.setValue("bytes=\(offset)-\(endExclusive - 1)", forHTTPHeaderField: "Range")
        } else if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        } else {
            // Ranged even at zero, so the very first response reveals whether
            // the origin can seek (206) or not (200).
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !cancelled, dataTask === task, let http = response as? HTTPURLResponse,
              let server else { completionHandler(.cancel); return }
        switch server.downloaderGotResponse(http, requestedOffset: requestedOffset) {
        case .allow:
            completionHandler(.allow)
        case .retryLater(let delay):
            completionHandler(.cancel)
            let offset = writeOffset
            let end = segmentEnd
            task = nil
            server.downloaderThrottled(self, resumeAt: offset, end: end, after: delay)
        case .restartAtZero:
            completionHandler(.cancel)
            start(at: 0)
        case .abandon:
            completionHandler(.cancel)
            task = nil
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled, dataTask === task, let server else { return }
        server.downloaderWrote(data, at: writeOffset)
        writeOffset += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled, task === self.task, let server else { return }
        if let error {
            let code = (error as NSError).code
            // A cancel is the pool repositioning or parking us, never a
            // failure — and `task` is already nil in that case.
            if code == NSURLErrorCancelled { return }
            retries += 1
            guard retries <= 3 else {
                self.task = nil
                server.downloaderFailed(self)
                return
            }
            let offset = writeOffset
            q.asyncAfter(deadline: .now() + Double(retries)) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.start(at: offset)
            }
            return
        }
        retries = 0
        self.task = nil
        server.downloaderFinishedSegment(self)
    }
}
