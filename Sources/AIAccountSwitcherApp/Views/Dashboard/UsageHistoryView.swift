import Charts
import SwiftUI
import SwitcherCore

/// Small line chart of the recorded 5-hour and weekly utilisation.
struct UsageHistoryView: View {
    var points: [UsageCache.HistoryPoint]

    var body: some View {
        if points.count < 2 {
            Text("History appears after a few refreshes.").font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(points) { p in
                    if let v = p.fiveHour {
                        LineMark(x: .value("Time", p.at), y: .value("Used %", v), series: .value("Window", "5-hour"))
                            .foregroundStyle(.green)
                    }
                    if let v = p.weekly {
                        LineMark(x: .value("Time", p.at), y: .value("Used %", v), series: .value("Window", "Weekly"))
                            .foregroundStyle(.purple)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .frame(height: 120)
        }
    }
}
