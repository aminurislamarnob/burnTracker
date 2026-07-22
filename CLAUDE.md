# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `open BurnTracker.xcodeproj` — open the project in Xcode
- `xcodebuild -project BurnTracker.xcodeproj -scheme BurnTracker -configuration Debug -destination 'platform=macOS' build` — build from the CLI
- Run from Xcode (⌘R), or launch the built `BurnTracker.app` from `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/`

Requires Xcode 16+ (the project uses a file-system-synchronized group). Deployment target is macOS 13.0; Swift language mode 5. There is no test suite or linter. The app runs as a menu-bar accessory (no Dock icon); quit it from the in-app power button (top-right) or Activity Monitor.

## Project layout

The Xcode project and its source folder both live at the repo root. The project uses a **file-system-synchronized group** (`PBXFileSystemSynchronizedRootGroup`, `path = BurnTracker`), so every file under `BurnTracker/` is compiled/bundled automatically — **no need to edit `project.pbxproj` when adding a source file**, just drop it in the folder. Conversely, do not place loose source at the repo root; only `BurnTracker/` is a target member.

```
BurnTracker.xcodeproj/           the Xcode project
BurnTracker/
  BurnTrackerApp.swift           @main App: MenuBarExtra(.window) + .accessory activation policy
  AppState.swift                 @MainActor ObservableObject — all view state + coordination
  Theme.swift                    color/design tokens
  Models/                        Account, QuotaData, AntigravityData, TrackerSettings
  Services/                      ClaudeService, AntigravityService, GeminiService, CliQuotaSupport,
                                 Persistence, FileWatcher, NotificationManager, SessionAutomation
  Views/                         RootView, DashboardView, AccountCardView, CliQuotaCardView,
                                 SettingsView, Components
  Utilities/TimeFormat.swift
  Assets.xcassets               AppIcon, MenuBarIcon (template), AppIconImage
assets/  AppIcon.iconset/         icon sources (also used by the landing page)
landing/                          marketing site (deployed via .github/workflows)
```

## Architecture

A native SwiftUI macOS **menu-bar app** that displays Claude.ai usage quotas for multiple accounts, plus two **separate** CLI quota cards — Antigravity and Gemini CLI — each an independent provider with its own source, sync, and link/unlink. (Migrated from an Electron app; the JS/IPC layers no longer exist.)

- **`BurnTrackerApp.swift`** — the `@main` scene is a single `MenuBarExtra` with `.menuBarExtraStyle(.window)` (a popover-style window). An `NSApplicationDelegateAdaptor` sets `NSApp.setActivationPolicy(.accessory)` so there is no Dock icon, and calls `AppState.shared.onLaunch()` at startup so watchers/timer run before the popover is ever opened.
- **`AppState`** (`@MainActor final class … ObservableObject`, singleton `AppState.shared`) — the single source of view state (`accounts`, `agAccount`, `geminiAccount`, `activeView`, `globalStatus`, `refreshMinutes`, `alertThreshold`) and all coordination logic. Views observe it via `@EnvironmentObject`.
- **Services** are stateless enums/classes with `async` methods. There is no IPC boundary — networking, filesystem, and process calls run directly (no CORS/cookie restrictions to work around).

### Data flow & live quota fetching

The live quota path is the core feature. `ClaudeService.fetchLiveLimits(sessionKey:)` (port of the original `main.js` handler):
1. GET `https://claude.ai/api/organizations` with `Cookie: sessionKey=…` (via an ephemeral `URLSession` that does **not** manage cookies, so the manual header is sent verbatim) to resolve the first org's `uuid`.
2. GET `https://claude.ai/api/organizations/{orgId}/usage` for the rate-limit payload.

`QuotaData`/`UsageWindow` decoding normalizes both snake_case and camelCase shapes (`five_hour`/`fiveHour`, `seven_day`/`sevenDay`, `resets_at`/`resetsAt`) via custom `init(from:)` — **preserve this dual handling** when touching quota parsing, as the upstream private API field naming is not guaranteed. Accounts are fetched concurrently (`withTaskGroup`); a failed/expired key sets only that account's `status` to `.error`, and `globalStatus` aggregates to `.online`/`.warning`/`.error`.

