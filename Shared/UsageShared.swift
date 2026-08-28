import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Model (shared by the app and the widget extension)

struct UsageLimit: Identifiable, Codable, Hashable {
    let id: String
    let label: String
    /// Percent, 0–100.
    let utilization: Double
    let resetsAt: Date?
}

/// One organization on a claude.ai login. A single account can belong to more
/// than one (a personal org plus a team, say), and each carries its own plan and
/// its own usage limits, so each is fetched separately.
struct OrgInfo: Identifiable, Codable, Hashable {
    let id: String          // the org uuid
    let name: String
    let plan: String?       // Pro / Max / Team / Enterprise, when the API says
}

/// What the host app hands to the widget through the App Group container.
struct UsageSnapshot: Codable {
    var limits: [UsageLimit]
    var updated: Date
    var subscription: String?
    /// The org these limits belong to, and whether there are others to switch
    /// between. Both optional so a snapshot written by an older build still
    /// decodes; the widget only shows the name when there's more than one org.
    var orgName: String?
    var orgCount: Int?

    /// The headline number: the 5-hour session window when present.
    var headline: UsageLimit? {
        limits.first(where: { $0.id == "five_hour" })
            ?? limits.max(by: { $0.utilization < $1.utilization })
    }

    /// True when the user has more than one org, so labelling is worth the space.
    var showsOrgName: Bool { (orgCount ?? 1) > 1 && !(orgName ?? "").isEmpty }

    static let empty = UsageSnapshot(
        limits: [], updated: .distantPast, subscription: nil, orgName: nil, orgCount: nil
    )
}

// MARK: - App Group plumbing

enum SharedStore {
    /// On macOS an App Group id is team-prefixed, which isn't known until signing.
    /// Both targets carry it in Info.plist as `$(TeamIdentifierPrefix)group.…`,
    /// expanded at build time, so we just read it back here.
    static var appGroupID: String {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "group.com.jpuritz.claudar"
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("usage-snapshot.json")
    }

    static func write(_ snapshot: UsageSnapshot) {
        guard let url = snapshotURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> UsageSnapshot? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }
}

// MARK: - Deep links

enum ClaudarURL {
    static let scheme = "claudar"
    /// Opened when the user clicks the widget — brings up the usage window.
    static let window = URL(string: "\(scheme)://window")!
}

// MARK: - Severity

/// The single source of truth for "how alarming is this percentage".
///
/// Both palettes live here so the menu bar ring, the panel bars, and the widget
/// can't drift apart — they previously used custom RGB in SwiftUI and
/// `NSColor.system*` in AppKit, which rendered as visibly different greens.
enum Severity: CaseIterable {
    case ok         // < 50%
    case notice     // < 75%
    case warning    // < 90%
    case critical   // ≥ 90%

    static func forPercent(_ pct: Double) -> Severity {
        switch pct {
        case ..<50: return .ok
        case ..<75: return .notice
        case ..<90: return .warning
        default: return .critical
        }
    }

    /// Red, green, blue in 0–1. One definition, two color types below.
    var components: (r: Double, g: Double, b: Double) {
        switch self {
        case .ok:       return (0.22, 0.72, 0.45)
        case .notice:   return (0.95, 0.77, 0.06)
        case .warning:  return (0.96, 0.55, 0.14)
        case .critical: return (0.91, 0.26, 0.21)
        }
    }

    var color: Color {
        let c = components
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    #if canImport(AppKit)
    var nsColor: NSColor {
        let c = components
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
    #endif
}

func severityColor(_ pct: Double) -> Color { Severity.forPercent(pct).color }

// MARK: - Presentation helpers (shared)

enum UsageFormat {
    static func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v.rounded())
    }

    /// Weekday + hour, in the user's locale — a 24-hour-clock user should not be
    /// shown "Mon 6 PM". Built from a template so the field order is localized too.
    private static let dayHourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE j")
        return f
    }()

    static func resetString(_ date: Date?) -> String {
        guard let date else { return "" }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "resetting…" }
        if interval < 36 * 3600 {
            let h = Int(interval) / 3600
            let m = (Int(interval) % 3600) / 60
            return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
        }
        return "resets \(dayHourFormatter.string(from: date))"
    }

    static func staleString(_ updated: Date) -> String {
        let mins = Int(Date().timeIntervalSince(updated) / 60)
        if mins < 2 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h ago"
    }
}
