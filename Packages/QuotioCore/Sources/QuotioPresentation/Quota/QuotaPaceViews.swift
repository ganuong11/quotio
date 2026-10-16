import QuotioDomain
import SwiftUI

/// One limit as the pace-tick meters draw it.
@MainActor
struct QuotaMeter {
    enum Tone { case good, behind, critical, unknown }

    let metric: QuotaMetric
    let displayMode: QuotaDisplayMode
    let pace: QuotaPace?
    let tone: Tone

    init(metric: QuotaMetric, displayMode: QuotaDisplayMode, now: Date = Date()) {
        self.metric = metric
        self.displayMode = displayMode
        pace = metric.pace(now: now)
        tone = Self.tone(remaining: metric.percentage, pace: pace)
    }

    var name: String { metric.displayName }
    var hasData: Bool { metric.percentage >= 0 }
    var remaining: Double { max(0, min(100, metric.percentage)) }
    var isExhausted: Bool { hasData && remaining <= 0 }
    var resetsAt: Date? { metric.resetDate }
    /// The source names the reset day only, so clock times and countdowns would overstate it.
    var resetsOnDate: Bool { metric.resetPrecision == .day }

    var displayValue: Double { displayMode.displayValue(from: remaining) }
    var valueText: String { hasData ? "\(Int(displayValue.rounded()))%" : "—" }

    /// Where the even-pace mark sits on the bar, in the same direction as the fill.
    var tickFraction: Double? {
        guard let pace else { return nil }
        let expected = displayMode == .used ? 100 - pace.expectedRemaining : pace.expectedRemaining
        return min(1, max(0, expected / 100))
    }

    var color: Color { tone.color }

    /// Value text stays in label color unless the limit needs attention.
    var valueColor: Color {
        switch tone {
        case .good, .unknown: .primary
        case .behind, .critical: tone.color
        }
    }

    /// Without a window length, colors fall back to fixed thresholds on what is left.
    private static func tone(remaining: Double, pace: QuotaPace?) -> Tone {
        guard remaining >= 0 else { return .unknown }
        if remaining <= 0 { return .critical }
        if let pace { return pace.status == .behind ? .behind : .good }
        if remaining > 50 { return .good }
        if remaining > 20 { return .behind }
        return .critical
    }
}