Services return `Result`/optionals rather than throwing across a boundary; `AppState` branches on success and updates the matching account by `id`.

### Antigravity & Gemini CLI quota (two separate providers)

Antigravity (the IDE) and the Gemini CLI are tracked **independently** — each has its own linked account (`agAccount` / `geminiAccount`), its own card, and its own refresh. The two originally-combined fetch strategies are now split one-per-provider:
1. **`AntigravityService.fetchQuota()`** — runs `lsof` to find the Antigravity language-server port, then POSTs to `https://127.0.0.1:{port}/…/RetrieveUserQuotaSummary`. A scoped `URLSessionDelegate` (in `CliQuotaSupport`) trusts the self-signed cert **for 127.0.0.1 only**.
2. **`GeminiService.fetchQuota()`** — reads `~/.gemini/oauth_creds.json`, decodes the `id_token` JWT for the client id, refreshes the token against the embedded (base64-obfuscated) Google OAuth client secrets, and POSTs to the Cloud Code `retrieveUserQuota` API.

`CliQuotaSupport` holds everything both providers share: paths, email resolution, JWT/OAuth handling, the localhost-trust delegate, and the bucket parsers. Each provider still surfaces the same two model-family groups internally (**Gemini** and **Claude & GPT**), rendered by the shared `CliQuotaCardView`. The bucket-selection heuristics (weekly vs 5-hour, gemini vs claude/gpt) are load-bearing and undocumented — port them verbatim if refactoring.

### Persistence

State is stored as JSON in `~/.claude/tracker-settings.json` (`Persistence.swift`), the **same file and shape** as the original Electron build (drop-in compatible):
- `accounts` — `{ id, label, sessionKey }`. Transient runtime fields (`status`, `quota`, `lastFetchTime`, `alertedHighUsage`) are stripped before writing in `AppState.saveToDisk()`.
- `agAccount` (Antigravity) and `geminiAccount` (Gemini CLI) — each `{ token, email }`; plus `refreshMinutes` and `alertThreshold`. Legacy files with only `agAccount` still load (Antigravity); `geminiAccount` starts unlinked until the user links it.

**Session keys are stored in plaintext** on disk — keep them local, never log them, and never transmit them anywhere except Claude.ai.

### Refresh triggers

`AppState.refreshAll()` re-syncs everything and is driven by three sources:
- **Popover shown** — `RootView.onAppear` → `onPopoverAppear()` (the `window-shown` equivalent, instant foreground sync).
- **File watchers** — `FileWatcher` on `history.jsonl`/`stats-cache.json` in `~/.claude`, debounced 500ms. Watchers re-arm themselves on atomic replace (rename/delete invalidates the inode watch).
- **Background timer** — a repeating `Timer` firing every `refreshMinutes` minutes; keeps running while the popover is closed.

### Notifications & session automation

- `NotificationManager` (`UNUserNotificationCenter`) fires an **edge-triggered** alert once when a provider's 5-hour usage first crosses `alertThreshold`, re-arming only after it drops back below. This covers **all providers**: Claude accounts (`checkSessionUsageAlert`, using session utilization) and the CLI providers (`checkCliUsageAlert`, which converts each provider's *remaining* 5-hour fraction into usage = 100 − lowest-remaining lane). `alertThreshold` and `refreshMinutes` are **app-wide** settings (the "General" card in Settings), not Claude-scoped — the background timer's `refreshAll()` likewise re-syncs every provider.
- `SessionWindowController` (`SessionAutomation.swift`) opens claude.ai in a `WKWebView`, injects the account's `sessionKey` cookie, then types + sends a prompt via JS. This is the most fragile part: WKWebView has no native `insertText`, so it relies on `execCommand`/input events driving ProseMirror. If claude.ai's editor stops accepting synthetic input, fall back to opening the URL in the default browser.
