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
  Models/                        Account, QuotaData, AntigravityData, CommandCodeData,
                                 PinnedProvider, TrackerSettings
  Services/                      ClaudeService, AntigravityService, GeminiService, CommandCodeService,
                                 CliQuotaSupport, Persistence, FileWatcher, NotificationManager,
                                 SessionAutomation
  Views/                         RootView, DashboardView, AccountCardView, CliQuotaCardView,
                                 CommandCodeCardView, MenuBarLabel, SettingsView, Components
  Utilities/TimeFormat.swift
  Assets.xcassets               AppIcon, MenuBarIcon (template), AppIconImage
assets/  AppIcon.iconset/         icon sources (also used by the landing page)
landing/                          marketing site (deployed via .github/workflows)
```

## Architecture

A native SwiftUI macOS **menu-bar app** that displays Claude.ai usage quotas for multiple accounts, plus three **separate** CLI quota cards — Antigravity, Gemini CLI, and Command Code — each an independent provider with its own source, sync, and link/unlink. (Migrated from an Electron app; the JS/IPC layers no longer exist.)

- **`BurnTrackerApp.swift`** — the `@main` scene is a single `MenuBarExtra` with `.menuBarExtraStyle(.window)` (a popover-style window). An `NSApplicationDelegateAdaptor` sets `NSApp.setActivationPolicy(.accessory)` so there is no Dock icon, and calls `AppState.shared.onLaunch()` at startup so watchers/timer run before the popover is ever opened. It holds `AppState.shared` as an `@ObservedObject` so the menu-bar label redraws when the pinned provider's usage changes.

### Menu-bar pin

The user can pin **one** provider (`PinnedProvider`: a Claude account by id, or Gemini / Antigravity / Command Code) so the menu bar shows its current 5-hour usage next to the glyph. `AppState.togglePin` sets or clears the single `pinnedProvider`, so one-at-a-time is a property of the model rather than UI bookkeeping; `pinnedSummary` resolves it to a label + percentage.

Each provider reports "5-hour usage" differently: Claude uses `sessionUtilization`, Gemini/Antigravity reuse `fiveHourUsedPct` (100 − lowest remaining lane), and Command Code uses its 5-hour window — **falling back to `creditsUsedPct`** for plans with no request window (`limited: false`), which otherwise have no 5-hour signal at all.

`MenuBarLabel.image(for:)` composites the glyph and text into a **single** template `NSImage`. This is deliberate: `MenuBarExtra`'s label does not reliably lay out a multi-view hierarchy, so drawing one image keeps the result predictable while `isTemplate = true` preserves light/dark menu-bar recoloring.

The pin is persisted as a flat token string (`pinnedProvider`, e.g. `"claude:acc_123"`) and is **self-healing**: `prunePinIfDangling()` runs on load and after every account removal/unlink, so a pin pointing at a provider that no longer exists can never leave a stale reading in the menu bar.
- **`AppState`** (`@MainActor final class … ObservableObject`, singleton `AppState.shared`) — the single source of view state (`accounts`, `agAccount`, `geminiAccount`, `commandCodeAccount`, `pinnedProvider`, `activeView`, `globalStatus`, `refreshMinutes`, `alertThreshold`) and all coordination logic. Views observe it via `@EnvironmentObject`.
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

### Command Code quota (a third, differently-shaped provider)

Command Code (the `cmd` CLI) is tracked independently via `commandCodeAccount`. It does **not** reuse `AGGroup`/`CliQuotaCardView`, because its quota model is different: it bills in **credits** (dollars against a monthly plan allowance), with optional 5-hour/weekly *request* windows on top. Hence its own `CommandCodeData` model and `CommandCodeCardView`.

`CommandCodeService.fetchQuota()` reads the API key from `~/.commandcode/auth.json` and calls `https://api.commandcode.ai` with `Authorization: Bearer …`, mirroring the CLI's own `fetchUsageData` sequence: `/alpha/whoami` (email + org id) → `/alpha/billing/credits` + `/alpha/billing/subscriptions` in parallel → `/alpha/usage/summary?since={currentPeriodStart}`. The `orgId` param is omitted for personal accounts (`org: null`).

