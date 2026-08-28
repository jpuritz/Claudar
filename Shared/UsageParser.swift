import Foundation

/// Pure parsing of the shapes Anthropic hands back — no networking, no state,
/// no actor isolation. Kept separate from `UsageModel` so it can be unit tested
/// directly (see Tests/), because these are the parts most likely to break when
/// an upstream payload changes.
enum UsageParser {

    // MARK: - Usage limits

    private static let labelMap: [String: String] = [
        "five_hour": "Session (5 h)",
        "seven_day": "Weekly · all models",
        "seven_day_sonnet": "Weekly · Sonnet",
        "seven_day_opus": "Weekly · Opus",
        "seven_day_oauth_apps": "Weekly · OAuth apps",
        "extra_usage": "Extra usage",
    ]

    private static let preferredOrder = [
        "five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus",
        "seven_day_oauth_apps", "extra_usage",
    ]

    /// Parses the usage payload defensively: any object (at the top level or
    /// nested) carrying a numeric "utilization" is treated as a limit. New limits
    /// Anthropic adds therefore appear with no code change; unknown keys get a
    /// title-cased label.
    static func limits(from data: Data) -> [UsageLimit] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var found: [String: UsageLimit] = [:]

        func scan(_ dict: [String: Any]) {
            for (key, value) in dict {
                guard let entry = value as? [String: Any] else { continue }
                if let num = entry["utilization"] as? NSNumber {
                    let label = labelMap[key] ?? key
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized
                    found[key] = UsageLimit(
                        id: key,
                        label: label,
                        utilization: min(max(num.doubleValue, 0), 100),
                        resetsAt: (entry["resets_at"] as? String).flatMap(isoDate)
                    )
                } else {
                    scan(entry)
                }
            }
        }
        scan(root)

        var ordered: [UsageLimit] = []
        for key in preferredOrder {
            if let l = found.removeValue(forKey: key) { ordered.append(l) }
        }
        ordered.append(contentsOf: found.values.sorted { $0.id < $1.id })
        return ordered
    }

    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - claude.ai org & plan

    /// Parses `/api/organizations` into every org on the login, in the order the
    /// API returns them.
    ///
    /// A login can belong to several orgs (a personal one plus a team), each with
    /// its own plan and its own usage. Entries with no uuid are unusable, so they
    /// are skipped; duplicates are collapsed; an entry with no name falls back to
    /// a short form of its uuid so the switcher always has a label to show.
    static func organizations(from data: Data) -> [OrgInfo] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var orgs: [OrgInfo] = []
        for entry in arr {
            guard let uuid = entry["uuid"] as? String, !uuid.isEmpty,
                  seen.insert(uuid).inserted else { continue }
            let trimmed = (entry["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            orgs.append(OrgInfo(
                id: uuid,
                name: trimmed.isEmpty ? "Org \(uuid.prefix(8))" : trimmed,
                plan: planLabel(from: entry["capabilities"] as? [String] ?? [])
            ))
        }
        return orgs
    }

    /// claude.ai reports the plan as an org capability, e.g. ["claude_pro", "chat"].
    static func planLabel(from capabilities: [String]) -> String? {
        if capabilities.contains("claude_max") { return "Max" }
        if capabilities.contains("claude_pro") { return "Pro" }
        if capabilities.contains("claude_team") { return "Team" }
        if capabilities.contains("claude_enterprise") { return "Enterprise" }
        return nil
    }

    /// The session cookie carries `lastActiveOrg`, so an org lookup is usually
    /// unnecessary. Values are percent-encoded in the cookie.
    static func orgID(fromCookie cookie: String) -> String? {
        for piece in cookie.split(separator: ";") {
            let kv = piece.trimmingCharacters(in: .whitespaces)
            guard kv.hasPrefix("lastActiveOrg=") else { continue }
            let raw = String(kv.dropFirst("lastActiveOrg=".count))
            let value = raw.removingPercentEncoding ?? raw
            if !value.isEmpty { return value }
        }
        return nil
    }
}
