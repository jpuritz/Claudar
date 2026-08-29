import Foundation
import Combine
import WidgetKit

@MainActor
final class UsageModel: ObservableObject {
    /// The ACTIVE org's limits. Views bind to this and are unaware of the rest,
    /// which keeps the menu, window, and widget code identical to single-org.
    @Published var limits: [UsageLimit] = []
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var subscription: String?

    /// Every org on the current claude.ai login. Empty in CLI mode, and of
    /// length 1 for almost everyone, in which case no switcher is shown.
    @Published var orgs: [OrgInfo] = []
    /// Latest limits for every org, so the switcher can show each one's session
    /// percentage without making the user switch to find out.
    @Published var orgUsage: [String: [UsageLimit]] = [:]
    private var orgErrors: [String: String] = [:]

    /// Show every org's limits together rather than only the active one. Mirrored
    /// into Prefs on write, and published rather than read straight from Prefs so
    /// that the usage window, whose hosting view outlives the menu, re-renders the
    /// moment it's toggled.
    @Published var showAllOrgs: Bool = Prefs.showAllOrgs {
        didSet { Prefs.showAllOrgs = showAllOrgs }
    }

    /// True when the panel should render org-by-org. One org has nothing to
    /// separate, so the setting is ignored there.
    var showsAllOrgs: Bool { showAllOrgs && orgs.count > 1 }

    /// Limits for one org, for the grouped layout.
    func limits(for orgID: String) -> [UsageLimit] { orgUsage[orgID] ?? [] }

    /// Per-org error, so a group that failed can say so without blanking the rest.
    func error(for orgID: String) -> String? { orgErrors[orgID] }

    private var inFlight = false
    private var nextAttemptAllowed = Date.distantPast
    private var consecutive429s = 0
    /// Guards against re-invoking the CLI in a tight loop if it can't fix things.
    private var lastCLIRefresh = Date.distantPast

    /// What the menu bar shows: the 5-hour session limit, since that's the one
    /// that bites during a working session. Falls back to the highest limit if
    /// the session window isn't in the response.
    var menuBarUtilization: Double? {
        limits.first(where: { $0.id == "five_hour" })?.utilization
            ?? limits.map(\.utilization).max()
    }

    // MARK: - Active org

    private static let activeOrgKey = "ClaudeActiveOrgID"
    private static let orgListKey = "ClaudeOrgList"
    private static let orgListStampKey = "ClaudeOrgListFetchedAt"
    /// Orgs change about never, so the list is cached and only re-read
    /// occasionally. A cookie change clears it outright.
    private static let orgListTTL: TimeInterval = 6 * 3600

    /// The org the menu bar, window, and widget are showing. Falls back to the
    /// first org whenever the stored choice is missing or no longer on the login.
    var activeOrg: OrgInfo? {
        let stored = UserDefaults.standard.string(forKey: Self.activeOrgKey)
        return orgs.first { $0.id == stored } ?? orgs.first
    }

    /// The session percentage for one org, for the switcher rows.
    func sessionPercent(for orgID: String) -> Double? {
        let limits = orgUsage[orgID] ?? []
        return limits.first(where: { $0.id == "five_hour" })?.utilization
            ?? limits.map(\.utilization).max()
    }

