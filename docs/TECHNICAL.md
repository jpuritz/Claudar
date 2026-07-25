# Claudar technical notes

Internals, design decisions, and dead ends. For install and everyday use, see
the [README](../README.md).

## How it fetches usage

The app polls your usage every 30 seconds (configurable 15 s to 2 min), with
`Retry-After`-aware exponential backoff on 429s. It has two authentication modes.

### Mode 1: Claude Code CLI (default)

Reads the OAuth token Claude Code stores in your login Keychain
(`Claude Code-credentials`) and calls `api.anthropic.com/api/oauth/usage`, the
same undocumented endpoint behind Claude Code's `/usage`.

It identifies itself as `claude-code/<version>` because that endpoint rejects
unrecognized User-Agents. Because the endpoint is undocumented, Anthropic can
change or remove it at any time, which would break the app.

**Why it prompts for your password.** That Keychain item belongs to *another
app*, so macOS gates each read with an authorization prompt. Clicking "Always
Allow" grants access, but the grant is tied to the item's access-control list,
and the CLI **rewrites that item every time it renews the token** (~every 8
hours), which resets the ACL and wipes your grant. So the prompt returns a few
times a day, usually noticed after an overnight sleep. Nothing in the app can
prevent it. macOS is guarding another app's credential, and a paid Developer ID
signature wouldn't change that. Mode 2 exists to sidestep the whole thing.

**Keeping you signed in.** Access tokens last ~8 hours. The app can't refresh
them directly (see dead ends), but a real CLI call does, so on a 401 it runs a
tiny `claude -p "hi" --model haiku --no-session-persistence`, which makes the
CLI renew the Keychain token, then retries. This fires ~3×/day for a negligible
number of tokens (rate-limited to one call per 5 minutes). Only if that fails
does it ask you to run `claude` → `/login`.

