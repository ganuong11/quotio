import Foundation

/// How a limit is tracking against spending its window evenly.
///
/// Expected remaining is where an even spend would be right now:
/// `100 × (1 − elapsed / window)`. Remaining below that runs out before the reset.
public struct QuotaPace: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case onPace
        case behind
        case exhausted
    }

    public let remaining: Double
    public let expectedRemaining: Double
    public let windowStart: Date
    public let resetsAt: Date
    public let status: Status
    /// Average use per day since the window opened, in percentage points.
    public let usedPerDay: Double
    /// Use per day that would last exactly until the reset, in percentage points.
    public let budgetPerDay: Double
    /// When remaining reaches zero at the average rate, if that comes before the reset.
    public let projectedEmpty: Date?

    /// Below this share of the window there is too little history for a rate to mean anything.
    static let minimumElapsedFraction = 0.02
    /// Points below the even-pace mark that still count as on pace, so a hair's
    /// difference doesn't flip the bar to amber.
    static let behindTolerance = 3.0

    public init?(remainingPercent: Double, resetsAt: Date?, windowDuration: TimeInterval?, now: Date) {
        guard remainingPercent >= 0, let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
        let untilReset = resetsAt.timeIntervalSince(now)
        guard untilReset > 0, untilReset <= windowDuration * 1.01 else { return nil }
        let remaining = min(100, remainingPercent)
        let elapsed = max(0, windowDuration - untilReset)
        let day: TimeInterval = 86_400

        self.remaining = remaining
        self.resetsAt = resetsAt
        windowStart = resetsAt.addingTimeInterval(-windowDuration)
        expectedRemaining = 100 * untilReset / windowDuration
        budgetPerDay = remaining / (untilReset / day)

        let used = 100 - remaining
        if elapsed >= windowDuration * Self.minimumElapsedFraction, used > 0 {
            let perSecond = used / elapsed
            usedPerDay = perSecond * day
            let empty = now.addingTimeInterval(remaining / perSecond)
            projectedEmpty = remaining > 0 && empty < resetsAt ? empty : nil
        } else {
            usedPerDay = 0
            projectedEmpty = nil
        }

        if remaining <= 0 {
            status = .exhausted
        } else if projectedEmpty != nil, remaining < expectedRemaining - Self.behindTolerance {
            status = .behind
        } else {
            status = .onPace
        }
    }
}

public extension QuotaPace {
    var windowDuration: TimeInterval { resetsAt.timeIntervalSince(windowStart) }

    /// What would be left at the reset if the average rate holds.
    func remainingAtReset(now: Date) -> Double {
        max(0, remaining - usedPerDay * resetsAt.timeIntervalSince(now) / 86_400)
    }
}

public extension QuotaMetric {
    /// Beyond this horizon a reset timestamp is a no-expiry sentinel (e.g. year 9999),
    /// not a countdown worth rendering.
    private static var meaningfulResetHorizon: TimeInterval { 366 * 5 * 86_400 }

    var resetDate: Date? {
        guard !resetTime.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: resetTime) ?? ISO8601DateFormatter().date(from: resetTime)
        guard let date, date.timeIntervalSinceNow < Self.meaningfulResetHorizon else { return nil }
        return date
    }

    func pace(now: Date = Date()) -> QuotaPace? {
        QuotaPace(remainingPercent: percentage, resetsAt: resetDate, windowDuration: windowDuration, now: now)
    }
}
