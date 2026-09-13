import SwiftUI

/// Settings → Integrations → Plex / Jellyfin: connection status, sign-in and
/// disconnect for each media server.
struct MediaServerSection: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mediaServers: MediaServerStore
    let kind: MediaServerKind
    @State private var connecting = false

    private var account: MediaServerAccount? { mediaServers.account(for: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            Button { connecting = true } label: {
                HStack(spacing: OrivioSpacing.lg) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account == nil ? "Connect \(kind.displayName)" : (account?.serverName ?? kind.displayName))
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text(statusLine)
                            .font(.system(size: 19))
                            .foregroundStyle(account != nil ? OrivioPrimitives.success : theme.palette.textSecondary)
                    }
                    Spacer()
                    Image(systemName: account != nil ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(account != nil ? OrivioPrimitives.success : theme.palette.textTertiary)
                }
                .integrationRowBackground(theme)
            }
            .buttonStyle(PlainCardButtonStyle())

            if account != nil {
                Button(role: .destructive) {
                    mediaServers.set(nil, for: kind)
                } label: {
                    SettingsActionRow(title: "Disconnect", subtitle: "Forget this server and its sign-in",
                                      leadingIcon: "xmark.circle")
                }
                .buttonStyle(PlainCardButtonStyle())
            }

            Text(blurb)
                .font(.system(size: 17))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .fullScreenCover(isPresented: $connecting) {
            Group {
                switch kind {
                case .plex: PlexConnectPage { connecting = false }
                case .jellyfin: JellyfinConnectPage { connecting = false }
                }
            }
            .environmentObject(theme)
            .environmentObject(mediaServers)
        }
    }

    private var statusLine: String {
        guard let account else {
            return kind == .plex ? "Sign in with a code at plex.tv/link" : "Server address, username and password"
        }
        var parts = ["Connected"]
        if let user = account.username, !user.isEmpty { parts.append(user) }
        parts.append(account.serverURL.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: ""))
        return parts.joined(separator: " · ")
    }

    private var blurb: String {
        switch kind {
        case .plex:
            return "Your Plex Media Server's movies and shows appear as a Plex tab in Library and play straight from the server."
        case .jellyfin:
            return "Your Jellyfin server's movies and shows appear as a Jellyfin tab in Library and play straight from the server."
        }
    }
}

// MARK: - Plex (plex.tv/link code)