**Reducing prompts.** The app caches the token it reads into its *own* Keychain
item (`Claudar-session`) and reads from there on normal polls and on wake.
Reading your own item never prompts. It only touches Claude Code's item on first
launch and after a 401. That removes the wake-from-short-sleep prompt, though
not the renewal prompt (a long sleep expires the cached token, forcing a re-read
of Claude Code's freshly-rewritten item).

### Mode 2: claude.ai session cookie

Reads a claude.ai session cookie from `Claudar-cookie`, a Keychain item this app
**owns**, so reading it never prompts. It then calls
`claude.ai/api/organizations/<org>/usage`. That response carries the same limit
fields (`five_hour`, `seven_day`, `extra_usage`, …), so the parser is shared.

Claudar gets the cookie from an embedded `WKWebView` sign-in (menu → No-Prompt
Mode → Sign In). The WebView is given the same `User-Agent` as the fetch, so the
`cf_clearance` cookie it earns from Cloudflare stays valid for the later
`URLSession` requests. cf_clearance is UA-bound, so a mismatch would 403.
On success the app harvests all `claude.ai` cookies from the WebView's store and
writes them to the Keychain. (A manual path via `set-cookie.command` also exists.)

- The org UUID comes from the cookie's `lastActiveOrg`, with a
  `/api/organizations` lookup as fallback. Org and plan are cached in
  UserDefaults, so the extra lookup happens at most once.
- The plan badge (Pro / Max / Team / Enterprise) is derived from the org's
  `capabilities` array.
- **Cloudflare:** claude.ai sits behind Cloudflare, which serves a challenge page
  (HTTP 403 "Just a moment…") to non-browser clients. `URLSession` passes;
  `curl` and Python both fail. So cookie mode always uses `URLSession` and never
  the curl fallback that Mode 1 has.

**Tradeoff:** the cookie is broader than the usage-scoped OAuth token (full
claude.ai session access) and expires every few weeks-to-months, so you re-paste
occasionally. In exchange, zero Keychain prompts. It's sent only to `claude.ai`.

## Privacy

No telemetry and no third-party network calls. The app reads credentials from
the Keychain, never writes back to Claude Code's item, and sends them only to
`api.anthropic.com` (Mode 1) or `claude.ai` (Mode 2). The credential-handling
code is in [Sources/Keychain.swift](../Sources/Keychain.swift) and
[Sources/UsageModel.swift](../Sources/UsageModel.swift).

## Approaches that do NOT work

Documented so you don't repeat them:

- **Calling the OAuth refresh endpoint from the app.**
  `platform.claude.com/v1/oauth/token` returns a persistent 429 to non-browser
  clients. It never clears, identically via `URLSession` and `curl` (with or
  without HTTP/1.1). That's bot protection wearing a rate limit's status code.
- **`claude auth status`.** Reports only locally-stored state and never hits the
  network. Returns `loggedIn: true` even when the stored token is long dead.
- **`claude setup-token` long-lived tokens.** They're scoped for the Anthropic
  API, so `/oauth/usage` rejects them with 401. (A token placed in a
  `Claudar-token` Keychain item is still preferred if present, though it isn't a
  working path today.)
- **A paid Developer ID signature to stop the prompt.** The prompt comes from
  the CLI rewriting its own Keychain item's ACL, independent of how this app is
  signed. Signing doesn't help.
- **Timezone gotcha when debugging:** the Keychain's `expiresAt` is a Unix
  timestamp most tooling renders in *local* time. Print both zones when comparing
  against expiry, or you'll chase failures that haven't happened yet.

## Architecture

```
Sources/   host app (menu bar, window, fetching, notifications, status)
Widget/    WidgetKit extension
Shared/    model, parsing, and formatting compiled into BOTH targets
Config/    Info.plists and entitlements
Tests/     unit tests over Shared/ (SwiftPM; not part of the release build)
```

The host app is deliberately **not sandboxed**: it reads the Claude Code
Keychain item and spawns the `claude` CLI, neither of which a sandboxed process
can do. Widget extensions *must* be sandboxed. So the two can't share memory or
arbitrary files. The app writes a JSON snapshot into the shared App Group
container and calls `WidgetCenter.reloadAllTimelines()`; the widget only ever
reads that snapshot and never touches your credentials.

The app pushes a widget reload on every poll, but macOS throttles and coalesces
widget refreshes on its own schedule, so in practice the widget updates less
often than the menu bar. Every widget view shows an "updated Xm ago" stamp
rather than implying the number is live. The menu bar, drawn directly by the
app, tracks the full poll cadence.

Clicking the widget opens `claudar://window`, which the app handles by showing
the usage window. The scheme is registered in both Info.plists and the URL is
defined once in `Shared/` (`ClaudarURL`), so the widget and the handler cannot
disagree. Without it a click would be a dead end: the app is an `LSUIElement`
accessory, so simply activating it puts nothing on screen.

Other details:

- Colors: green < 50%, yellow < 75%, orange < 90%, red ≥ 90%. Defined once, in
  `Severity` (`Shared/UsageShared.swift`), which vends both a SwiftUI `Color`
  and an `NSColor` from the same RGB triple. The menu bar ring and the panel
  bars used to carry separate palettes and never quite matched.
- Notification state (which thresholds have fired, whether a pace warning went
  out) is persisted per limit, keyed on the limit's `resets_at`. A window the
  app has no record of seeds its already-crossed thresholds *without* notifying:
  you cannot cross a line the app never watched you cross. That is what stops a
  relaunch at 85% (every login, with Launch at Login on) from re-announcing 80%.
  A genuine reset changes `resets_at` and clears the state.
- The menu bar and widget headline show the **5-hour session** limit (the one
  that bites mid-session), falling back to the highest limit if absent. The menu,
  window, and medium/large widgets list every limit.
- The usage parser is generic: any new limit Anthropic adds appears
  automatically, no code change needed.

## Building from source

Two paths, depending on whether you want the WidgetKit widget.

### With the widget (needs Xcode)

```sh
brew install xcodegen
./build-widget.sh          # builds app + widget, installs to /Applications
```

First time only, before that script will succeed:

1. Install **Xcode** (not just Command Line Tools) and point the tools at it:
   `sudo xcode-select -s /Applications/Xcode.app`
2. **Xcode ▸ Settings ▸ Accounts ▸ "+" ▸ Apple ID** and sign in. A *free* Apple ID
   works; no paid developer account.
3. Generate and open the project, then pick your Team:
   ```sh
   xcodegen generate && open Claudar.xcodeproj
   ```
   Select the **Claudar** target ▸ Signing & Capabilities ▸ **Team**, then do
   the same for the **ClaudarWidget** target. Xcode creates your development
   certificate at that moment.
4. Run `./build-widget.sh`. From here on it's fully command-line: it finds your
   team automatically.

Then add the widget: right-click the desktop ▸ **Edit Widgets** ▸ search
"Claudar" ▸ drag out the size you want.

You need the Apple ID because the app and widget are separate processes that
share data through an **App Group**, and that entitlement can't be ad-hoc signed.
The Xcode project is generated from [`project.yml`](../project.yml) by XcodeGen,
so edit that rather than the `.xcodeproj` (which is gitignored).

<details>
<summary>Widget build troubleshooting</summary>

- *"has entitlements that require signing with a development certificate"*: no
  Team selected yet; do step 3 above.
- *"invalid or unsupported format for signature"*: stale build artifacts. Run
  `rm -rf build/dd` and rebuild.
- *Widget doesn't appear in the gallery*: it's registered from the installed
  copy, so the app must be in `/Applications`. Confirm with
  `pluginkit -mv -p com.apple.widgetkit-extension | grep claude`.
- *Widget shows old data*: make sure only the `/Applications` copy is running.
  An ad-hoc `build.sh` copy in `~/Applications` can't write the shared snapshot.

</details>

### Without the widget (Command Line Tools only)

No Xcode, no Apple ID. Menu bar and usage window work fully; there's just no
widget.

```sh
./build.sh              # ad-hoc signed, installs to ~/Applications
./build.sh --package    # …and also produces build/Claudar-menubar.zip
```

This is what the published release contains.

## Tests

```sh
swift test
```

`Package.swift` exists **only** for this: it exposes `Shared/` as a library so
the pure code can be tested without launching an app. It is not part of either
build path above. XcodeGen and `build.sh` compile `Shared/*.swift` straight into
their targets.

The coverage is deliberately narrow, aimed at the code most exposed to somebody
else's decisions: the usage parser (undocumented payload, could change shape
without warning), the org/plan extraction from a cookie, the reset/staleness
formatting, and the severity thresholds. Networking, Keychain access, and the
AppKit surface stay uncovered; they need a signed, running app.
