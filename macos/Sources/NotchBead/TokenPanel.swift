import Charts
import SwiftUI

/// Today's token use in the notch: the total and its cost, the last seven days by agent, and today
/// split by agent and by model. Opened by clicking the token figure; the full dashboard is a click away.
struct TokenPanel: View {
    /// Bumped each time the panel opens, so it loads fresh numbers.
    var openToken = 0
    @State private var stats: TokenBoard.Stats?
    @State private var failed = false
    @State private var collecting = false
    @State private var showsModels = false

    private static let colors: [String: Color] = [
        "pi": Color(hex: 0xB08F45),
        "claude-code": Color(hex: 0xC2714F),
        "codex": Color(hex: 0x7468CC),
        "workbuddy": Color(hex: 0x2E9E76),
    ]
    private static let palette: [Color] = [0x7468CC, 0xB08F45, 0x2E9E76, 0xC58AF9, 0xF97583, 0x63D3D8].map { Color(hex: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let stats {
                WeekChart(week: stats.week, color: color(forSource:))
                    .frame(height: 92)
                    .padding(10)
                    .card()
                breakdown(stats)
            } else {
                Text(failed ? "tokenboard isn't answering on this Mac." : "Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .task(id: openToken) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DashboardWindow.didIngest)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        let fresh = await TokenBoard.stats()
        failed = fresh == nil
        if let fresh, fresh != stats {
            withAnimation(.panelSpring) { stats = fresh }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stats.map { TokenText.yi($0.total) } ?? "—")
                        .font(.system(size: 24, weight: .semibold))
                        .contentTransition(.numericText())
                    if let stats {
                        Text(TokenText.cost(stats.cost, partial: stats.costPartial))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .help(stats.costPartial ? "Some models have no price in pricing.json, so this is a lower bound." : "Estimated from pricing.json")
                    }
                }
                .monospacedDigit()
            }
            Spacer()
            HStack(spacing: 6) {
                Button {
                    Task {
                        collecting = true
                        if await TokenBoard.collect() {
                            NotificationCenter.default.post(name: DashboardWindow.didIngest, object: nil)
                        }
                        collecting = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(collecting ? 360 : 0))
                        .animation(collecting ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: collecting)
                }
                .buttonStyle(CircleIconButtonStyle())
                .disabled(collecting)
                .help("采集: collect from the agents' logs now")
                Button {
                    DashboardWindow.shared.show()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(CircleIconButtonStyle())
                .help("Open the full dashboard")
            }
        }
        .padding(.horizontal, Metrics.edge - 6)
    }

    // MARK: - Breakdown

    private func breakdown(_ stats: TokenBoard.Stats) -> some View {
        let rows = showsModels ? Array(stats.models.prefix(6)) : stats.agents
        let top = max(rows.first?.tokens ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $showsModels) {
                Text("By agent").tag(false)
                Text("By model").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                ShareRow(
                    share: row,
                    fraction: Double(row.tokens) / Double(top),
                    color: showsModels ? Self.palette[index % Self.palette.count] : color(forSource: row.key)
                )
            }
            if rows.isEmpty {
                Text("Nothing yet today.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .card()
    }

    private func color(forSource source: String) -> Color {
        Self.colors[source] ?? Self.palette[abs(source.hashValue) % Self.palette.count]
    }
}

/// One agent or model: its name, a bar against the largest, tokens and cost.
private struct ShareRow: View {
    let share: TokenBoard.Share
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(share.key)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(TokenText.compact(share.tokens))
                    .font(.system(size: 12, weight: .medium))
                Text(TokenText.cost(share.cost, partial: share.costPartial))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            .monospacedDigit()
            GeometryReader { proxy in
                Capsule().fill(color.opacity(0.85))
                    .frame(width: max(2, proxy.size.width * fraction), height: 3)
            }
            .frame(height: 3)
        }
    }
}

/// The last seven days, stacked by agent; today is the last bar.
private struct WeekChart: View {
    let week: [TokenBoard.Day]
    let color: (String) -> Color

    private struct Bar: Identifiable {
        var day: String
        var source: String
        var tokens: Double
        var id: String { day + source }
    }

    var body: some View {
        let sources = Set(week.flatMap(\.bySource.keys)).sorted()
        let bars = week.flatMap { day in
            sources.map { Bar(day: day.day, source: $0, tokens: Double(day.bySource[$0] ?? 0) / 1e8) }
        }
        Chart(bars) { bar in
            BarMark(x: .value("Day", Self.label(bar.day)), y: .value("亿", bar.tokens), width: .ratio(0.62))
                .foregroundStyle(color(bar.source))
                .cornerRadius(2)
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel { if let v = value.as(Double.self) { Text(v == 0 ? "0" : String(format: "%g亿", v)) } }
                    .font(.system(size: 9))
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) }
        }
    }

    /// "11/06" for a date like "2026-11-06".
    static func label(_ day: String) -> String {
        let parts = day.split(separator: "-")
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : day
    }
}

/// A round icon button like the task list's header buttons.
private struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: Metrics.controlSize, height: Metrics.controlSize)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .contentShape(Circle())
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