    func selectOrg(_ id: String) {
        guard id != activeOrg?.id, orgs.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: Self.activeOrgKey)
        // Swap the visible numbers over at once from what's already cached, then
        // refresh so the new org's data is current.
        applyActiveOrg()
        refresh(force: true)
    }

    /// Points the published, view-facing properties at the active org.
    private func applyActiveOrg(fallbackError: String? = nil) {
        guard let org = activeOrg else { return }
        limits = orgUsage[org.id] ?? []
        subscription = org.plan
        errorMessage = orgErrors[org.id] ?? fallbackError
        publishToWidget(limits)
    }

    func refresh(force: Bool = false) {
        guard !inFlight else { return }
        if !force && Date() < nextAttemptAllowed { return }
        inFlight = true
        Task {
            await self.fetch()
            self.inFlight = false
        }
    }

    /// Hands fresh data to the widget extension. The widget is sandboxed and
    /// can't fetch or reach the Keychain itself, so the app writes a snapshot to
    /// the shared App Group container and asks WidgetKit to reload.
    private func publishToWidget(_ limits: [UsageLimit]) {
        SharedStore.write(UsageSnapshot(
            limits: limits, updated: Date(), subscription: subscription,
            orgName: activeOrg?.name, orgCount: orgs.isEmpty ? nil : orgs.count
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Called when the saved claude.ai cookie is added or removed. A new cookie
    /// may belong to a different org/account, so drop the cached org and plan and
    /// re-fetch immediately.
    func cookieDidChange() {
        UserDefaults.standard.removeObject(forKey: Self.orgIDKey)
        UserDefaults.standard.removeObject(forKey: Self.planKey)
        UserDefaults.standard.removeObject(forKey: Self.orgListKey)
        UserDefaults.standard.removeObject(forKey: Self.orgListStampKey)
        UserDefaults.standard.removeObject(forKey: Self.activeOrgKey)
        orgs = []
        orgUsage = [:]
        orgErrors = [:]
        subscription = nil
        refresh(force: true)
    }

    /// Refresh only if the data is older than `seconds` (used on menu close).
    func refreshIfStale(seconds: TimeInterval) {
        if let updated = lastUpdated, Date().timeIntervalSince(updated) < seconds { return }
        refresh()
    }

    // MARK: - Fetch

    nonisolated private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let preferCurlKey = "PreferCurlTransport"

    /// Off by default. Turn on to log the shape of the usage payload when a limit
    /// you can see in Claude Code doesn't appear here, which is how the `limits`
    /// array was found:
    ///
    ///     defaults write com.jpuritz.claudar LogPayloadShape -bool true
    ///
    /// Logs key paths, numbers, and short strings to
    /// ~/Library/Logs/Claudar-last-error.txt. Long strings are elided so account
    /// identifiers stay out of it.
    static var logsPayloadShape: Bool {
        UserDefaults.standard.bool(forKey: "LogPayloadShape")
    }

    private struct ResolvedToken {
        let token: String
        let isCustom: Bool
        let subscription: String?
    }

    // MARK: - claude.ai cookie mode

    /// Matches a real browser. claude.ai sits behind Cloudflare; requests must
    /// look like a browser AND come from a TLS stack Cloudflare accepts.
    /// URLSession works here where curl and Python get a 403 challenge page —
    /// so cookie mode deliberately never uses the curl fallback.
    nonisolated static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let orgIDKey = "ClaudeOrgID"
    private static let planKey = "ClaudeOrgPlan"

    nonisolated static func browserRequest(_ url: URL, cookie: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 25
        return req
    }

    /// Resolves every org on the login, cached in UserDefaults so the extra
    /// lookup happens rarely rather than on every poll.
    ///
    /// A login can belong to more than one org, and the old code took only the
    /// first, which silently hid the rest. Failure degrades in stages: a stale
    /// cache beats nothing, and the `lastActiveOrg` in the cookie beats that.
    private func resolveOrgs(cookie: String) async -> [OrgInfo] {
        func cached() -> [OrgInfo] {
            guard let data = UserDefaults.standard.data(forKey: Self.orgListKey),
                  let list = try? JSONDecoder().decode([OrgInfo].self, from: data)
            else { return [] }
            return list
        }

        let stamp = UserDefaults.standard.object(forKey: Self.orgListStampKey) as? Date
        let fresh = Date().timeIntervalSince(stamp ?? .distantPast) < Self.orgListTTL
        let cache = cached()
        if fresh, !cache.isEmpty { return cache }

        let req = Self.browserRequest(URL(string: "https://claude.ai/api/organizations")!,
                                      cookie: cookie)
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            let parsed = UsageParser.organizations(from: data)
            if !parsed.isEmpty {
                if let encoded = try? JSONEncoder().encode(parsed) {
                    UserDefaults.standard.set(encoded, forKey: Self.orgListKey)
                    UserDefaults.standard.set(Date(), forKey: Self.orgListStampKey)
                }
                return parsed
            }
        }

        if !cache.isEmpty { return cache }
        if let id = UsageParser.orgID(fromCookie: cookie), !id.isEmpty {
            return [OrgInfo(id: id, name: "Your organization", plan: nil)]
        }
        return []
    }

    /// What one org's usage call produced.
    private enum OrgFetch {
        case success([UsageLimit])
        /// Rate limited. The caller stops immediately: every org shares one host
        /// and one session, so hammering the rest would only dig in deeper.
        case rateLimited(Double?)
        case failure(String)
    }

    private func fetchOrgUsage(_ org: OrgInfo, cookie: String) async -> OrgFetch {
        let url = URL(string: "https://claude.ai/api/organizations/\(org.id)/usage")!
        let req = Self.browserRequest(url, cookie: cookie)

        let data: Data, http: HTTPURLResponse
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard let h = resp as? HTTPURLResponse else {
                return .failure("No response from claude.ai.")
            }
            data = d; http = h
        } catch {
            return .failure("Network error: \(error.localizedDescription)")
        }

        switch http.statusCode {
        case 200:
            if Self.logsPayloadShape {
                Self.appendLog("cookie payload for \(org.name):\n" + UsageParser.debugShape(data))
            }
            let parsed = UsageParser.limits(from: data)
            return parsed.isEmpty
                ? .failure("Usage response had no limit data.")
                : .success(parsed)
        case 401:
            return .failure("claude.ai session expired — sign in again from No-Prompt Mode.")
        case 403:
            // Cloudflare serves an HTML challenge when cf_clearance goes stale.
            // A 403 on one org of several is more likely to mean this login can't
            // read that org's usage at all, which is worth saying plainly.
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            if body.contains("Just a moment") {
                return .failure("Cloudflare challenge — your cf_clearance cookie expired; sign in again.")
            }
            Self.appendLog("cookie mode HTTP 403 for org \(org.id)")
            return .failure("claude.ai won't share usage for \(org.name).")
        case 429:
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            return .rateLimited(ra)
        default:
            Self.appendLog("cookie mode HTTP \(http.statusCode) for org \(org.id)")
            return .failure("claude.ai returned HTTP \(http.statusCode).")
        }
    }

    /// Picks the access token to use, minimizing reads of Claude Code's Keychain
    /// item. Priority:
    ///   1. A user-set long-lived token (`Claudar-token`).
    ///   2. Our own cached copy of the CLI token (`Claudar-session`).
    ///   3. Claude Code's credentials — read once to bootstrap, then cached in (2).
    ///
    /// Why the cache: reading Claude Code's item is a *cross-app* Keychain access,
    /// which macOS gates with an authorization prompt (and re-prompts whenever our
    /// signature changes). Reading our OWN item never prompts. So normal polling
    /// and wake-refreshes read the cache and stay silent; we only touch Claude
    /// Code's item on first launch and after a 401 (see the 401 handler, which
    /// clears the cache so the freshly-renewed credential is re-read).
    ///
    /// We deliberately IGNORE `expiresAt` and use the token until the server
    /// rejects it — the server is the authority, and tokens are often accepted
    /// past their nominal expiry.
    private func resolveToken() async throws -> ResolvedToken {
        // (1) User-set long-lived token.
        if let custom = await Task.detached(priority: .userInitiated, operation: {
            KeychainReader.readCustomToken()
        }).value {
            return ResolvedToken(token: custom, isCustom: true, subscription: nil)
        }

        // (2) Our own cached copy — no authorization prompt.
        if let session = await Task.detached(priority: .userInitiated, operation: {
            KeychainReader.readSession()
        }).value {
            return ResolvedToken(token: session.accessToken, isCustom: false,
                                 subscription: session.subscriptionType)
        }

        // (3) Bootstrap from Claude Code's item (may prompt once), then cache.
        let creds = try await Task.detached(priority: .userInitiated) {
            try KeychainReader.readClaudeCredentials()
        }.value
        KeychainReader.writeSession(
            accessToken: creds.accessToken,
            refreshToken: creds.refreshToken,
            expiresAt: creds.expiresAt ?? .distantFuture,
            subscription: creds.subscriptionType
        )
        return ResolvedToken(token: creds.accessToken, isCustom: false,
                             subscription: creds.subscriptionType)
    }

    /// Triggers the CLI to renew its stored credential, then the app re-reads it.
    ///
    /// The app can't call the OAuth refresh endpoint itself (it blocks non-browser
    /// clients), but the CLI renews the token as a side effect of a real API call
    /// and writes the result back to the Keychain. Note `claude auth status` does
    /// NOT work here: it only reports locally-stored state and never hits the
    /// network. So we make the smallest real call possible (haiku, two-word
    /// prompt, no session file) — a negligible number of tokens, ~3x a day.
    nonisolated private static func runCLIAuthRefresh() async -> Bool {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        guard let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return false }

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = [
                    "-p", "hi",
                    "--model", "haiku",
                    "--no-session-persistence",
                ]
                p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                // Strip nested-session guards so it runs from any context.
                var env = ProcessInfo.processInfo.environment
                for key in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION",
                            "CLAUDE_CODE_SESSION_ACCESS_TOKEN"] {
                    env.removeValue(forKey: key)
                }
                p.environment = env
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                do { try p.run() } catch {
                    cont.resume(returning: false); return
                }
                // Don't let a stalled CLI hang the app.
                DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
                    if p.isRunning { p.terminate() }
                }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    // MARK: - Shared response handling
    //
    // Both transports get the same treatment on success and on 429, so the logic
    // lives here rather than being mirrored in each fetch path.

    /// Commits a successful payload: publishes it, clears backoff, and lets the
    /// alert engine compare it against the previous reading.
    private func applySuccess(_ body: Data) {
        if Self.logsPayloadShape {
            Self.appendLog("bearer payload:\n" + UsageParser.debugShape(body))
        }
        let parsed = UsageParser.limits(from: body)
        guard !parsed.isEmpty else {
            errorMessage = "Usage response had no limit data."
            return
        }
        let previous = limits
        limits = parsed
        lastUpdated = Date()
        errorMessage = nil
        consecutive429s = 0
        nextAttemptAllowed = .distantPast
        AlertEngine.shared.evaluate(previous: previous, current: parsed)
        publishToWidget(parsed)
    }

    /// Exponential backoff: 5, 10, 20, 40, 60, 60… minutes, or the server's
    /// `Retry-After` if that's longer.
    private func applyBackoff(retryAfter: Double?, source: String) {
        consecutive429s += 1
        var delay = min(3600.0, 300.0 * pow(2, Double(consecutive429s - 1)))
        if let retryAfter { delay = max(delay, retryAfter) }
        nextAttemptAllowed = Date(timeIntervalSinceNow: delay)
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        errorMessage = "Rate limited (\(source)) — retrying after \(f.string(from: nextAttemptAllowed))."
    }

    private func fetch() async {
        // Cookie mode takes priority: it reads only Keychain items this app owns,
        // so it never triggers an authorization prompt.
        if let cookie = await Task.detached(priority: .userInitiated, operation: {
            KeychainReader.readCookie()
        }).value {
            await fetchViaCookie(cookie)
            return
        }
        await fetchViaBearer()
    }

    /// claude.ai path. Same limit fields as the OAuth endpoint, so the parser is
    /// shared. Every org is polled each cycle, because notifications for an org
    /// you aren't currently looking at are the main reason to have more than one.
    private func fetchViaCookie(_ cookie: String) async {
        let resolved = await resolveOrgs(cookie: cookie)
        guard !resolved.isEmpty else {
            errorMessage = "Couldn't determine your organization from the saved cookie."
            return
        }
        orgs = resolved
        let multi = resolved.count > 1

        var anySucceeded = false
        var firstError: String?
        var throttled: (hit: Bool, retryAfter: Double?) = (false, nil)

        for org in resolved {
            switch await fetchOrgUsage(org, cookie: cookie) {
            case .success(let limits):
                anySucceeded = true
                let previous = orgUsage[org.id] ?? []
                orgUsage[org.id] = limits
                orgErrors[org.id] = nil
                AlertEngine.shared.evaluate(
                    previous: previous, current: limits,
                    scope: org.id, orgLabel: multi ? org.name : nil
                )
            case .rateLimited(let retryAfter):
                // Every org shares one host and one session, so once we're
                // throttled the rest of the loop would only dig in deeper. Stop,
                // but keep whatever already came back this cycle.
                throttled = (true, retryAfter)
            case .failure(let message):
                orgErrors[org.id] = message
                if firstError == nil { firstError = message }
            }
            if throttled.hit { break }
        }

        if anySucceeded {
            lastUpdated = Date()
            if !throttled.hit {
                consecutive429s = 0
                nextAttemptAllowed = .distantPast
            }
        }
        if throttled.hit {
            applyBackoff(retryAfter: throttled.retryAfter, source: "claude.ai")
            // applyBackoff owns errorMessage here; don't let the active org
            // overwrite it with a stale per-org message.
            let saved = errorMessage
            applyActiveOrg()
            errorMessage = saved
        } else {
            applyActiveOrg(fallbackError: anySucceeded ? nil : firstError)
        }
    }

    private func fetchViaBearer() async {
        // CLI mode has no org concept: the token itself picks the account. Drop
        // any org list left over from cookie mode so nothing gets mislabelled.
        if !orgs.isEmpty {
            orgs = []
            orgUsage = [:]
            orgErrors = [:]
        }
        let accessToken: String
        var usingCustomToken = false
        do {
            let resolved = try await resolveToken()
            accessToken = resolved.token
            usingCustomToken = resolved.isCustom
            subscription = resolved.subscription
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let creds = OAuthCredentials(
            accessToken: accessToken, refreshToken: nil, expiresAt: nil, subscriptionType: subscription
        )

        var status: Int?
        var body = Data()
        var retryAfter: Double?
        var transport = "urlsession"

        // If curl previously succeeded where URLSession was blocked, lead with curl.
        if UserDefaults.standard.bool(forKey: Self.preferCurlKey),
           let r = await Self.curlFetch(token: creds.accessToken) {
            (status, body) = r
            transport = "curl"
        }

        if status == nil {
            var request = URLRequest(url: Self.endpoint)
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return }
                status = http.statusCode
                body = data
                if let ra = http.value(forHTTPHeaderField: "Retry-After") {
                    retryAfter = Double(ra)
                }
            } catch {
                errorMessage = "Network error: \(error.localizedDescription)"
                return
            }

            // URLSession blocked? Try once through curl — a different TLS stack,
            // in case the edge is fingerprinting the client.
            if status == 429, let alt = await Self.curlFetch(token: creds.accessToken) {
                Self.appendLog("URLSession got 429; curl attempt returned \(alt.0)")
                if alt.0 == 200 {
                    (status, body) = alt
                    transport = "curl"
                    retryAfter = nil
                    UserDefaults.standard.set(true, forKey: Self.preferCurlKey)
                }
            }
        }

        guard let status else {
            errorMessage = "Request failed with no response."
            return
        }

        switch status {
        case 200:
            applySuccess(body)
        case 401, 403:
            if usingCustomToken {
                errorMessage = "Long-lived token rejected — remove the Claudar-token Keychain item to fall back."
            } else if Date().timeIntervalSince(lastCLIRefresh) > 300,
                      await Self.runCLIAuthRefresh() {
                // Our cached token was rejected. The CLI owns this credential's
                // lifecycle and can reach the refresh endpoint (which blocks this
                // app directly), so it just renewed Claude Code's item. Drop our
                // stale cache so the retry re-reads and re-caches the fresh token.
                KeychainReader.clearSession()
                Self.appendLog("401 → triggered CLI to renew credential.")
                // Retry inline rather than via refresh(): we are still inside the
                // in-flight fetch, so refresh() would be dropped by its own
                // re-entrancy guard and the recovery would wait for the next poll.
                // Stamping lastCLIRefresh *before* recursing bounds this to one
                // extra attempt — a second 401 fails the 5-minute check and falls
                // through to the message below.
                lastCLIRefresh = Date()
                await fetchViaBearer()
            } else {
                errorMessage = "Sign-in expired — run `claude` in Terminal, then /login."
            }
        case 429:
            applyBackoff(retryAfter: retryAfter, source: "via \(transport)")
            let raText = retryAfter.map { String(Int($0)) } ?? "none"
            let bodyText = String(data: body.prefix(500), encoding: .utf8) ?? ""
            Self.appendLog("HTTP 429 via \(transport), retry-after header: \(raText)\n\(bodyText)")
        default:
            errorMessage = "Usage endpoint returned HTTP \(status)."
            Self.appendLog("HTTP \(status) via \(transport)\n\(String(data: body.prefix(1000), encoding: .utf8) ?? "<non-UTF8>")")
        }
    }

    /// Fetches via /usr/bin/curl. Headers go through stdin (never argv, so the
    /// token is not visible in the process list). Returns (status, body).
    nonisolated private static func curlFetch(token: String) async -> (Int, Data)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                // --http1.1 + axios-style Accept headers: mirror the Claude Code
                // CLI's request shape exactly (Node speaks HTTP/1.1; the edge
                // appears to classify clients partly on this).
                p.arguments = [
                    "-s", "-m", "20", "--http1.1", "--compressed",
                    "-H", "@-",
                    "-w", "\nHTTPSTATUS:%{http_code}",
                    endpoint.absoluteString,
                ]
                let stdin = Pipe(), stdout = Pipe()
                p.standardInput = stdin
                p.standardOutput = stdout
                p.standardError = Pipe()
                do { try p.run() } catch {
                    cont.resume(returning: nil)
                    return
                }
                let headers = """
                Authorization: Bearer \(token)
                anthropic-beta: oauth-2025-04-20
                Content-Type: application/json
                User-Agent: \(userAgent)
                Accept: application/json, text/plain, */*
                """
                stdin.fileHandleForWriting.write(headers.data(using: .utf8)!)
                stdin.fileHandleForWriting.closeFile()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard let s = String(data: out, encoding: .utf8),
                      let marker = s.range(of: "\nHTTPSTATUS:", options: .backwards),
                      let code = Int(s[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)),
                      code > 0
                else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: (code, Data(s[..<marker.lowerBound].utf8)))
            }
        }
    }

    /// Matches the User-Agent the Claude Code CLI sends ("claude-code/<version>") —
    /// the usage endpoint rejects unrecognized user agents. Reads the installed CLI
    /// version from the ~/.local/bin/claude symlink when possible.
    nonisolated static let userAgent: String = {
        let fallback = "claude-code/2.1.63"
        let link = NSHomeDirectory() + "/.local/bin/claude"
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            return fallback
        }
        let version = (dest as NSString).lastPathComponent
        let looksLikeVersion = version.range(
            of: #"^\d+\.\d+\.\d+"#, options: .regularExpression
        ) != nil
        return looksLikeVersion ? "claude-code/\(version)" : fallback
    }()

    /// Appends diagnostics to ~/Library/Logs (kept under ~100 KB).
    nonisolated static func appendLog(_ message: String) {
        let path = NSHomeDirectory() + "/Library/Logs/Claudar-last-error.txt"
        var existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if existing.count > 100_000 { existing = String(existing.suffix(50_000)) }
        let text = existing + "[\(Date())] \(message)\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

}
