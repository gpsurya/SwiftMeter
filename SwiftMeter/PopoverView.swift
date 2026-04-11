import SwiftUI

// MARK: - Main Popover

struct PopoverContentView: View {
    @ObservedObject var monitor: NetworkMonitor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            backgroundGradient

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    headerSection
                    graphSection
                    connectionSection
                    ipSection
                    // Show WiFi section whenever we have WiFi data, not just when
                    // NWPathMonitor reports wifi — handles VPN-over-WiFi & startup lag
                    if monitor.connectionType == .wifi || monitor.wifiSSID != "--" {
                        wifiSection
                    }
                    networkConfigSection
                    statsSection
                    footerSection
                }
                .padding(12)
            }
        }
    }

    // MARK: Background

    @ViewBuilder
    private var backgroundGradient: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.netDown.opacity(scheme == .dark ? 0.08 : 0.05),
                    Color.netUp.opacity(scheme == .dark ? 0.06 : 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Speed Header

    private var headerSection: some View {
        GlassCard {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Spacer()
                    connectionBadge
                }

                HStack(spacing: 20) {
                    speedColumn(
                        label: "DOWNLOAD",
                        speed: monitor.downloadSpeed,
                        string: monitor.downloadSpeedString,
                        color: .netDown,
                        symbol: "arrow.down.circle.fill"
                    )

                    Divider()
                        .frame(height: 44)
                        .opacity(0.3)

                    speedColumn(
                        label: "UPLOAD",
                        speed: monitor.uploadSpeed,
                        string: monitor.uploadSpeedString,
                        color: .netUp,
                        symbol: "arrow.up.circle.fill"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func speedColumn(label: String, speed: Double, string: String,
                              color: Color, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, value: speed > 0)

            Text(string)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.3), value: string)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color.opacity(0.8))
                .kerning(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(monitor.isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
                .shadow(color: monitor.isConnected ? .green.opacity(0.6) : .red.opacity(0.6),
                        radius: 3)

            Text(monitor.connectionType.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Image(systemName: monitor.connectionType.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Speed Graph

    private var graphSection: some View {
        GlassCard {
            VStack(spacing: 8) {
                SpeedRowView(
                    label: "DL",
                    currentSpeed: monitor.downloadSpeedString,
                    color: Color.netDown,
                    data: monitor.speedHistory.map(\.download)
                )
                Divider().opacity(0.25)
                SpeedRowView(
                    label: "UL",
                    currentSpeed: monitor.uploadSpeedString,
                    color: Color.netUp,
                    data: monitor.speedHistory.map(\.upload)
                )
            }
        }
    }

    // MARK: - Connection Info

    private var connectionSection: some View {
        GlassCard {
            VStack(spacing: 0) {
                SectionHeader(title: "CONNECTION", symbol: "network")
                Spacer().frame(height: 8)
                VStack(spacing: 6) {
                    InfoRow(label: "Interface", value: monitor.activeInterface)
                    InfoRow(label: "Type",      value: monitor.connectionType.rawValue)
                    HStack {
                        Text("Latency")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(monitor.latencyString)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(latencyColor)
                    }
                }
            }
        }
    }

    private var latencyColor: Color {
        let ms = monitor.latencyMs
        if ms < 0   { return .secondary }
        if ms < 50  { return .green }
        if ms < 100 { return Color(red: 0.9, green: 0.7, blue: 0) }
        if ms < 200 { return .orange }
        return .red
    }

    // MARK: - IP Addresses

    private var ipSection: some View {
        GlassCard {
            VStack(spacing: 0) {
                SectionHeader(title: "IP ADDRESSES", symbol: "number.circle")
                Spacer().frame(height: 8)
                VStack(spacing: 6) {
                    InfoRow(label: "IPv4 (Local)",  value: monitor.ipv4Address)
                    InfoRow(label: "IPv6 (Local)",  value: monitor.ipv6Address, monospace: true, small: true)
                    HStack {
                        InfoRow(label: "Public WAN", value: monitor.publicIP)
                        Spacer()
                        Button {
                            Task { await monitor.fetchPublicIP() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh public IP")
                    }
                    if monitor.ispName != "--" {
                        InfoRow(label: "ISP", value: monitor.ispName)
                    }
                    let locationParts = [monitor.ipCity, monitor.ipRegion, monitor.ipCountry]
                        .filter { $0 != "--" && !$0.isEmpty }
                    if !locationParts.isEmpty {
                        InfoRow(label: "Location", value: locationParts.joined(separator: ", "))
                    }
                }
            }
        }
    }

    // MARK: - WiFi Section

    private var wifiSection: some View {
        GlassCard {
            VStack(spacing: 0) {
                SectionHeader(title: "WI-FI", symbol: "wifi")
                Spacer().frame(height: 8)
                VStack(spacing: 6) {
                    HStack {
                        Text("Network")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(monitor.wifiSSID)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                    }

                    HStack {
                        Text("Signal")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 5) {
                            SignalBarsView(percent: monitor.wifiSignalPercent, color: .netDown)
                            Text("\(monitor.wifiSignalPercent)%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text("(\(monitor.wifiRSSI) dBm)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    InfoRow(label: "Channel", value: monitor.wifiChannel)
                    InfoRow(label: "Band",    value: monitor.wifiBand)

                    if monitor.wifiTxRate > 0 {
                        InfoRow(label: "TX Rate",
                                value: String(format: "%.0f Mbps", monitor.wifiTxRate))
                    }
                }
            }
        }
    }

    // MARK: - Network Config

    private var networkConfigSection: some View {
        GlassCard {
            VStack(spacing: 0) {
                SectionHeader(title: "NETWORK CONFIG", symbol: "gearshape.2")
                Spacer().frame(height: 8)
                VStack(spacing: 6) {
                    InfoRow(label: "Gateway",     value: monitor.gateway)
                    InfoRow(label: "Subnet Mask", value: monitor.subnetMask)

                    if monitor.dnsServers.isEmpty {
                        InfoRow(label: "DNS", value: "--")
                    } else {
                        ForEach(Array(monitor.dnsServers.enumerated()), id: \.offset) { i, dns in
                            InfoRow(label: i == 0 ? "DNS \(i+1)" : "     \(i+1)",
                                    value: dns, monospace: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Session Stats

    private var sessionAge: String {
        let interval = Date().timeIntervalSince(monitor.sessionStartDate)
        let totalSeconds = Int(interval)
        let hours   = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "just now"
        }
    }

    private var statsSection: some View {
        GlassCard {
            VStack(spacing: 0) {
                HStack {
                    SectionHeader(title: "SESSION STATS", symbol: "chart.bar.fill")
                    Spacer()
                    Button {
                        monitor.resetSession()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset session counters")
                }

                Text("Since \(sessionAge)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer().frame(height: 8)

                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        statPill(
                            label: "Downloaded",
                            value: monitor.formatBytes(monitor.sessionDownload),
                            color: .netDown
                        )
                        statPill(
                            label: "Uploaded",
                            value: monitor.formatBytes(monitor.sessionUpload),
                            color: .netUp
                        )
                    }

                    Divider().opacity(0.3)

                    HStack(spacing: 12) {
                        InfoRow(label: "Packets In",  value: formatCount(monitor.packetsIn))
                        Spacer()
                        InfoRow(label: "Packets Out", value: formatCount(monitor.packetsOut))
                    }

                    if monitor.networkErrors > 0 {
                        InfoRow(label: "Errors",
                                value: formatCount(monitor.networkErrors),
                                valueColor: .orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("SwiftMeter v1.0.1")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    // MARK: Helpers

    private func formatCount(_ n: UInt32) -> String {
        n >= 1_000_000
            ? String(format: "%.1fM", Double(n) / 1_000_000)
            : n >= 1_000
                ? String(format: "%.1fK", Double(n) / 1_000)
                : "\(n)"
    }
}

// MARK: - Reusable Components

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                    .shadow(
                        color: .black.opacity(scheme == .dark ? 0.3 : 0.08),
                        radius: 4, y: 2
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        scheme == .dark
                            ? Color.white.opacity(0.08)
                            : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
            }
    }
}

struct SectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.8)
            Spacer()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospace: Bool = false
    var small: Bool = false
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(
                    monospace
                        ? .system(size: small ? 9 : 11, design: .monospaced)
                        : .system(size: 11, weight: .medium)
                )
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
