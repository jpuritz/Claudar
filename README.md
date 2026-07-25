# Claudar

> Watch your Claude usage limits from the macOS menu bar, a desktop widget, and
> a status window — the same numbers as Claude Code's `/usage`, always in view.

[![Downloads](https://img.shields.io/github/downloads/jpuritz/Claudar/total?label=downloads&color=brightgreen)](https://github.com/jpuritz/Claudar/releases)
[![Latest release](https://img.shields.io/github/v/release/jpuritz/Claudar)](https://github.com/jpuritz/Claudar/releases/latest)
[![License](https://img.shields.io/github/license/jpuritz/Claudar)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

![Opening Claudar: the ring icon in the menu bar, then the dropdown showing each limit with reset countdowns](docs/demo.gif)

> **Unofficial** — not affiliated with Anthropic. It reads *your* Claude sign-in
> from your Keychain, talks only to Anthropic's servers, and has no telemetry.

**Requires:** macOS 14+, an active Claude subscription, and a way to sign in —
either the [Claude Code CLI](https://code.claude.com) (nothing to set up), or a
one-time claude.ai login via [No-Prompt Mode](#sign-in-and-the-password-prompt)
if you don't use the CLI.

## Install

**Homebrew** (recommended):

```sh
brew install --cask jpuritz/tap/claudar
xattr -dr com.apple.quarantine "/Applications/Claudar.app"
```

**Or** download `Claudar-menubar.zip` from the
[latest release](https://github.com/jpuritz/Claudar/releases/latest),
unzip, drag **Claudar.app** to `/Applications`, then run that same `xattr`
command once.

*(The `xattr` line is needed because the app is ad-hoc signed — it tells
Gatekeeper to trust it. Homebrew used to do this for you via
`--no-quarantine`, but Homebrew 6 removed the flag: passing it now fails with
`invalid option`, and `HOMEBREW_CASK_OPTS=--no-quarantine` no longer works
either, because `brew install` stopped consulting it. Clearing the flag after
installing is the route that actually works.)*

**On first launch**, macOS asks to access *Claude Code-credentials* — click
**Always Allow**. That's how the app reads your usage. No CLI? Skip that prompt
and use **No-Prompt Mode → Sign In to claude.ai…** from the menu instead.

> **Want the desktop widget?** The download and Homebrew builds are the **menu
> bar + window** version. The widget has to be built from source (free, needs
> Xcode) — see [building](docs/TECHNICAL.md#building-from-source).

## Features

- **Menu bar** — a colored ring and your 5-hour session percentage; click for
  every limit with reset countdowns.
- **Desktop widget** — a real WidgetKit widget (small / medium / large) in the
  system widget gallery.
- **Usage window** — the full breakdown in a normal window: resizable, remembers
  its position, and can float on top.
- **Live Claude service status** — a colored line in the menu and a dot on the
  ring when claude.ai, the API, Claude Code, or the Console has an incident.
- **Notifications** — 80% / 95% thresholds, reset alerts, "on pace to run out"
  warnings, and service up/down alerts. Each toggleable.
- **Global shortcut** (⌘⇧C) opens the window from anywhere — no extra permissions.
- **Configurable refresh** (15 s – 2 min), plus an instant refresh on wake.
- **No-Prompt Mode** — sign in to claude.ai once to stop the periodic macOS
  password prompt (see [below](#sign-in-and-the-password-prompt)).

## Screenshots

| Widget | Menu bar | Window |
|---|---|---|
| ![widget](docs/shot-widget.png) | ![menu bar](docs/shot-menubar.png) | ![window](docs/shot-window.png) |

## Menu options

- **Claude service status** — click to open status.claude.com
- **Refresh Now** (⌘R while the menu is open)
- **Usage Window** (⌘W) — show/hide the detail window
- **Keep Window on Top**
- **Notifications** — thresholds, resets, pace warnings, service alerts
- **Refresh Interval** — 15 s / 30 s / 1 min / 2 min
- **Global Shortcut (⌘⇧C)** — off by default
- **No-Prompt Mode** — sign in to claude.ai to stop the password prompt
- **Launch at Login**
- **Quit**

## Sign-in and the password prompt

Out of the box the app uses your **Claude Code CLI** sign-in — nothing to set up.
The one quirk: because it reads a credential that belongs to the CLI, macOS asks
for your password to authorize it, and that authorization gets reset each time
the CLI refreshes its token (a few times a day). So the prompt comes back
periodically. This is macOS protecting the CLI's credential, not a bug.

**To never see that prompt,** turn on **No-Prompt Mode**, which signs in to
claude.ai and stores the session in a Keychain item the app owns:

> Menu → **No-Prompt Mode** → **Sign In to claude.ai…**

A sign-in window opens; log in once and you're done — no DevTools, no terminal.
The app switches over automatically and you can **Turn Off** any time from the
same menu to go back to CLI mode.

The claude.ai session is broader than the CLI token (full session access, sent
only to claude.ai) and expires every few weeks, at which point you sign in again.

<details>
<summary>Prefer to set the cookie by hand?</summary>

Run `./set-cookie.command` from a copy of this repo (it guides you through
copying the Cookie header), or do it directly: copy the `Cookie:` header from
claude.ai's DevTools (Network tab → the `usage` request) and run

```sh
security add-generic-password -U -s "Claudar-cookie" -a "claudar" -w "$(pbpaste)"
```

Remove it with `security delete-generic-password -s "Claudar-cookie"`.

</details>

Full details on both modes are in [docs/TECHNICAL.md](docs/TECHNICAL.md#how-it-fetches-usage).

## More

- **[Technical notes](docs/TECHNICAL.md)** — how it works, privacy, architecture,
  building from source, and the dead ends we hit so you don't repeat them.

## License

[MIT](LICENSE) © Jon Puritz