extension QuotaMeter.Tone {
    var color: Color {
        switch self {
        case .good: .green
        case .behind: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }
}

// MARK: - Formatting

enum QuotaTimeText {
    /// "1h 42m", "2d 3h", "34m".
    static func duration(until date: Date, now: Date = Date()) -> String {
        let minutes = max(1, Int(date.timeIntervalSince(now) / 60))
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    static func weekdayTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// A day-precision reset sits at midnight UTC; reading it in UTC keeps the
    /// named day from shifting to the day before west of Greenwich.
    static func day(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = .gmt
        return date.formatted(style)
    }

    /// Within a day the countdown reads better than a clock time.
    @MainActor
    static func reset(_ date: Date, onDate: Bool = false, now: Date = Date()) -> String {
        if onDate {
            return String(format: "quota.reset.at".localized(), day(date))
        }
        if date.timeIntervalSince(now) < 86_400 {
            return String(format: "quota.reset.in".localized(), duration(until: date, now: now))
        }
        return String(format: "quota.reset.at".localized(), weekdayTime(date))
    }

    /// "5 hours", "7 days".
    static func window(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 86_400 ? [.day] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter.string(from: duration) ?? ""
    }

    static func percent(_ value: Double) -> String {
        "\(max(1, Int(value.rounded())))%"
    }
}

// MARK: - Bar

/// Remaining (or used) fill with a tick where an even pace would be. When the
/// fill falls short of the tick, the gap between them is tinted.
struct QuotaPaceBar: View {
    let meter: QuotaMeter
    var height: CGFloat = 6
    var tickOverhang: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = meter.hasData ? width * meter.displayValue / 100 : 0
            ZStack(alignment: .leading) {
                Capsule().fill(meter.isExhausted ? AnyShapeStyle(Color.red.opacity(0.12)) : AnyShapeStyle(.fill.tertiary))
                if meter.tone == .behind, let tick = meter.tickFraction {
                    let lower = min(fill, width * tick), upper = max(fill, width * tick)
                    Rectangle()
                        .fill(Color.orange.opacity(0.25))
                        .frame(width: upper - lower)
                        .offset(x: lower)
                }
                Capsule()
                    .fill(meter.color)
                    .frame(width: fill)
                if !meter.isExhausted, let tick = meter.tickFraction {
                    // A background-colored edge keeps the tick readable over a light fill in dark mode.
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: height + tickOverhang * 2)
                        .padding(.horizontal, 1)
                        .background(.background)
                        .offset(x: min(width - 4, max(0, width * tick - 2)))
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + tickOverhang * 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Rates

/// Phrases a pace's rates in the unit that suits its window: hours inside a
/// window shorter than a day, days otherwise.
@MainActor
struct QuotaRateText {
    let hourly: Bool

    init(_ pace: QuotaPace) {
        hourly = pace.windowDuration < 86_400
    }

    /// "~9% an hour", "~34% a day".
    func rate(perDay: Double) -> String {
        String(format: (hourly ? "quota.rate.hour" : "quota.rate.day").localized(),
               QuotaTimeText.percent(hourly ? perDay / 24 : perDay))
    }

    func resetTime(_ pace: QuotaPace, onDate: Bool) -> String {
        if onDate { return QuotaTimeText.day(pace.resetsAt) }
        return hourly ? QuotaTimeText.time(pace.resetsAt) : QuotaTimeText.weekdayTime(pace.resetsAt)
    }
}

// MARK: - Rows

/// Comfortable density: name and value, the pace bar, then reset or projection.
/// Detailed adds a one-line reading of the rate.
struct QuotaLimitRow: View {
    let meter: QuotaMeter
    var showsInsight = false
    /// Recorded use per day, shown in place of a reset the limit does not have.
    var trendPerDay: Double?

    private var insightPace: QuotaPace? {
        guard showsInsight, let pace = meter.pace, pace.usedPerDay > 0 else { return nil }
        return pace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(meter.valueText)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(meter.valueColor)
            }
            QuotaPaceBar(meter: meter)
            footer
                .font(.caption)
            if let pace = insightPace, meter.tone == .behind {
                Label {
                    Text(String(format: "quota.insight.behind".localized(),
                                QuotaRateText(pace).rate(perDay: pace.usedPerDay),
                                QuotaRateText(pace).rate(perDay: pace.budgetPerDay)))
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
            }
        }
        .menuNativeTooltip(meter.metric.tooltip ?? "")
    }

    @ViewBuilder private var footer: some View {
        if meter.tone == .behind, let empty = meter.pace?.projectedEmpty {
            HStack(spacing: 8) {
                Text(String(format: "quota.pace.emptyAt".localized(), QuotaTimeText.weekdayTime(empty)))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let reset = meter.resetsAt {
                    Text(QuotaTimeText.reset(reset, onDate: meter.resetsOnDate))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let reset = meter.resetsAt, reset > Date() {
            HStack(spacing: 8) {
                Text(QuotaTimeText.reset(reset, onDate: meter.resetsOnDate))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let pace = insightPace {
                    Spacer(minLength: 4)
                    Label {
                        Text(String(format: "quota.insight.onPace".localized(),
                                    QuotaRateText(pace).rate(perDay: pace.usedPerDay)))
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        } else if meter.metric.resetNeverExpires {
            Text("quota.reset.noExpiry".localized())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let trendPerDay {
            Label {
                Text(String(format: "quota.trend.week".localized(),
                            String(format: "quota.rate.day".localized(), QuotaTimeText.percent(trendPerDay))))
            } icon: {
                Image(systemName: "chart.line.downtrend.xyaxis")
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            // Keeps every row the same height whether or not a reset is known.
            Text(" ").accessibilityHidden(true)
        }
    }
}

/// A limit that has run out: what ran out, when it comes back, and a countdown.
struct QuotaExhaustedBanner: View {
    let meter: QuotaMeter

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "quota.exhausted.title".localized(), meter.name))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                if let reset = meter.resetsAt {
                    Text(meter.resetsOnDate
                        ? String(format: "quota.exhausted.backOn".localized(), QuotaTimeText.day(reset))
                        : String(format: "quota.exhausted.back".localized(), QuotaTimeText.time(reset)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if meter.metric.resetNeverExpires {
                    Text("quota.reset.noExpiry".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !meter.resetsOnDate, let reset = meter.resetsAt, reset > Date() {
                Label(QuotaTimeText.duration(until: reset), systemImage: "clock")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .menuNativeTooltip(meter.metric.tooltip ?? "")
    }
}

// MARK: - Burn chart

/// One recorded remaining value.
struct QuotaHistoryPoint: Equatable, Sendable {
    let date: Date
    let remaining: Double

    /// Average share used per day since the first point, for limits with no
    /// reset to pace against. Top-ups between points do not count against use.
    static func usedPerDay(_ points: [QuotaHistoryPoint], now: Date = Date()) -> Double? {
        let points = points.sorted { $0.date < $1.date }
        guard let first = points.first else { return nil }
        let days = now.timeIntervalSince(first.date) / 86_400
        guard days >= 1 else { return nil }
        let used = zip(points, points.dropFirst()).reduce(0) { $0 + max(0, $1.0.remaining - $1.1.remaining) }
        return used > 0 ? used / days : nil
    }
}

/// The window so far, the even-pace line, where the current rate leads, and
/// what to do about it.
struct QuotaBurnCard: View {
    let meter: QuotaMeter
    let pace: QuotaPace
    var history: [QuotaHistoryPoint] = []

    private var isBehind: Bool { meter.tone == .behind }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.name + " · " + QuotaTimeText.window(pace.windowDuration))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(meter.valueText)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(meter.valueColor)
            }
            QuotaBurnChart(meter: meter, pace: pace, history: history)
            Divider().opacity(0.6)
            advice
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isBehind ? AnyShapeStyle(Color.orange.opacity(0.07)) : AnyShapeStyle(.fill.quaternary))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isBehind ? Color.orange.opacity(0.25) : .clear)
        }
    }

    private var advice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(isBehind ? .orange : .secondary)
            adviceText
        }
    }

    private var adviceText: Text {
        guard pace.usedPerDay > 0 else {
            return Text("quota.pace.noRate".localized()).foregroundStyle(.secondary)
        }
        let rates = QuotaRateText(pace)
        let rate = Text(rates.rate(perDay: pace.usedPerDay) + ".")
            .fontWeight(.semibold)
            .foregroundStyle(isBehind ? .orange : .primary)
        let plan = isBehind
            ? String(format: "quota.advice.budget".localized(), rates.resetTime(pace, onDate: meter.resetsOnDate), rates.rate(perDay: pace.budgetPerDay))
            : String(format: "quota.advice.leftAtReset".localized(), QuotaTimeText.percent(pace.remainingAtReset(now: Date())))
        return rate + Text(" " + plan).foregroundStyle(.secondary)
    }
}

private struct QuotaBurnChart: View {
    let meter: QuotaMeter
    let pace: QuotaPace
    let history: [QuotaHistoryPoint]
    private let plotHeight: CGFloat = 56

    private var isBehind: Bool { meter.tone == .behind }

    var body: some View {
        let now = Date()
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let size = proxy.size
                let point = { (date: Date, remaining: Double) in
                    CGPoint(x: xPosition(date, width: size.width), y: size.height * (1 - remaining / 100))
                }
                let current = point(now, pace.remaining)
                let recorded = recordedPoints(now: now).map { point($0.date, $0.remaining) } + [current]
                let end = projectionEnd(now: now, size: size)

                Path { path in
                    path.move(to: CGPoint(x: recorded[0].x, y: size.height))
                    recorded.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: current.x, y: size.height))
                    path.closeSubpath()
                }
                .fill(meter.color.opacity(0.15))

                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                }
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))

