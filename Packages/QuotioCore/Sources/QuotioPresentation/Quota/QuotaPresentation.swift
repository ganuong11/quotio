import Foundation
import QuotioDomain

private func parseQuotaResetDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return fractional.date(from: value) ?? standard.date(from: value)
}

private func relativeQuotaResetTime(_ value: String) -> String {
    guard !value.isEmpty, let date = parseQuotaResetDate(value) else { return "—" }
    let interval = date.timeIntervalSinceNow
    guard interval > 0 else { return "now" }
    // No-expiry sentinels (e.g. year 9999) are meaningless as countdowns.
    guard interval < 366 * 5 * 86_400 else { return "—" }
    let totalMinutes = Int(interval / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    let days = hours / 24
    let remainingHours = hours % 24
    if days > 0 {
        return remainingHours > 0 ? "\(days)d \(remainingHours)h" : "\(days)d"
    }
    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    return "\(max(1, minutes))m"
}

@MainActor
public extension QuotaMetricUnit {
    func format(_ value: Double) -> String {
        switch self {
        case .usd:
            value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        case .credits:
            String.localizedStringWithFormat("quota.metric.unit.credits".localizedStatic(), value)
        case .requests:
            String.localizedStringWithFormat("quota.metric.unit.requests".localizedStatic(), value)
        case .searches:
            String.localizedStringWithFormat("quota.metric.unit.searches".localizedStatic(), value)
        default:
            value.formatted(.number.precision(.fractionLength(0...2))) + " " + rawValue
        }
    }
}

@MainActor
public extension QuotaMetric {
    var formattedPercentage: String {
        guard percentage >= 0 else { return "—" }
        return percentage == percentage.rounded()
            ? String(format: "%.0f%%", percentage)
            : String(format: "%.2f%%", percentage)
    }

    var formattedUsage: String? {
        if let presentation {
            switch presentation {
            case .progress(let used, let limit, let unit):
                return unit.format(used) + " / " + unit.format(limit)
            case .amount(let value, let unit, let semantics):
                let key = semantics == .balance ? "quota.metric.balanceValue" : "quota.metric.spentValue"
                return String(format: key.localizedStatic(), unit.format(value))
            case .status(let text):
                return text
            }
        }
        guard let used else { return nil }
        if let limit, limit > 0 { return "\(used)/\(limit)" }
        return "\(used) used"
    }

    var isStandaloneMetric: Bool {
        guard let presentation else { return false }
        return switch presentation {
        case .amount, .status: true
        case .progress: false
        }
    }

    var displayName: String { name }

    var formattedResetTime: String {
        relativeQuotaResetTime(resetTime)
    }
}

@MainActor
public extension ProviderQuota {
    var formattedTokenExpiry: String? {
        guard let tokenExpiresAt else { return nil }
        guard tokenExpiresAt.timeIntervalSinceNow > 0 else { return "Expired" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return "Token expires \(formatter.string(from: tokenExpiresAt))"
    }

    var planDisplayName: String? { planType }

    var metricGroups: [(name: String?, models: [QuotaMetric])] {
        models.filter { !$0.isStandaloneMetric }.reduce(into: []) { groups, metric in
            if let index = groups.firstIndex(where: { $0.name == metric.group }) {
                groups[index].models.append(metric)
            } else {
                groups.append((metric.group, [metric]))
            }
        }
    }
}

public extension QuotaSubscriptionInfo {
    var tierDisplayName: String { effectiveTier?.name ?? "Unknown" }
    var tierDescription: String { effectiveTier?.description ?? "" }
}
