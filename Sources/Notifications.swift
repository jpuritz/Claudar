import Foundation
import UserNotifications

// MARK: - Preferences

enum Prefs {
    private static func bool(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
    private static func set(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static var notifyThresholds: Bool {
        get { bool("NotifyThresholds", default: true) }
        set { set("NotifyThresholds", newValue) }
    }
    static var notifyResets: Bool {
        get { bool("NotifyResets", default: true) }
        set { set("NotifyResets", newValue) }
    }
    static var notifyPace: Bool {
        get { bool("NotifyPace", default: true) }
        set { set("NotifyPace", newValue) }
    }
    static var notifyStatus: Bool {
        get { bool("NotifyStatus", default: true) }
        set { set("NotifyStatus", newValue) }
    }
    /// List every org's limits in the panel at once, instead of only the active
    /// one. Off by default: it's meaningless with a single org, and it makes the
    /// menu considerably taller with several.
    static var showAllOrgs: Bool {
        get { bool("ShowAllOrgs", default: false) }
        set { set("ShowAllOrgs", newValue) }
    }
    static var hotkeyEnabled: Bool {
        get { bool("HotkeyEnabled", default: false) }
        set { set("HotkeyEnabled", newValue) }
    }

    /// Usage-endpoint poll interval, seconds. Clamped to a sane menu of choices.
    static let pollChoices: [Int] = [15, 30, 60, 120]
    static var pollInterval: Int {
        get {
            let v = UserDefaults.standard.object(forKey: "PollInterval") as? Int ?? 30
            return pollChoices.contains(v) ? v : 30
        }
        set { UserDefaults.standard.set(newValue, forKey: "PollInterval") }
    }
}

// MARK: - Notification delivery

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() { super.init() }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    /// Schedules (or replaces — same id overwrites) a one-shot notification.
    func schedule(id: String, at date: Date, title: String, body: String) {
        guard date.timeIntervalSinceNow > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: date.timeIntervalSinceNow, repeats: false
        )
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    func cancel(ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // Show banners even while the app is "active" (menu open, etc.).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Alert logic

/// Decides, on each successful poll, whether anything is notification-worthy:
/// threshold crossings (80 / 95 %), scheduled reset alerts, and burn-rate
/// ("on pace to run out") warnings.
@MainActor
final class AlertEngine {
    static let shared = AlertEngine()

    private let thresholds: [Double] = [80, 95]
    /// Recent (time, utilization) samples per scoped limit, for burn-rate
    /// estimation. Deliberately in-memory: a burn rate measured before a relaunch
    /// says nothing useful about the rate after it.
    private var history: [String: [(Date, Double)]] = [:]

    /// Reset notifications currently scheduled. Tracked so turning the pref off
    /// cancels every org's, not just whichever one happens to be active.
    private var scheduledResetIDs: Set<String> = []

    /// Alert state is per org as well as per limit. Two orgs on one login each
    /// have their own five-hour window, and crossing 80% in one says nothing
    /// about the other. `scope` is the org uuid, or empty in CLI mode where there
    /// is only ever one set of limits.
    private static func key(_ scope: String, _ id: String) -> String {
        scope.isEmpty ? id : "\(scope)/\(id)"
    }

    /// Which alerts have already fired for one limit within one reset window.
    ///
    /// Persisted, because it is the only thing standing between the user and a
    /// duplicate "at 80%" banner every time the app launches, and with Launch at
    /// Login on that means every login.
    private struct AlertState: Codable {
        /// Identifies the reset window this state describes, so a genuine reset
        /// invalidates it. 0 for limits the API reports without a reset time.
        var window: Double
        var fired: Set<Int>
        var paced: Bool
    }

    private static func stateKey(_ key: String) -> String { "AlertState-\(key)" }

    private static func loadState(_ key: String) -> AlertState? {
        guard let data = UserDefaults.standard.data(forKey: stateKey(key)) else { return nil }
        return try? JSONDecoder().decode(AlertState.self, from: data)
    }

    private static func saveState(_ state: AlertState, for key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey(key))
    }

    /// `orgLabel` prefixes every notification when the login has more than one
    /// org, so "Session (5 h) at 95%" says which org it means.
    func evaluate(
        previous: [UsageLimit], current: [UsageLimit],
        scope: String = "", orgLabel: String? = nil
    ) {
        let prevByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let now = Date()

        for limit in current {
            let k = Self.key(scope, limit.id)
            let old = prevByID[limit.id]?.utilization
            let window = limit.resetsAt?.timeIntervalSince1970 ?? 0
            var state = Self.loadState(k)

            // An unknown window means we were not watching when this one started,
            // so seed the already-crossed thresholds as "fired" WITHOUT notifying.
            // You cannot cross a line the app never saw you cross, which is what
            // stops a relaunch at 85% from re-announcing 80%. On a live reset the
            // utilization has just dropped to ~0, so this seeds nothing.
            if state == nil || state!.window != window {
                state = AlertState(
                    window: window,
                    fired: Set(thresholds.filter { limit.utilization >= $0 }.map(Int.init)),
                    paced: false
                )
                history[k] = []
            }
            var s = state!

            // Fallback for limits reported without a reset time: a big downward
            // move is the only signal that the window rolled over.
            if window == 0, let old, limit.utilization < old - 10 {
                s.fired = []
                s.paced = false
                history[k] = []
            }

            history[k, default: []].append((now, limit.utilization))
            history[k] = history[k]!.suffix(60).filter {
                now.timeIntervalSince($0.0) < 2 * 3600
            }

            checkThresholds(limit, key: k, orgLabel: orgLabel, state: &s)
            updateResetSchedule(limit, key: k, orgLabel: orgLabel)
            checkPace(limit, key: k, orgLabel: orgLabel, now: now, state: &s)

            Self.saveState(s, for: k)
        }
    }

    /// Cancels every scheduled reset alert across all orgs. Used when the pref is
    /// switched off, where cancelling only the active org's would leave the
    /// others to fire days later.
    func cancelAllResetSchedules() {
        guard !scheduledResetIDs.isEmpty else { return }
        NotificationManager.shared.cancel(ids: Array(scheduledResetIDs))
        scheduledResetIDs.removeAll()
    }

    private func title(_ text: String, _ orgLabel: String?) -> String {
        guard let orgLabel, !orgLabel.isEmpty else { return text }
        return "\(orgLabel) · \(text)"
    }

    private func checkThresholds(
        _ limit: UsageLimit, key: String, orgLabel: String?, state: inout AlertState
    ) {
        guard Prefs.notifyThresholds else { return }
        for t in thresholds where limit.utilization >= t {
            if state.fired.insert(Int(t)).inserted {
                let resetInfo = UsageFormat.resetString(limit.resetsAt)
                NotificationManager.shared.post(
                    id: "threshold-\(key)-\(Int(t))-\(Int(Date().timeIntervalSince1970))",
                    title: title("\(limit.label) at \(UsageFormat.percent(limit.utilization))", orgLabel),
                    body: resetInfo.isEmpty ? "Approaching your Claude limit." : resetInfo.capitalized
                )
            }
        }
    }

    /// Keep a notification scheduled for the reset time of any limit that's
    /// meaningfully used. It fires even if the Mac was asleep at reset time.
    private func updateResetSchedule(_ limit: UsageLimit, key: String, orgLabel: String?) {
        let id = "resetsched-\(key)"
        if Prefs.notifyResets, let resets = limit.resetsAt, limit.utilization >= 60 {
            NotificationManager.shared.schedule(
                id: id,
                at: resets.addingTimeInterval(60),
                title: title("\(limit.label) has reset", orgLabel),
                body: "Your Claude usage window renewed. You're back to full capacity."
            )
            scheduledResetIDs.insert(id)
        } else {
            NotificationManager.shared.cancel(ids: [id])
            scheduledResetIDs.remove(id)
        }
    }

    /// Burn-rate projection over the last hour of samples: warn once per window
    /// if 100 % will arrive before the reset does (and within the next hour).
    private func checkPace(
        _ limit: UsageLimit, key: String, orgLabel: String?,
        now: Date, state: inout AlertState
    ) {
        guard Prefs.notifyPace,
              !state.paced,
              limit.utilization >= 50, limit.utilization < 100,
              let samples = history[key]
        else { return }

        let recent = samples.filter { now.timeIntervalSince($0.0) <= 3600 }
        guard let first = recent.first, let last = recent.last else { return }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= 900 else { return } // need ≥15 min of signal

        let rate = (last.1 - first.1) / span // % per second
        guard rate > 0 else { return }
        let secondsTo100 = (100 - last.1) / rate
        guard secondsTo100 < 3600 else { return }

        let hitTime = now.addingTimeInterval(secondsTo100)
        if let resets = limit.resetsAt, hitTime >= resets { return } // reset arrives first

        state.paced = true
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        NotificationManager.shared.post(
            id: "pace-\(key)-\(Int(now.timeIntervalSince1970))",
            title: title("On pace to hit \(limit.label)", orgLabel),
            body: "At the current rate you'll reach 100% around \(f.string(from: hitTime))."
        )
    }
}