                Path { path in
                    path.addLines(recorded)
                }
                .stroke(meter.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                Path { path in
                    path.move(to: current)
                    path.addLine(to: end)
                }
                .stroke(isBehind ? .red : meter.color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

                if isBehind {
                    Circle().fill(.red).frame(width: 5, height: 5).position(end)
                }

                Rectangle()
                    .fill(.blue)
                    .frame(width: 1.5, height: size.height)
                    .position(x: size.width - 0.75, y: size.height / 2)

                Circle()
                    .strokeBorder(meter.color, lineWidth: 1.5)
                    .background(Circle().fill(.background))
                    .frame(width: 8, height: 8)
                    .position(current)
            }
            .frame(height: plotHeight)

            axisLabels(now: now)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.name + " " + meter.valueText)
    }

    /// Recorded values since the window opened. Without any, the line assumes
    /// an even spend from a full window to now.
    private func recordedPoints(now: Date) -> [QuotaHistoryPoint] {
        let inWindow = history
            .filter { $0.date >= pace.windowStart && $0.date < now }
            .sorted { $0.date < $1.date }
        return inWindow.isEmpty ? [QuotaHistoryPoint(date: pace.windowStart, remaining: 100)] : inWindow
    }

    /// Weekdays repeat inside a short window, so those read as clock times.
    private func axisText(_ date: Date) -> String {
        pace.windowDuration >= 2 * 86_400 ? QuotaTimeText.weekday(date) : QuotaTimeText.time(date)
    }

