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
    private var downloader: SegmentDownloader?

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
    /// High-water mark of served bytes — the playhead estimate when no reader
    /// happens to be connected at the moment eviction looks.
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

    private func publishSnapshot() {
        snapshotLock.lock()
        snapshotRanges = ranges
        snapshotTotal = totalLength
        snapshotFailure = failureReason
        snapshotWindow = windowed
            ? "window budget=\(budget) paused=\(pausedForSpace) evicted=\(evictedTotal)\(evictionBroken ? " EVICTION BROKEN" : "")"
            : nil
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
            teardownSessionLocked()
            guard startListenerLocked() else { return nil }
            self.origin = origin
            token = UUID().uuidString
            redirectAll = false
            rangeCapable = true
            totalLength = -1
            ranges = []
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
            let downloader = SegmentDownloader(server: self, origin: origin, queue: q)
            self.downloader = downloader
            downloader.start(at: 0)
            // Keep the origin's extension: the engine router picks
            // native-vs-FFmpeg by it, and losing ".mkv" would send Matroska
            // to AVPlayer.
            let name = ext.isEmpty ? "v" : "v.\(ext)"
            return URL(string: "http://127.0.0.1:\(Self.port)/m/\(token)/\(name)")
        }
    }

    /// Stop downloading, drop every connection, delete the cache file.
    func endSession() {
        q.sync { teardownSessionLocked() }
    }

    // MARK: - Session teardown (on q)

    private func teardownSessionLocked() {
        downloader?.cancel()
        downloader = nil
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
        publishSnapshot()
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

        // Cache-only lane: what's on disk or a fast refusal — no jump, no
        // redirect, no waiting on the network.
        if cacheOnly {
            if coverageEnd(from: start) == start, start < total, method != "HEAD" {
                sendSimple(connection, "416 Range Not Satisfiable")
                return
            }
        }
        // Route an uncovered request. (The old check here — `start >
        // coverageEnd(from: start)` — could never be true, so deep seeks
        // stalled against the sequential download instead of repositioning it.)
        else if rangeCapable, coverageEnd(from: start) == start, start < total {
            let frontier = ranges.last?.end ?? 0
            if start > frontier + Self.jumpAheadSlopBytes {
                // Deep forward seek: reposition the download to serve the
                // viewer's new position now rather than eventually.
                pausedForSpace = false
                downloader?.jump(to: start)
            } else if windowed, start < frontier {
                // Behind the sliding window (evicted, or a gap the window
                // will never refill) — this reader gets the origin directly.
                sendRedirect(connection)
                return
            }
        }

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
        // Preview readers are not the viewer: they must not steer eviction.
        if !cacheOnly { readOffsets[ObjectIdentifier(connection)] = start }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.q.async {
                if error != nil || method == "HEAD" { self.finish(connection); return }
                guard let fileURL = self.fileURL,
                      let reader = try? FileHandle(forReadingFrom: fileURL) else {
                    self.drop(connection); return
                }
                self.serve(connection, reader: reader, offset: start,
                           endExclusive: endExclusive, stalledSince: nil, cacheOnly: cacheOnly)
            }
        })
    }

    /// Pump bytes from the cache file to the player as they become available.
    /// Backpressure is the send-completion; availability gaps poll at 80ms —
    /// crude, but local, cheap, and immune to lost-wakeup bugs.
    private func serve(_ connection: NWConnection, reader: FileHandle,
                       offset: Int64, endExclusive: Int64, stalledSince: Date?,
                       cacheOnly: Bool = false) {
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
                try? reader.close()
                drop(connection)
                return
            }
            q.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.serve(connection, reader: reader, offset: offset,
                            endExclusive: endExclusive, stalledSince: stalledSince ?? Date())
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
                if !cacheOnly {
                    self.readOffsets[ObjectIdentifier(connection)] = next
                    self.lastReadOffset = max(self.lastReadOffset, next)
                    self.resumeIfRoom()
                }
                self.serve(connection, reader: reader, offset: next,
                           endExclusive: endExclusive, stalledSince: nil, cacheOnly: cacheOnly)
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

    /// The first missing byte range, for the fill-the-gaps pass. In windowed
    /// mode, gaps behind the slowest reader are the EVICTED past — refilling
    /// them would fight the eviction forever, so only gaps from the reader
    /// forward qualify.
    private func firstGap() -> (start: Int64, end: Int64)? {
        guard totalLength > 0 else { return nil }
        var cursor: Int64 = windowed ? minActiveRead() : 0
        for range in ranges {
            if range.start > cursor { return (cursor, range.start) }
            cursor = max(cursor, range.end)
        }
        return cursor < totalLength ? (cursor, totalLength) : nil
    }

    // MARK: - Downloader callbacks (on q)

    fileprivate func downloaderGotResponse(_ response: HTTPURLResponse, requestedOffset: Int64) -> Bool {
        switch response.statusCode {
        case 206:
            // "bytes X-Y/TOTAL"
            if totalLength <= 0,
               let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
               let totalPart = contentRange.split(separator: "/").last,
               let total = Int64(totalPart) {
                totalLength = total
                publishSnapshot()
                return configureBudget()
            }
            return true
        case 200:
            if requestedOffset > 0 {
                // Origin ignored the Range header — it can't seek. What's
                // cached so far still serves; jumps are off the table.
                rangeCapable = false
                return false
            }
            rangeCapable = false
            totalLength = response.expectedContentLength
            guard totalLength > 0 else {
                failSession("origin sent no content length")
                return false
            }
            publishSnapshot()
            return configureBudget()
        default:
            failSession("origin answered \(response.statusCode)")
            return false
        }
    }

    fileprivate func downloaderWrote(_ data: Data, at offset: Int64) {
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

    fileprivate func downloaderFinishedSegment() {
        // Tail done (or segment complete) → fill the earliest gap next; no
        // gaps means the whole file is on disk and the downloader retires.
        guard let gap = firstGap() else {
            NSLog("[OrivioCache] %@ (%lld bytes)",
                  windowed ? "window reaches the end of the file — download retired" : "file fully cached",
                  totalLength)
            downloader = nil
            return
        }
        downloader?.start(at: gap.start, endExclusive: rangeCapable ? gap.end : nil)
    }

    fileprivate func downloaderFailed() {
        failSession("download failed")
    }

    private func failSession(_ reason: String) {
        // Fail OPEN, but never silently: the reason reaches the colour trail
        // (readable live over the dev probe endpoint) and the snapshot, so
        // the UI knows the cache is gone and the band can fall back honestly.
        NSLog("[OrivioCache] session failed: %@ — redirecting to origin", reason)
        PlayerViewModel.colorTrail("cache session failed: \(reason) — direct playback from origin")
        failureReason = reason
        redirectAll = true
        downloader?.cancel()
        downloader = nil
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
        downloader?.pause()
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
        downloader?.resume()
        publishSnapshot()
        NSLog("[OrivioCache] window slid — download resumed")
    }
}

// MARK: - Segment downloader

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

    /// Abandon the current segment for a seek target (on q).
    func jump(to offset: Int64) {
        guard !cancelled else { return }
        start(at: offset)
    }

    /// Space pause: drop the network request but keep our place. `task` is
    /// nilled so any chunks URLSession already buffered are discarded by the
    /// delegate guards; `resume()` re-requests from exactly where writing
    /// stopped, bounded to the same segment.
    func pause() {
        guard !cancelled else { return }
        task?.cancel()
        task = nil
    }

    func resume() {
        guard !cancelled, task == nil else { return }
        start(at: writeOffset, endExclusive: segmentEnd)
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
        if server.downloaderGotResponse(http, requestedOffset: requestedOffset) {
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
            // A 200-to-a-ranged-request origin restarts from zero once.
            if requestedOffset > 0 { start(at: 0) }
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
            if code == NSURLErrorCancelled { return }   // a jump superseded this segment
            retries += 1
            guard retries <= 3 else { server.downloaderFailed(); return }
            let offset = writeOffset
            q.asyncAfter(deadline: .now() + Double(retries)) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.start(at: offset)
            }
            return
        }
        retries = 0
        server.downloaderFinishedSegment()
    }
}
