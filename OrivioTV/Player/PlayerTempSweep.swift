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

    /// The sweep itself. Synchronous — call it directly only from a background
    /// context (or a test).
    static func sweep() {
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
            // Whatever the request is, the answer is the same — so don't wait
            // for a complete one, just read once and reply.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                Task { @MainActor in Self.send(on: connection) }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        #endif
    }

    private static func send(on connection: NWConnection) {
        var trail = UserDefaults.standard.stringArray(forKey: "dev.colorTrail") ?? []
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