    /// The window's edges are only known to the day when the reset is.
    private func edgeText(_ date: Date) -> String {
        meter.resetsOnDate ? QuotaTimeText.day(date) : axisText(date)
    }

    private func xPosition(_ date: Date, width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(pace.windowStart) / pace.windowDuration
        return width * min(1, max(0, fraction))
    }

    private func projectionEnd(now: Date, size: CGSize) -> CGPoint {
        if let empty = pace.projectedEmpty {
            return CGPoint(x: xPosition(empty, width: size.width), y: size.height)
        }
        return CGPoint(x: size.width, y: size.height * (1 - pace.remainingAtReset(now: now) / 100))
    }

    /// Start and reset labels pin to the edges; "Now" and the projected empty
    /// day sit under their points and drop out when they would collide. Close
    /// to the reset, "Now" joins the reset label instead.
    private func axisLabels(now: Date) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let nowX = xPosition(now, width: width)
            let emptyX = pace.projectedEmpty.map { xPosition($0, width: width) }
            let resetText = edgeText(pace.resetsAt)
            let startText = edgeText(pace.windowStart)
            ZStack(alignment: .topLeading) {
                // A weekly window opens and resets on the same weekday, so the start shows its date.
                Text(startText == resetText ? QuotaTimeText.day(pace.windowStart) : startText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if nowX >= width - 75 {
                        Text("quota.chart.now".localized()).foregroundStyle(.primary)
                    }
                    Text(String(format: "quota.chart.reset".localized(), resetText)).foregroundStyle(.blue)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                if nowX > 40, nowX < width - 75, !isBehind || emptyX.map({ abs($0 - nowX) > 40 }) ?? true {
                    Text("quota.chart.now".localized())
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .position(x: nowX, y: 6)
                }
                if isBehind, let empty = pace.projectedEmpty, let emptyX, emptyX > 40, emptyX < width - 75 {
                    Text(axisText(empty))
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                        .fixedSize()
                        .position(x: emptyX, y: 6)
                }
            }
        }
        .font(.caption2)
        .frame(height: 12)
    }
}

/// Explains the chart's three lines once for every card above it.
struct QuotaBurnLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legend("quota.legend.recorded", style: StrokeStyle(lineWidth: 2), color: .green)
            legend("quota.legend.even", style: StrokeStyle(lineWidth: 1, dash: [1, 3]), color: .secondary)
            legend("quota.legend.projection", style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]), color: .green)
            Spacer(minLength: 4)
            Text("quota.pace.estimated".localized())
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legend(_ key: String, style: StrokeStyle, color: Color) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 12, y: 1))
            }
            .stroke(color, style: style)
            .frame(width: 12, height: 2)
            Text(key.localized())
                .lineLimit(1)
                .fixedSize()
        }
    }
}