/// Plex's TV sign-in: a four-character code the viewer enters at plex.tv/link
/// on a phone or computer, polled until the account links, then the account's
/// servers are looked up and the reachable one saved.
private struct PlexConnectPage: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mediaServers: MediaServerStore
    let onDone: () -> Void

    private enum Phase { case starting, code(PlexService.Pin), servers([PlexService.ServerCandidate], token: String), connecting, failed(String) }
    @State private var phase: Phase = .starting
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: OrivioSpacing.xl) {
                Text("Connect Plex")
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)

                switch phase {
                case .starting:
                    ProgressView().tint(theme.palette.secondary)
                    Text("Getting a sign-in code…")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.palette.textSecondary)
                    FocusAnchor()
                case .code(let pin):
                    Text("On your phone or computer, go to plex.tv/link and enter this code.")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                    QRCodeView(string: PlexService.Pin.linkURL, side: 300)
                    Text(pin.code)
                        .font(.system(size: 72, weight: .heavy, design: .monospaced))
                        .tracking(12)
                        .foregroundStyle(theme.palette.secondary)
                    HStack(spacing: OrivioSpacing.sm) {
                        ProgressView().tint(theme.palette.secondary)
                        Text("Waiting for the code to be entered…")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                    FocusAnchor()
                case .servers(let servers, let token):
                    Text("Which server?")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                    VStack(spacing: OrivioSpacing.sm) {
                        ForEach(servers) { server in
                            Button { Task { await connect(server, token: token) } } label: {
                                SettingsActionRow(title: server.name,
                                                  subtitle: "\(server.connections.count) address\(server.connections.count == 1 ? "" : "es")",
                                                  leadingIcon: "server.rack")
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .frame(maxWidth: 900)
                case .connecting:
                    ProgressView().tint(theme.palette.secondary)
                    Text("Finding your server…")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.palette.textSecondary)
                    FocusAnchor()
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 24))
                        .foregroundStyle(OrivioPrimitives.error)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                    Button("Try Again") { Task { await begin() } }
                        .font(.system(size: 24, weight: .semibold))
                }

                Text("Press Menu to cancel")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(OrivioSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await begin() }
        .onDisappear { pollTask?.cancel() }
        .onExitCommand { pollTask?.cancel(); onDone() }
    }

    private func begin(renewal: Bool = false) async {
        // A renewal runs INSIDE pollTask itself — cancelling here would cancel
        // the very task doing the renewing, and the next URLSession call then
        // throws CancellationError: the viewer who let a code expire got the
        // failure screen instead of a fresh code. (Same trap, same fix, as the
        // debrid connect page.)
        if !renewal { pollTask?.cancel() }
        phase = .starting
        guard let pin = await PlexService.requestPin() else {
            phase = .failed("Couldn't get a sign-in code from plex.tv. Check the connection and try again.")
            return
        }
        phase = .code(pin)
        startPolling(pin)
    }

    private func startPolling(_ pin: PlexService.Pin) {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                if Date() >= pin.expiresAt {
                    await begin(renewal: true)   // a fresh code
                    return
                }
                if let token = await PlexService.pollPin(pin) {
                    await linked(token: token)
                    return
                }
            }
        }
    }

    private func linked(token: String) async {
        phase = .connecting
        let servers = await PlexService.servers(token: token)
        guard !servers.isEmpty else {
            phase = .failed("Signed in, but this Plex account has no servers.")
            return
        }
        if servers.count == 1 {
            await connect(servers[0], token: token)
        } else {
            phase = .servers(servers, token: token)
        }
    }

    private func connect(_ server: PlexService.ServerCandidate, token: String) async {
        phase = .connecting
        let serverToken = server.accessToken ?? token
        guard let url = await PlexService.reachableURL(server, token: serverToken) else {
            phase = .failed("\(server.name) didn't answer on any of its addresses. Make sure it's on and reachable from this Apple TV.")
            return
        }
        mediaServers.set(MediaServerAccount(kind: .plex, serverURL: url, token: serverToken,
                                            serverName: server.name), for: .plex)
        onDone()
    }
}

// MARK: - Jellyfin (address + sign-in)

private struct JellyfinConnectPage: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mediaServers: MediaServerStore
    let onDone: () -> Void

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var status: String?

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: OrivioSpacing.xl) {
                Text("Connect Jellyfin")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("The server's address as you'd open it in a browser, then your Jellyfin user.")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)

                VStack(spacing: OrivioSpacing.md) {
                    TextField("http://192.168.1.10:8096", text: $server)
                        .textContentType(.URL)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                .font(.system(size: 24))
                .frame(maxWidth: 760)

                if let status {
                    Text(status)
                        .font(.system(size: 20))
                        .foregroundStyle(status == "Connected." ? OrivioPrimitives.success : OrivioPrimitives.error)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }

                HStack(spacing: OrivioSpacing.lg) {
                    Button(action: connect) {
                        if working { ProgressView().tint(theme.palette.onSecondary) }
                        else { Text("Connect") }
                    }
                    Button("Cancel", role: .cancel, action: onDone)
                }
                .font(.system(size: 24, weight: .semibold))
            }
            .padding(OrivioSpacing.huge)
        }
        .onAppear {
            if let existing = mediaServers.jellyfin {
                server = existing.serverURL
                username = existing.username ?? ""
            }
        }
        .onExitCommand { onDone() }
    }

    private func connect() {
        guard !working else { return }
        guard let url = JellyfinService.normalizedServerURL(server) else {
            status = "Enter the server's address first."
            return
        }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = "Enter your Jellyfin username."
            return
        }
        working = true
        status = nil
        Task {
            let result = await JellyfinService.authenticate(
                serverURL: url, username: username.trimmingCharacters(in: .whitespaces), password: password
            )
            working = false
            status = result.message
            if let account = result.account {
                mediaServers.set(account, for: .jellyfin)
                onDone()
            }
        }
    }
}
