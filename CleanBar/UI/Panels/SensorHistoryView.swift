import Charts
import SwiftUI

/// A sensor's temperature or a fan's speed over the last hour, day, week or month, shown next to the sensors list. Stretches
/// when the Mac was asleep or CleanBar wasn't running stay empty. The pointer over the chart shows when a sample is from and
/// what it was.
struct SensorHistoryView: View {
    let row: SensorRow
    let monitor: SensorMonitor
    @Bindable var settings: AppSettings
    @State private var points: [HistoryPoint] = []
    /// Whether `points` has been read yet.
    @State private var isLoaded = false
    /// The moment the chart ends, which is when it was last read.
    @State private var end = Date.now
    @State private var selected: HistoryPoint?

    /// Wide enough for the longest sensor names next to the range buttons.
    static let size = NSSize(width: 500, height: 300)

    private struct LoadKey: Hashable {
        let row: String
        let range: HistoryRange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(HistoryRange.allCases) { range in
                    RangeButton(title: range.title, isSelected: settings.historyRange == range) {
                        settings.historyRange = range
                    }
                }
                Spacer(minLength: 12)
                SymbolBadge(symbol: row.symbol, tint: row.tint, size: 16)
                Text(row.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            chart
                // Just for the moment it takes to read: it'd show axes that don't go with the samples.
                .opacity(isLoaded ? 1 : 0)
        }
        .padding(12)
        .frame(width: Self.size.width, height: Self.size.height)
        .task(id: LoadKey(row: row.id, range: settings.historyRange)) {
            selected = nil
            // A shorter chart moves on sooner.
            let refresh = max(Double(settings.historyRange.sampleLength), 10)
            while !Task.isCancelled {
                let now = Date.now
                let latest = await monitor.history.points(of: row.id, in: settings.historyRange, at: now)
                guard !Task.isCancelled else { return }
                points = latest
                isLoaded = true
                end = now
                try? await Task.sleep(for: .seconds(refresh))
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        let segments = Self.segments(of: points, sampleLength: settings.historyRange.sampleLength)
        let domain = fan.map { Self.speedDomain(of: points, fan: $0) } ?? Self.temperatureDomain(of: points)
        let start = end.addingTimeInterval(-Double(settings.historyRange.duration))
        Chart {
            ForEach(segments, id: \.first?.id) { segment in
                ForEach(segment) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Bottom", domain.lowerBound),
                        yEnd: .value("Reading", shown(point)),
                        series: .value("Stretch", segment.first?.date ?? point.date)
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [row.tint.opacity(0.35), row.tint.opacity(0.03)], startPoint: .top, endPoint: .bottom)
                    )
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Reading", shown(point)),
                        series: .value("Stretch", segment.first?.date ?? point.date)
                    )
                    .foregroundStyle(row.tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                }
            }
            if let selected {
                PointMark(
                    x: .value("Time", selected.date),
                    y: .value("Reading", shown(selected))
                )
                .symbolSize(36)
                .foregroundStyle(row.tint)
                // Where there's room for it without covering the sample.
                .annotation(
                    position: shown(selected) > (domain.lowerBound + domain.upperBound) / 2 ? .bottom : .top,
                    spacing: 8,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    HistoryTooltip(date: selected.date, reading: label(selected))
                }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: .top) {
                        Text(date, format: settings.historyRange.duration > 86_400
                            ? .dateTime.day().month(.abbreviated)
                            : .dateTime.hour().minute())
                    }
                }
            }
        }
        .chartYAxis {
            if fan == nil {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    if let degrees = value.as(Double.self) {
                        AxisValueLabel(TemperatureText.string(degrees: degrees))
                    }
                }
            } else {
                // The fan's slowest and fastest speeds, and what's between them.
                AxisMarks(position: .leading, values: (0...4).map { domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double($0) / 4 }) { value in
                    AxisGridLine()
                    if let speed = value.as(Double.self) {
                        AxisValueLabel(String(Int(speed.rounded())))
                    }
                }
            }
        }
        .chartOverlay { chart in
            GeometryReader { geometry in
                PointerArea { isInside, _ in
                    if !isInside {
                        selected = nil
                    }
                } onMove: { location in
                    guard let plot = chart.plotFrame else { return }
                    let x = location.x - geometry[plot].minX
                    guard let date: Date = chart.value(atX: x) else { return }
                    let nearest = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                    // Nothing to say about a gap.
                    selected = nearest.flatMap { point in
                        abs(point.date.timeIntervalSince(date)) <= Self.longestStep(sampleLength: settings.historyRange.sampleLength) ? point : nil
                    }
                }
            }
        }
        .overlay {
            if points.isEmpty {
                Text("No readings yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The fan this is the history of, if it is one's.
    private var fan: FanReading? {
        guard case .fan(let index) = row.kind else { return nil }
        return monitor.fans.first { $0.index == index }
    }

    /// A sample as it goes on the chart: a temperature in the Mac's unit, or a speed.
    private func shown(_ point: HistoryPoint) -> Double {
        row.isFan ? point.value : TemperatureText.degrees(point.value)
    }

    private func label(_ point: HistoryPoint) -> String {
        row.isFan ? String(localized: "\(Int(point.value.rounded())) rpm") : TemperatureText.string(point.value)
    }

    /// The stretches of samples with nothing missing between them: the chart doesn't draw a line across a gap. A stretch
    /// that's only one sample gets a second point at its end, or it wouldn't show at all.
    static func segments(of points: [HistoryPoint], sampleLength: Int) -> [[HistoryPoint]] {
        var segments: [[HistoryPoint]] = []
        for point in points {
            if let last = segments.last?.last, point.date.timeIntervalSince(last.date) <= longestStep(sampleLength: sampleLength) {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
        }
        return segments.map { segment in
            guard segment.count == 1, let point = segment.first else { return segment }
            return [point, HistoryPoint(date: point.date.addingTimeInterval(Double(sampleLength)), value: point.value)]
        }
    }

    /// How far apart two samples can be without leaving a gap between them. A sample or two can go missing while the Mac
    /// is busy, and a minute means nothing on a chart of an hour.
    private static func longestStep(sampleLength: Int) -> TimeInterval {
        max(Double(sampleLength) * 2.5, 60)
    }

    /// From a little under the lowest temperature to a little over the highest, in the Mac's unit, on multiples of 5.
    static func temperatureDomain(of points: [HistoryPoint]) -> ClosedRange<Double> {
        let degrees = points.map { TemperatureText.degrees($0.value) }
        guard let lowest = degrees.min(), let highest = degrees.max() else { return 0...100 }
        let bottom = ((lowest - 2) / 5).rounded(.down) * 5
        let top = ((highest + 2) / 5).rounded(.up) * 5
        return bottom...top
    }

    /// From a fan's slowest speed to its fastest, or wider if it read outside them: some stop altogether when they can.
    static func speedDomain(of points: [HistoryPoint], fan: FanReading) -> ClosedRange<Double> {
        let speeds = points.map(\.value)
        let lowest = min(speeds.min() ?? fan.minimum, fan.minimum)
        let highest = max(speeds.max() ?? fan.maximum, fan.maximum)
        return lowest < highest ? lowest...highest : lowest...(lowest + 1)
    }
}

/// When a sample is from and what it was.
private struct HistoryTooltip: View {
    let date: Date
    let reading: String

    var body: some View {
        VStack(spacing: 2) {
            Text(date, format: .dateTime.day().month(.abbreviated).year())
            Text(date, format: .dateTime.hour().minute())
            Text(reading)
                .fontWeight(.semibold)
                .padding(.top, 4)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .strokeBorder(.separator)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        }
    }
}

private struct RangeButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.callout)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .opacity(isSelected || isHovered ? 1 : 0)
            }
            .overlay {
                PointerArea(label: title) { isInside, _ in
                    isHovered = isInside
                } onClick: { _ in
                    action()
                }
            }
    }
}
