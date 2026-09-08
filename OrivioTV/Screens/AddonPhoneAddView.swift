import SwiftUI

/// Settings → Add-ons → Add Add-ons: a QR pointing at a small page this Apple
/// TV serves on the local network, so manifest URLs can be pasted from a phone
/// instead of typed on the remote.
///
/// The server runs ONLY while this screen is up (see `onAppear`/`onDisappear`)
/// — it is a tool the viewer opened, not a service left listening.
struct AddonPhoneAddView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var addonManager: AddonManager
    @StateObject private var server = AddonImportServer()
    let onDone: () -> Void

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: OrivioSpacing.lg) {
                Text("Add Add-ons")
                    .font(FusionType.pageTitle(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)

                if let address = server.address {
                    Text("Scan with your phone, or open \(address) in its browser. Both devices have to be on the same network.")
                        .font(FusionType.bodyText(theme.font))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                    QRCodeView(string: address, side: 360)
                    Text(address)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.palette.secondary)
                } else if let error = server.lastError {
                    Text(error)
                        .font(FusionType.bodyText(theme.font))
                        .foregroundStyle(OrivioPrimitives.red300)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    OrivioLoadingView(label: "Starting")
                        .frame(height: 360)
                }

                if !server.accepted.isEmpty {
                    // Echo what the phone sent so it is obvious it worked
                    // without walking back to the TV to check the list.
                    VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
                        ForEach(server.accepted.prefix(3)) { addon in
                            HStack(spacing: OrivioSpacing.sm) {
                                // Manifest logos are frequently missing; the
                                // placeholder keeps the rows aligned instead of
                                // letting the names jump left.
                                RemoteImage(url: addon.logo, contentMode: .fit, maxDimension: 44)
                                    .frame(width: 44, height: 44)
                                    .background(Color.white.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 8))
                                Text(addon.name)
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(theme.palette.textPrimary)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(OrivioPrimitives.success)
                            }
                        }
                    }
                }

                Button("Done", action: onDone)
                    .padding(.top, OrivioSpacing.sm)
            }
            .padding(OrivioSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            server.onInstall = { url in
                do {
                    try await addonManager.install(manifestURL: url)
                    // Report what actually installed — the manifest's own name,
                    // logo and description — rather than echoing the link back.
                    // A URL tells you nothing about what you just added.
                    guard let installed = addonManager.addons.first(where: { $0.manifestURL == url })
                    else {
                        return .success(.init(manifestURL: url, name: url,
                                              logo: nil, description: nil))
                    }
                    return .success(.init(manifestURL: url,
                                          name: installed.manifest.name,
                                          logo: installed.manifest.logo,
                                          description: installed.manifest.description))
                } catch {
                    return .failure(error)
                }
            }
            server.start()
        }
        .onDisappear { server.stop() }
        .onExitCommand(perform: onDone)
    }
}

/// Settings → Content & Discovery → Live TV: the same phone-paste server,
/// pointed at the custom IPTV playlist instead of the add-on list — playlist
/// URLs are even longer than manifest URLs, and typing one on the remote was
/// the only way in.
struct IPTVPhoneAddView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var liveTV = LiveTVSettingsStore.shared
    @StateObject private var server = AddonImportServer()
    let onDone: () -> Void

    private struct PlaylistImportError: LocalizedError {
        var errorDescription: String? {
            "no channels found at that URL — check it points to an M3U/M3U8 playlist"
        }
    }

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: OrivioSpacing.lg) {
                Text("Add IPTV Playlist")
                    .font(FusionType.pageTitle(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)

                if let address = server.address {
                    Text("Scan with your phone, or open \(address) in its browser, and paste your playlist URL there. Both devices have to be on the same network.")
                        .font(FusionType.bodyText(theme.font))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                    QRCodeView(string: address, side: 360)
                    Text(address)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.palette.secondary)
                } else if let error = server.lastError {
                    Text(error)
                        .font(FusionType.bodyText(theme.font))
                        .foregroundStyle(OrivioPrimitives.red300)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    OrivioLoadingView(label: "Starting")
                        .frame(height: 360)
                }

                if let accepted = server.accepted.first {
                    HStack(spacing: OrivioSpacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(OrivioPrimitives.success)
                        Text(accepted.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                    }
                }

                Button("Done", action: onDone)
                    .padding(.top, OrivioSpacing.sm)
            }
            .padding(OrivioSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            server.pageTitle = "Add IPTV playlist"
            server.pagePrompt = "Paste your M3U/M3U8 playlist URL. It replaces the built-in channel list in Live TV on the Apple TV."
            server.pagePlaceholder = "https://…/playlist.m3u"
            server.pageButton = "Use this playlist"
            server.pageEmptyMessage = "Enter a playlist URL."
            server.onInstall = { url in
                var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.contains("://") { normalized = "https://" + normalized }
                // Same validation as the on-TV field: actually fetch and
                // parse — storing a dud would just blank the Live TV tab.
                let channels = await M3UService.channels(from: normalized)
                guard !channels.isEmpty else { return .failure(PlaylistImportError()) }
                LiveTVSettingsStore.shared.customPlaylistURL = normalized
                return .success(.init(manifestURL: normalized,
                                      name: "Playlist active — \(channels.count) channels",
                                      logo: nil, description: normalized))
            }
            server.start()
        }
        .onDisappear { server.stop() }
        .onExitCommand(perform: onDone)
    }
}