Two things are **ports of the CLI's internals and must be kept in step** with it:
- The per-plan monthly allowance table (`individual-go` = 10, `individual-pro` = 30, `individual-provider` = 15, `individual-max` = 150, `individual-ultra` = 300, `teams-pro` = 40) and the friendly names — the API returns a `planId` but never the allowance, so the pool is derived locally by longest-prefix match.
- The credit projection in `project(...)`, a port of the CLI's `projectUsageView`. In particular the pool is `max(planAllowance, monthlyRemaining) + purchased + free` **only while the subscription is active**, else `spent + remaining`; that `max` is what makes the reported percentage match `cmd`'s own `/usage` view.

`windowLimits` reports `used`/`cap` (absolute *usage*, unlike the other CLI providers' remaining fractions) and `resetAt` as **epoch milliseconds**, where `0` means the window has not started. `limited: false` means the plan enforces no request windows at all, and both lanes are dropped.

The API key is **read fresh from `~/.commandcode/auth.json` on every fetch** and never copied into `tracker-settings.json` (which stores only the `"local-creds"` placeholder, as Antigravity/Gemini do) — so re-running `cmd login` is picked up automatically and the secret lives in exactly one place.

### Persistence

State is stored as JSON in `~/.claude/tracker-settings.json` (`Persistence.swift`), the **same file and shape** as the original Electron build (drop-in compatible):
- `accounts` — `{ id, label, sessionKey }`. Transient runtime fields (`status`, `quota`, `lastFetchTime`, `alertedHighUsage`) are stripped before writing in `AppState.saveToDisk()`.
- `agAccount` (Antigravity), `geminiAccount` (Gemini CLI), and `commandCodeAccount` (Command Code) — each `{ token, email }`; plus `refreshMinutes` and `alertThreshold`. Every provider key is decoded optionally, so legacy files (e.g. with only `agAccount`) still load and the missing providers simply start unlinked. `pinnedProvider` (the menu-bar pin token) is likewise optional.

**Session keys are stored in plaintext** on disk — keep them local, never log them, and never transmit them anywhere except Claude.ai.

### Refresh triggers

`AppState.refreshAll()` re-syncs everything and is driven by three sources:
- **Popover shown** — `RootView.onAppear` → `onPopoverAppear()` (the `window-shown` equivalent, instant foreground sync).
- **File watchers** — `FileWatcher` on `history.jsonl`/`stats-cache.json` in `~/.claude`, debounced 500ms. Watchers re-arm themselves on atomic replace (rename/delete invalidates the inode watch).
- **Background timer** — a repeating `Timer` firing every `refreshMinutes` minutes; keeps running while the popover is closed.

### Notifications & session automation

- `NotificationManager` (`UNUserNotificationCenter`) fires an **edge-triggered** alert once when a provider's 5-hour usage first crosses `alertThreshold`, re-arming only after it drops back below. This covers **all providers**: Claude accounts (`checkSessionUsageAlert`, using session utilization), Antigravity/Gemini (`checkCliUsageAlert`, which converts each provider's *remaining* 5-hour fraction into usage = 100 − lowest-remaining lane), and Command Code (`checkCommandCodeUsageAlert`, whose 5-hour window is already expressed as usage; plans with no window are skipped). `alertThreshold` and `refreshMinutes` are **app-wide** settings (the "General" card in Settings), not Claude-scoped — the background timer's `refreshAll()` likewise re-syncs every provider.
- `SessionWindowController` (`SessionAutomation.swift`) opens `claude.ai/new` in a `WKWebView` with the account's `sessionKey` cookie injected into an isolated (non-persistent) data store. It only opens the chat, ready for input — the user types and sends their own message (no prompt automation). The earlier synthetic-input path (ProseMirror `execCommand`/input events to auto-send a prompt) was removed as unreliable.
