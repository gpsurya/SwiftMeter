import SwiftUI
import Charts

// History card slotted into the popover above SESSION STATS. Shows a
// window picker (Today / 7d / 30d / Lifetime), the totals for that
// window, a chart (per-hour for today, per-day otherwise), and the top
// networks/interfaces by usage.

struct HistoryView: View {

    @ObservedObject var monitor: NetworkMonitor

    @State private var window: HistoryWindow = .today
    @State private var totals    = HistoryTotals(dl: 0, ul: 0)
    @State private var hourly:   [HourlyTotal] = []
    @State private var daily:    [DailyTotal]  = []
    @State private var ssidPivot: [PivotEntry] = []
    @State private var ifacePivot: [PivotEntry] = []

    /// Re-fetch on this trigger so we don't ask SQLite every SwiftUI
    /// render. Bumped on `.onAppear` and on a 30 s timer while the
    /// popover is open.
    @State private var refreshTick = 0

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        GlassCard {
            VStack(spacing: 8) {
                HStack {
                    SectionHeader(title: "HISTORY", symbol: "chart.bar.xaxis")
                    Spacer()
                    Picker("", selection: $window) {
                        ForEach(HistoryWindow.allCases) { w in
                            Text(w.label).tag(w)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }

                totalsRow

                chartArea
                    .frame(height: 64)

                if !ssidPivot.isEmpty || !ifacePivot.isEmpty {
                    Divider().opacity(0.25)
                    topNetworksRow
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: window) { _ in reload() }
        .onReceive(refreshTimer) { _ in reload() }
    }

    // MARK: - Totals row

    private var totalsRow: some View {
        HStack(spacing: 16) {
            totalChip(symbol: "arrow.down",
                      color: .netDown,
                      value: monitor.formatBytes(UInt64(max(0, totals.dl))))
            totalChip(symbol: "arrow.up",
                      color: .netUp,
                      value: monitor.formatBytes(UInt64(max(0, totals.ul))))
            Spacer()
            Text(monitor.formatBytes(UInt64(max(0, totals.total))))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label). Downloaded \(monitor.formatBytes(UInt64(max(0, totals.dl)))), uploaded \(monitor.formatBytes(UInt64(max(0, totals.ul)))). Total \(monitor.formatBytes(UInt64(max(0, totals.total)))).")
    }

    @ViewBuilder
    private func totalChip(symbol: String, color: Color, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartArea: some View {
        if window == .today {
            hourlyChart
        } else {
            dailyChart
        }
    }

    private var hourlyChart: some View {
        Chart(hourly) { bin in
            BarMark(
                x: .value("Hour", bin.hour),
                y: .value("Bytes", bin.dl + bin.ul)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.netDown.opacity(0.85), Color.netUp.opacity(0.85)],
                    startPoint: .bottom, endPoint: .top
                )
            )
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                if let h = value.as(Int.self) {
                    AxisValueLabel { Text("\(h)") }
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .chartYAxis(.hidden)
        .accessibilityLabel("Hourly usage today")
    }

    private var dailyChart: some View {
        Chart(daily) { day in
            BarMark(
                x: .value("Day", day.date, unit: .day),
                y: .value("Bytes", day.dl + day.ul)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.netDown.opacity(0.85), Color.netUp.opacity(0.85)],
                    startPoint: .bottom, endPoint: .top
                )
            )
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, daily.count / 5))) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis(.hidden)
        .accessibilityLabel("Daily usage for \(window.label)")
    }

    // MARK: - Top networks

    @ViewBuilder
    private var topNetworksRow: some View {
        let entries = ssidPivot.isEmpty ? ifacePivot : ssidPivot
        let label = ssidPivot.isEmpty ? "Top interfaces" : "Top networks"
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            ForEach(entries.prefix(3)) { entry in
                HStack {
                    Text(entry.key)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(monitor.formatBytes(UInt64(max(0, entry.total))))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Data load

    private func reload() {
        let h = History.shared
        totals     = h.totals(in: window)
        ssidPivot  = h.pivotBySSID(in: window)
        ifacePivot = h.pivotByInterface(in: window)
        switch window {
        case .today:
            hourly = h.hourlyToday()
            daily  = []
        case .last7:
            hourly = []
            daily  = h.dailyTotals(lastDays: 7)
        case .last30:
            hourly = []
            daily  = h.dailyTotals(lastDays: 30)
        case .lifetime:
            hourly = []
            daily  = h.dailyTotals(lastDays: 60)  // chart 60 days; totals are full-lifetime
        }
        refreshTick &+= 1
    }
}
