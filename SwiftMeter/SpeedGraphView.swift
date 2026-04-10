import SwiftUI
import Charts

// MARK: - Mini Sparkline View

struct MiniSparklineView: View {
    let data: [Double]
    let color: Color

    // Keep a small non-zero floor so an all-zero series renders as a flat line, not nothing
    private var yMax: Double { max(data.max() ?? 0, 1_024) }

    var body: some View {
        if data.isEmpty {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.07))
                .frame(height: 28)
        } else {
            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { index, value in
                    AreaMark(
                        x: .value("Index", index),
                        yStart: .value("Base", 0),
                        yEnd: .value("Speed", value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Index", index),
                        y: .value("Speed", value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...yMax)   // prevents auto-zoom on low/zero traffic
            .animation(.easeInOut(duration: 0.6), value: data.count)
            .frame(height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Speed Row View

struct SpeedRowView: View {
    let label: String
    let currentSpeed: String
    let color: Color
    let data: [Double]

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                // Glass pill badge
                HStack(spacing: 0) {
                    Text(label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color)
                    Text("  —  ")
                        .font(.system(size: 9))
                        .foregroundStyle(color.opacity(0.5))
                    Text(currentSpeed)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.3), value: currentSpeed)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(color.opacity(0.4), lineWidth: 0.5)
                )

                Spacer()
            }

            MiniSparklineView(data: data, color: color)
        }
    }
}

// MARK: - Signal Strength Bars

struct SignalBarsView: View {
    let percent: Int     // 0-100
    let color: Color

    private var bars: Int {
        switch percent {
        case 0:       return 0
        case 1...25:  return 1
        case 26...50: return 2
        case 51...75: return 3
        default:      return 4
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1.5)
                    .frame(width: 4, height: CGFloat(bar) * 4 + 2)
                    .foregroundStyle(
                        bar <= bars
                            ? AnyShapeStyle(color)
                            : AnyShapeStyle(Color.secondary.opacity(0.25))
                    )
            }
        }
    }
}
