import SwiftUI

// Three-tab Preferences pane wired into the SwiftUI `Settings` scene.
// Cmd+, opens it; the popover footer also exposes a gear button.

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General",  systemImage: "gear") }
            HistoryPane()
                .tabItem { Label("History",  systemImage: "chart.bar") }
            AboutPane()
                .tabItem { Label("About",    systemImage: "info.circle") }
        }
        .frame(width: 460, height: 300)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch SwiftMeter at login",
                       isOn: Binding(
                            get: { settings.autoLaunch },
                            set: { newValue in
                                settings.autoLaunch = newValue
                                settings.applyAutoLaunch()
                            }))
                Text("Uses macOS's built-in login-items system. You can also manage this in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - History

private struct HistoryPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Retention") {
                Stepper(value: $settings.historyRetentionDays, in: 30...365, step: 30) {
                    Text("Keep detailed history for \(settings.historyRetentionDays) days")
                }
                Text("Older samples are compacted to hourly rollups so the database stays small. Daily and monthly totals are kept indefinitely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Soft monthly data cap") {
                HStack {
                    Text("Warn me when I cross")
                    TextField("0",
                              value: $settings.dataCapGB,
                              format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("GB / month")
                    Spacer()
                }
                Text(settings.dataCapGB > 0
                     ? "Notifications fire at 50 / 80 / 100 % of the cap. SwiftMeter cannot block traffic — this is warn-only."
                     : "Set a value above 0 to enable cap warnings. SwiftMeter cannot block traffic — this is warn-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About

private struct AboutPane: View {
    private static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("SwiftMeter")
                .font(.title2.bold())
            Text("Version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("github.com/gpsurya/SwiftMeter",
                 destination: URL(string: "https://github.com/gpsurya/SwiftMeter")!)
                .font(.callout)
            Spacer()
            Text("Made with care. MIT licensed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
