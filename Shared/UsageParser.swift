import Foundation

/// Pure parsing of the shapes Anthropic hands back — no networking, no state,
/// no actor isolation. Kept separate from `UsageModel` so it can be unit tested
/// directly (see Tests/), because these are the parts most likely to break when
/// an upstream payload changes.
enum UsageParser {

    // MARK: - Usage limits

    /// Keys whose wording doesn't follow from the key itself.
    private static let labelMap: [String: String] = [
        "five_hour": "Session (5 h)",
        "seven_day": "Weekly · all models",
        "seven_day_oauth_apps": "Weekly · OAuth apps",
        "extra_usage": "Extra usage",
    ]

    /// Per-model weekly limits all share one shape: `seven_day_<model>`. Naming
    /// them by rule rather than by table means a model Anthropic adds later is
    /// labelled correctly with no code change, which is how Fable shows up
    /// alongside Sonnet and Opus.
    static func label(for key: String) -> String {
        if let mapped = labelMap[key] { return mapped }
        if key.hasPrefix("seven_day_") {
            let model = key.dropFirst("seven_day_".count)
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !model.isEmpty { return "Weekly · \(model.capitalized)" }
        }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Display order. Model limits sit together under the all-models total, in
    /// rough order of how much they cost you.
    private static let preferredOrder = [
        "five_hour", "seven_day",
        "seven_day_opus", "seven_day_fable", "seven_day_sonnet", "seven_day_haiku",
        "seven_day_oauth_apps", "extra_usage",
    ]

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 100) }

    /// Maps a `limits` array entry onto the id vocabulary the rest of the app
    /// already uses, so the menu bar's five-hour lookup, the display order, and
    /// saved notification state all keep working unchanged.
    static func canonicalID(kind: String, scope: [String: Any]?) -> String {
        switch kind {
        case "session": return "five_hour"
        case "weekly_all": return "seven_day"
        case "weekly_scoped":
            if let name = scopeName(scope), !name.isEmpty {
                let slug = name.lowercased().replacingOccurrences(of: " ", with: "_")
                return "seven_day_\(slug)"
            }
            return "seven_day_scoped"
        default: return kind
        }
    }

    /// A scoped limit names either a model ("Fable") or a surface.
    private static func scopeName(_ scope: [String: Any]?) -> String? {
        guard let scope else { return nil }
        if let model = scope["model"] as? [String: Any],
           let name = model["display_name"] as? String, !name.isEmpty { return name }
        if let surface = scope["surface"] as? [String: Any],
           let name = surface["display_name"] as? String, !name.isEmpty { return name }
        if let surface = scope["surface"] as? String, !surface.isEmpty { return surface }
        return nil
    }

    /// Parses the usage payload. Two shapes have to be handled.
    ///
    /// Newer responses carry a `limits` ARRAY, which is what Claude Code renders
    /// and the only place per-model limits appear: an entry with
    /// `kind: "weekly_scoped"` and `scope.model.display_name: "Fable"` is the
    /// Fable weekly limit. It uses `percent` where the older shape used
    /// `utilization`. Alongside it the payload still carries legacy top-level
    /// keys plus a number of internal codenames (`nimbus_quill`, `amber_ladder`,
    /// …) that Claude Code does not show, so when the array is present only
    /// explicitly-labelled top-level keys are merged in, which is how
    /// `extra_usage` still appears.
    ///
    /// Older responses have no array. Those fall back to the original behaviour:
    /// any object carrying a numeric `utilization` is a limit, so a limit added
    /// upstream still appears with no code change.
    static func limits(from data: Data) -> [UsageLimit] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var found: [String: UsageLimit] = [:]

        let array = (root["limits"] as? [[String: Any]]) ?? []
        for entry in array {
            guard let kind = entry["kind"] as? String, !kind.isEmpty,
                  let pct = entry["percent"] as? NSNumber else { continue }
            let scope = entry["scope"] as? [String: Any]
            let id = canonicalID(kind: kind, scope: scope)
            let label: String
            if kind == "weekly_scoped", let name = scopeName(scope) {
                label = "Weekly · \(name)"
            } else {
                label = self.label(for: id)
            }
            found[id] = UsageLimit(
                id: id, label: label,
                utilization: clamp(pct.doubleValue),
                resetsAt: (entry["resets_at"] as? String).flatMap(isoDate)
            )
        }

        let arrayWon = !found.isEmpty

        func scan(_ dict: [String: Any]) {
            for (key, value) in dict {
                guard let entry = value as? [String: Any] else { continue }
                if let num = entry["utilization"] as? NSNumber {
                    // The array is authoritative where it spoke, and once it has,
                    // only keys we can actually name are worth showing.
                    if found[key] != nil { continue }
                    if arrayWon && labelMap[key] == nil { continue }
                    found[key] = UsageLimit(
                        id: key,
                        label: label(for: key),
                        utilization: clamp(num.doubleValue),
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
        ordered.append(contentsOf: found.values.sorted {
            let aWeekly = $0.id.hasPrefix("seven_day_")
            let bWeekly = $1.id.hasPrefix("seven_day_")
            if aWeekly != bWeekly { return aWeekly }
            return $0.id < $1.id
        })
        return ordered
    }

    /// Describes the payload's shape: key paths, which carry a utilization,
    /// numbers, and short strings. Long strings are elided so account identifiers
    /// stay out of the log. Off by default, behind the `LogPayloadShape` user
    /// default; this is what found the `limits` array when Fable was showing in
    /// Claude Code but not here, and the payload will change again.
    static func debugShape(_ data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "  <not a JSON object>"
        }
        var lines: [String] = []
        func walk(_ dict: [String: Any], path: String, depth: Int) {
            guard depth < 6 else { return }
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                let p = path.isEmpty ? k : "\(path).\(k)"
                if let child = v as? [String: Any] {
                    if let u = child["utilization"] as? NSNumber {
                        lines.append("  \(p)  utilization=\(u)")
                    } else {
                        lines.append("  \(p)  {object}")
                    }
                    // Walk in even when this level had a utilization: a limit
                    // could be nested inside another one.
                    walk(child, path: p, depth: depth + 1)
                } else if let n = v as? NSNumber {
                    lines.append("  \(p) = \(n)")
                } else if let arr = v as? [Any] {
                    lines.append("  \(p) = [array of \(arr.count)]")
                    for (i, item) in arr.enumerated() {
                        if let obj = item as? [String: Any] {
                            walk(obj, path: "\(p)[\(i)]", depth: depth + 1)
                        } else {
                            lines.append("  \(p)[\(i)] = <\(type(of: item))>")
                        }
                    }
                } else if let str = v as? String {
                    // Short strings only: these are type/label names, not ids.
                    lines.append("  \(p) = \(str.count <= 40 ? "\"\(str)\"" : "<long string>")")
                } else {
                    lines.append("  \(p) = <\(type(of: v))>")
                }
            }
        }
        walk(root, path: "", depth: 0)
        return lines.isEmpty ? "  <empty>" : lines.joined(separator: "\n")
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
