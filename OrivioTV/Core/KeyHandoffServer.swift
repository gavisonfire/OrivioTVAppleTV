import Foundation
import Network

/// A one-field page this Apple TV serves on the local network so an API key can
/// be pasted from a phone instead of typed with the remote.
///
/// TMDB has no device/QR login: every v3 endpoint is authenticated by an API
/// key, and the flow that would hand one out needs a key to start. So the QR
/// can't come from TMDB — it points at this TV instead. Scan it, the phone
/// opens a form, the key arrives here, and the TV saves it. The phone is where
/// the key already is (it's on themoviedb.org in a browser tab), which is the
/// whole point.
///
/// Same shape and same limits as `AddonImportServer`, which does this for
/// manifest URLs:
///
/// * Bound to the LAN, and only while the screen showing the QR is open —
///   `stop()` on disappear. Not a background service.
/// * One route, one field. It accepts a string and hands it to `onSubmit`;
///   there is no shell, no filesystem, no proxying.
/// * http, not https. A self-signed cert on a LAN address trains people to
///   click through security warnings. That means the key crosses the local
///   network in the clear, which is why the page says so and why the screen
///   still offers on-TV entry for anyone who'd rather not.
@MainActor
final class KeyHandoffServer: ObservableObject {
    /// What the QR encodes, e.g. "http://192.168.1.20:8098". nil until the
    /// listener is actually up.
    @Published private(set) var address: String?
    @Published private(set) var lastError: String?
    /// Set once a submitted value was accepted, so the TV can say so.
    @Published private(set) var accepted = false

    /// What the page is asking for. Rendered on the phone.
    let title: String
    let blurb: String
    let placeholder: String

    /// Validates and stores a submitted value. Returns the message to show on
    /// the phone, and whether it was accepted.
    var onSubmit: ((String) async -> (accepted: Bool, message: String))?

    init(title: String, blurb: String, placeholder: String) {
        self.title = title
        self.blurb = blurb
        self.placeholder = placeholder
    }

    /// One above `AddonImportServer`'s, so both screens can be open at once
    /// without fighting over the port.
    private static let port: UInt16 = 8098

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.address = Self.lanAddress().map { "http://\($0):\(Self.port)" }
                        if self?.address == nil {
                            self?.lastError = "This Apple TV isn't on a network."
                        }
                    case .failed(let error):
                        self?.lastError = error.localizedDescription
                        self?.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        address = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Read until the headers are complete AND the declared body has arrived —
    /// a form POST routinely splits across packets.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            Task { @MainActor in
                if error != nil { self.drop(connection); return }
                guard let request = HTTPRequest(buffer), request.isComplete else {
                    // Cap it: a connection that never completes its request
                    // would otherwise grow this buffer without bound.
                    if isComplete || buffer.count > 64 * 1024 { self.drop(connection) }
                    else { self.receive(connection, buffer: buffer) }
                    return
                }
                await self.respond(to: request, on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        var message: String?
        var ok = false
        if request.method == "POST" {
            let value = Self.formValue("value", in: request.body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                message = "Nothing entered."
            } else if let onSubmit {
                let result = await onSubmit(value)
                ok = result.accepted
                message = result.message
                if ok { accepted = true }
            }
        }
        send(Self.page(server: self, message: message, accepted: ok), on: connection)
    }

    private func send(_ html: String, on connection: NWConnection) {
        let data = Data(html.utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(data.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + data,
                        completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.drop(connection) }
        })
    }

    // MARK: - Parsing

    private struct HTTPRequest {
        let method: String
        let body: String
        let isComplete: Bool

        init?(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8),
                  let headerEnd = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n"),
                  let requestLine = text.split(whereSeparator: \.isNewline).first
            else { return nil }
            method = requestLine.split(separator: " ").first.map(String.init) ?? "GET"
            body = String(text[headerEnd.upperBound...])
            let declared = text.range(of: #"(?i)content-length:\s*(\d+)"#, options: .regularExpression)
                .flatMap { Int(text[$0].filter(\.isNumber)) } ?? 0
            isComplete = method != "POST" || body.utf8.count >= declared
        }
    }

    private static func formValue(_ name: String, in body: String) -> String {
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == name else { continue }
            return parts[1]
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? String(parts[1])
        }
        return ""
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(server: KeyHandoffServer, message: String?, accepted: Bool) -> String {
        let note = message.map {
            "<p class=\"note \(accepted ? "ok" : "bad")\">\(escape($0))</p>"
        } ?? ""
        // The field is not `type=password`: the point of pasting from the phone
        // is being able to SEE that the right thing landed in the box.
        return """
        <!doctype html><html><head><meta charset=utf-8>
        <meta name=viewport content="width=device-width,initial-scale=1">
        <title>\(escape(server.title))</title><style>
        :root{color-scheme:dark}
        body{margin:0;padding:24px;background:#0d0f14;color:#f2f2f7;
             font:16px/1.5 -apple-system,system-ui,sans-serif}
        h1{font-size:22px;margin:0 0 4px} p{color:#9a9aa6;margin:0 0 20px}
        a{color:#a78bfa}
        input{width:100%;box-sizing:border-box;padding:14px;font-size:16px;
              border-radius:12px;border:1px solid #2c2f3a;background:#161923;color:#fff;
              font-family:ui-monospace,Menlo,monospace}
        button{margin-top:12px;width:100%;padding:14px;font-size:17px;font-weight:600;
               border:0;border-radius:12px;background:#7c3aed;color:#fff}
        .note{margin:16px 0 0} .ok{color:#4ade80} .bad{color:#f87171}
        .fine{margin-top:24px;font-size:13px;color:#6b6b78}
        </style></head><body>
        <h1>\(escape(server.title))</h1>
        <p>\(server.blurb)</p>
        <form method=post action="/">
        <input name=value autocapitalize=off autocorrect=off spellcheck=false
               placeholder="\(escape(server.placeholder))" autofocus>
        <button type=submit>Send to the TV</button>
        </form>\(note)
        <p class=fine>This page is served by your Apple TV on your own network,
        over plain http. Only use it on a network you trust.</p>
        </body></html>
        """
    }

    /// This device's IPv4 address on the LAN. Walks the interface list rather
    /// than assuming a name — the Apple TV is "en0" over Ethernet and Wi-Fi
    /// both, but not on every model, and picking wrong yields a dead QR.
    private static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var best: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            let ip = String(cString: host)
            if name.hasPrefix("en") { return ip }   // wired or Wi-Fi, preferred
            if best == nil { best = ip }
        }
        return best
    }
}
