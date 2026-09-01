import Foundation
import SwiftUI
import Combine

enum ActiveView {
    case dashboard
    case settings
}

/// Single source of view state (mirrors the original `appState` object) plus
/// the coordination logic from `src/renderer.js`. All UI state lives here.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var activeView: ActiveView = .dashboard
    @Published var accounts: [Account] = []
    @Published var agAccount: CliAccount?
    @Published var geminiAccount: CliAccount?
    @Published var commandCodeAccount: CommandCodeAccount?
    @Published var globalStatus: GlobalStatus = .offline
    /// CLI-wide Claude Code usage trend (local logs), shared across Claude cards.
    @Published var claudeUsageTrend: ClaudeUsageTrend?
    /// The single provider pinned to the menu bar, if any.
    @Published var pinnedProvider: PinnedProvider?
    @Published var refreshMinutes: Int = 15
    @Published var alertThreshold: Int = 80
    @Published var cardOrder: [String] = []
    @Published var lastSyncTime: Date?

    private var refreshTimer: Timer?
    private var fileWatchers: [FileWatcher] = []
    private var watchDebounce: DispatchWorkItem?
    private var launched = false

    // MARK: - Lifecycle

    /// Called once at app startup (from the app delegate) so watchers and the
    /// background timer run regardless of whether the popover has been opened.
    func onLaunch() {
        guard !launched else { return }
        launched = true
        NotificationManager.shared.requestAuthorization()
        loadFromDisk()
        setupFileWatchers()
        restartAutoRefreshTimer()
        if hasAnyAccount {
            Task { await refreshAll() }
        } else {
            updateGlobalStatus()
        }
    }

    /// True when at least one provider (Claude, Antigravity, Gemini CLI, or
    /// Command Code) is linked.
    var hasAnyAccount: Bool {
        !accounts.isEmpty || agAccount != nil || geminiAccount != nil || commandCodeAccount != nil
    }

    /// Called each time the menu-bar popover appears (the `window-shown`
    /// equivalent) — triggers an instant foreground sync.
    func onPopoverAppear() {
        guard launched else { return }
        Task { await refreshAll() }
    }

    private func loadFromDisk() {
        let settings = Persistence.load()
        accounts = settings.accounts.map {
            Account(id: $0.id, label: $0.label, sessionKey: $0.sessionKey, email: $0.email, status: .offline)
        }
        if let ag = settings.agAccount {
            agAccount = CliAccount(token: ag.token, email: ag.email, status: .offline)
        }
        if let gem = settings.geminiAccount {
            geminiAccount = CliAccount(token: gem.token, email: gem.email, status: .offline)
        }
        if let cmd = settings.commandCodeAccount {
            commandCodeAccount = CommandCodeAccount(token: cmd.token, email: cmd.email, status: .offline)
        }
        pinnedProvider = settings.pinnedProvider.flatMap(PinnedProvider.init(token:))
        refreshMinutes = settings.refreshMinutes
        alertThreshold = settings.alertThreshold
        if let order = settings.cardOrder {
            cardOrder = order
        }
        prunePinIfDangling()
    }

    @discardableResult
    func saveToDisk() -> Bool {
        // Strip transient fields, matching `saveAccountsToDisk` in renderer.js.
        let persisted = accounts.map {
            TrackerSettings.PersistedAccount(id: $0.id, label: $0.label, sessionKey: $0.sessionKey, email: $0.email)
        }
        let ag = agAccount.map { TrackerSettings.PersistedAg(token: $0.token, email: $0.email) }
        let gem = geminiAccount.map { TrackerSettings.PersistedAg(token: $0.token, email: $0.email) }
        let cmd = commandCodeAccount.map { TrackerSettings.PersistedAg(token: $0.token, email: $0.email) }
        let settings = TrackerSettings(accounts: persisted,
                                       agAccount: ag,
                                       geminiAccount: gem,
                                       commandCodeAccount: cmd,
                                       pinnedProvider: pinnedProvider?.token,
                                       refreshMinutes: refreshMinutes,
                                       alertThreshold: alertThreshold,
                                       cardOrder: cardOrder)
        Persistence.save(settings)
        return true
    }

    // MARK: - Dashboard card ordering

    /// The dashboard cards that currently have something to show, in the user's
    /// saved order. Ids saved for cards that are no longer present are ignored,
    /// and cards the user has never ordered are appended in their default order,
    /// so the list is always exactly the set of cards the dashboard renders.
    var visibleCardIDs: [String] {
        var active: [String] = accounts.map { "claude_\($0.id)" }
        if !accounts.isEmpty, let trend = claudeUsageTrend, !trend.days.isEmpty {
            active.append("claudeTrend")
        }
        if geminiAccount != nil { active.append("gemini") }
        if commandCodeAccount != nil { active.append("commandCode") }
        if agAccount != nil { active.append("antigravity") }

        var result = cardOrder.filter { active.contains($0) }
        result.append(contentsOf: active.filter { !result.contains($0) })
        return result
    }

    /// Adopts a new order for the *visible* cards. Ids that are saved but not
    /// currently visible (typically `claudeTrend` before any local history
    /// exists) are folded back in behind whichever visible card used to precede
    /// them, so a reorder never silently forgets a hidden card's position.
    func setCardOrder(_ visible: [String]) {
        let hidden = cardOrder.filter { !visible.contains($0) }
        guard !hidden.isEmpty else {
            cardOrder = visible
            return
        }
        var merged = visible
        for id in hidden {
            guard let old = cardOrder.firstIndex(of: id) else { continue }
            let predecessor = cardOrder[..<old].last(where: { visible.contains($0) })
            if let predecessor, let idx = merged.firstIndex(of: predecessor) {
                merged.insert(id, at: idx + 1)
            } else {
                merged.insert(id, at: 0)
            }
        }
        cardOrder = merged
    }

    // MARK: - Refresh triggers

    /// Re-syncs everything. Invoked by the popover opening, the background
    /// timer, and the file watchers.
    func refreshAll() async {
        guard hasAnyAccount else { return }

        restartAutoRefreshTimer()

        globalStatus = .syncing
        for i in accounts.indices { accounts[i].status = .syncing }
        if agAccount != nil { agAccount?.status = .syncing }
        if geminiAccount != nil { geminiAccount?.status = .syncing }
        if commandCodeAccount != nil { commandCodeAccount?.status = .syncing }
        updateGlobalStatus()

        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                let id = account.id
                let key = account.sessionKey
                group.addTask { [weak self] in
                    let result = await ClaudeService.fetchLiveLimits(sessionKey: key)
                    await self?.applyAccountResult(id: id, result: result)
                    await self?.fetchAccountEmailIfNeeded(id: id, sessionKey: key)
                }
            }
            if agAccount != nil {
                group.addTask { [weak self] in
                    await self?.refreshAntigravity()
                }
            }
            if geminiAccount != nil {
                group.addTask { [weak self] in
                    await self?.refreshGemini()
                }
            }
            if commandCodeAccount != nil {
                group.addTask { [weak self] in
                    await self?.refreshCommandCode()
                }
            }
        }

        aggregateGlobalStatus()

        // Local Claude Code usage trend — scanned independently (the first pass
        // over hundreds of MB of logs can take a few seconds), so it never holds
        // up the quota sync / "Synced" status. Only relevant with a Claude card.
        if !accounts.isEmpty {
            Task { await refreshClaudeUsageTrend() }
        }
    }

    /// Rescans local Claude Code logs (off the main actor) and publishes the trend.
    func refreshClaudeUsageTrend() async {
        let trend = await ClaudeUsageScanner.shared.scan()
        if let trend { claudeUsageTrend = trend }
    }

    private func applyAccountResult(id: String, result: Result<QuotaData, ClaudeService.FetchError>) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let quota):
            accounts[idx].quota = quota
            accounts[idx].lastFetchTime = Date()
            accounts[idx].status = .online
            accounts[idx].errorMsg = nil
            checkSessionUsageAlert(index: idx)
            checkModelWeeklyAlerts(index: idx)
        case .failure(let error):
            accounts[idx].quota = nil
            accounts[idx].status = .error
            accounts[idx].errorMsg = error.localizedDescription
        }
    }

    func refreshAccount(id: String) async {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].status = .syncing
        let key = accounts[idx].sessionKey
        let result = await ClaudeService.fetchLiveLimits(sessionKey: key)
        applyAccountResult(id: id, result: result)
        await fetchAccountEmailIfNeeded(id: id, sessionKey: key)
        aggregateGlobalStatus()
    }

    /// Fetches and caches the account email once (when not already known).
    private func fetchAccountEmailIfNeeded(id: String, sessionKey: String) async {
        guard let idx = accounts.firstIndex(where: { $0.id == id }), accounts[idx].email == nil else { return }
        guard let email = await ClaudeService.fetchAccountEmail(sessionKey: sessionKey) else { return }
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].email = email
        saveToDisk()
    }

    func refreshAntigravity() async {
        guard let token = agAccount?.token, !token.isEmpty else { return }
        if let result = await AntigravityService.fetchQuota() {
            agAccount?.gemini = result.gemini
            agAccount?.claudeGpt = result.claudeGpt
            if let email = result.email { agAccount?.email = email }
            agAccount?.lastFetch = Date()
            agAccount?.status = .online
            checkCliUsageAlert(\.agAccount, providerName: "Antigravity")
        } else {
            agAccount?.status = .error
        }
    }

    func refreshGemini() async {
        guard let token = geminiAccount?.token, !token.isEmpty else { return }
        if let result = await GeminiService.fetchQuota() {
            geminiAccount?.gemini = result.gemini
            geminiAccount?.claudeGpt = result.claudeGpt
            if let email = result.email { geminiAccount?.email = email }
            geminiAccount?.lastFetch = Date()
            geminiAccount?.status = .online
            checkCliUsageAlert(\.geminiAccount, providerName: "Gemini CLI")
        } else {
            geminiAccount?.status = .error
        }
    }

    func refreshCommandCode() async {
        guard let token = commandCodeAccount?.token, !token.isEmpty else { return }
        if let result = await CommandCodeService.fetchQuota() {
            commandCodeAccount?.quota = result.quota
            if let email = result.email { commandCodeAccount?.email = email }
            commandCodeAccount?.lastFetch = Date()
            commandCodeAccount?.status = .online
            checkCommandCodeUsageAlert()
        } else {
            commandCodeAccount?.status = .error
        }
    }

    // MARK: - Notifications

    /// Edge-triggered: fires once when session usage first crosses the
    /// threshold, re-arming only after usage falls back below it.
    private func checkSessionUsageAlert(index: Int) {
        let threshold = alertThreshold
        guard threshold > 0 else { return }
        let sessionPct = accounts[index].quota?.sessionUtilization ?? 0

        if sessionPct >= threshold {
            if !accounts[index].alertedHighUsage {
                accounts[index].alertedHighUsage = true
                NotificationManager.shared.notify(
                    title: "\(accounts[index].label) — \(sessionPct)% of session used",
                    body: "Your current 5-hour session has crossed \(threshold)% usage.")
            }
        } else {
            accounts[index].alertedHighUsage = false
        }
    }

    /// Edge-triggered alert for each model-scoped weekly cap (e.g. Fable), which
    /// the API already reports as *usage*, so no conversion is needed. Latched
    /// per model name, and only for caps the account actually has — a plan
    /// without the model reports no entry and is therefore never alerted on.
    private func checkModelWeeklyAlerts(index: Int) {
        let threshold = alertThreshold
        guard threshold > 0 else { return }
        let limits = accounts[index].quota?.modelWeeklyLimits ?? []

        for limit in limits {
            guard let model = limit.modelName else { continue }
            let pct = limit.percentInt
            if pct >= threshold {
                if !accounts[index].alertedModelWeekly.contains(model) {
                    accounts[index].alertedModelWeekly.insert(model)
                    NotificationManager.shared.notify(
                        title: "\(accounts[index].label) — \(pct)% of \(model) weekly used",
                        body: "Your weekly \(model) limit has crossed \(threshold)% usage.")
                }
            } else {
                accounts[index].alertedModelWeekly.remove(model)
            }
        }

        // Drop latches for caps the account no longer reports, so the alert
        // re-arms if the model comes back.
        let present = Set(limits.compactMap(\.modelName))
        accounts[index].alertedModelWeekly.formIntersection(present)
    }

    /// Edge-triggered alert for a CLI provider's 5-hour lane. The threshold is
    /// expressed as *usage* (matching Claude), so we convert the provider's
    /// *remaining* fraction: used = 100 − (lowest remaining 5-hour bucket).
    private func checkCliUsageAlert(_ kp: ReferenceWritableKeyPath<AppState, CliAccount?>,
                                    providerName: String) {
        let threshold = alertThreshold
        guard threshold > 0,
              let acc = self[keyPath: kp], acc.status == .online,
              let usedPct = fiveHourUsedPct(acc) else { return }

        if usedPct >= threshold {
            if self[keyPath: kp]?.alertedHighUsage == false {
                self[keyPath: kp]?.alertedHighUsage = true
                NotificationManager.shared.notify(
                    title: "\(providerName) — \(usedPct)% of 5-hour used",
                    body: "Your \(providerName) 5-hour quota has crossed \(threshold)% usage.")
            }
        } else {
            self[keyPath: kp]?.alertedHighUsage = false
        }
    }

    /// 5-hour usage% for a CLI account = 100 − the lowest remaining 5-hour
    /// bucket across its model families. Returns nil when no 5-hour data exists.
    private func fiveHourUsedPct(_ acc: CliAccount) -> Int? {
        var remaining: [Int] = []
        if let g = acc.gemini { remaining.append(g.fiveHourPct) }
        if let c = acc.claudeGpt { remaining.append(c.fiveHourPct) }
        guard let lowestRemaining = remaining.min() else { return nil }
        return max(0, 100 - lowestRemaining)
    }

    /// Edge-triggered alert for Command Code. Its 5-hour window already reports
    /// *usage* against a cap, so no conversion is needed. Plans without request
    /// windows (`limited: false`) have no 5-hour lane and are skipped — their
    /// only limit is the monthly credit pool.
    private func checkCommandCodeUsageAlert() {
        let threshold = alertThreshold
        guard threshold > 0,
              let acc = commandCodeAccount, acc.status == .online,
              let usedPct = acc.quota?.fiveHour?.usedPct else { return }

        if usedPct >= threshold {
            if commandCodeAccount?.alertedHighUsage == false {
                commandCodeAccount?.alertedHighUsage = true
                NotificationManager.shared.notify(
                    title: "Command Code — \(usedPct)% of 5-hour used",
                    body: "Your Command Code 5-hour quota has crossed \(threshold)% usage.")
            }
        } else {
            commandCodeAccount?.alertedHighUsage = false
        }
    }

    // MARK: - Menu-bar pin

    /// Pins a provider to the menu bar, or unpins it when it is already pinned.
    /// Only one provider can be pinned at a time.
    func togglePin(_ provider: PinnedProvider) {
        pinnedProvider = (pinnedProvider == provider) ? nil : provider
        saveToDisk()
    }

    func isPinned(_ provider: PinnedProvider) -> Bool {
        pinnedProvider == provider
    }

    /// Drops a pin that points at a provider which is no longer linked, so the
    /// menu bar never shows a stale reading.
    private func prunePinIfDangling() {
        guard let pin = pinnedProvider else { return }
        let stillExists: Bool
        switch pin {
        case .claude(let id): stillExists = accounts.contains { $0.id == id }
        // Keyed on the account only: quota is transient and still nil at launch,
        // so testing for the cap itself would drop the pin before the first
        // fetch. A cap that genuinely disappears yields no `pinnedSummary`,
        // which already falls the menu bar back to the plain glyph.
        case .claudeModelWeekly(let id, _):
            stillExists = accounts.contains { $0.id == id }
        case .gemini:         stillExists = geminiAccount != nil
        case .antigravity:    stillExists = agAccount != nil
        case .commandCode:    stillExists = commandCodeAccount != nil
        }
        if !stillExists { pinnedProvider = nil }
    }

    /// The label + usage the menu bar shows for the pinned reading — a
    /// provider's 5-hour session, or a model-scoped weekly cap when one is
    /// pinned instead.
    /// Nil when nothing is pinned or the provider has no reading yet, which
    /// falls the menu bar back to the plain icon.
    var pinnedSummary: PinnedSummary? {
        guard let pin = pinnedProvider else { return nil }
        switch pin {
        case .claude(let id):
            guard let acc = accounts.first(where: { $0.id == id }),
                  let quota = acc.quota else { return nil }
            return PinnedSummary(label: acc.label, percent: quota.sessionUtilization)
        case .claudeModelWeekly(let id, let model):
            guard let acc = accounts.first(where: { $0.id == id }),
                  let limit = acc.quota?.modelWeeklyLimits.first(where: { $0.modelName == model })
            else { return nil }
            return PinnedSummary(label: model, percent: limit.percentInt)
        case .gemini:
            guard let acc = geminiAccount, let pct = fiveHourUsedPct(acc) else { return nil }
            return PinnedSummary(label: "Gemini", percent: pct)
        case .antigravity:
            guard let acc = agAccount, let pct = fiveHourUsedPct(acc) else { return nil }
            return PinnedSummary(label: "Antigravity", percent: pct)
        case .commandCode:
            guard let quota = commandCodeAccount?.quota else { return nil }
            // Plans with no request window still have the monthly credit pool,
            // which is the only usage signal they expose.
            let pct = quota.fiveHour?.usedPct ?? quota.creditsUsedPct
            return PinnedSummary(label: "Command Code", percent: pct)
        }
    }

    // MARK: - Global status

    private func aggregateGlobalStatus() {
        var allSuccess = true
        var anySuccess = false
        for acc in accounts {
            if acc.status == .online { anySuccess = true } else { allSuccess = false }
        }
        if let ag = agAccount {
            if ag.status == .online { anySuccess = true } else { allSuccess = false }
        }
        if let gem = geminiAccount {
            if gem.status == .online { anySuccess = true } else { allSuccess = false }
        }
        if let cmd = commandCodeAccount {
            if cmd.status == .online { anySuccess = true } else { allSuccess = false }
        }
        if allSuccess {
            globalStatus = .online
        } else if anySuccess {
            globalStatus = .warning
        } else {
            globalStatus = .error
        }
        updateGlobalStatus()
    }

    private func updateGlobalStatus() {
        let latest = accounts.compactMap { $0.lastFetchTime }.max()
        if let latest { lastSyncTime = latest }
    }

    // MARK: - Account CRUD

    func addAccount(label: String, sessionKey: String) {
        var account = Account(label: label, sessionKey: sessionKey, status: .offline)
        account.status = .syncing
        accounts.append(account)
        saveToDisk()
        let id = account.id
        Task { await refreshAccount(id: id) }
    }

    func updateAccount(id: String, label: String, sessionKey: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        let keyChanged = accounts[idx].sessionKey != sessionKey
        accounts[idx].label = label
        accounts[idx].sessionKey = sessionKey
        saveToDisk()
        if keyChanged {
            accounts[idx].status = .syncing
            Task { await refreshAccount(id: id) }
        }
    }

    func removeAccount(id: String) {
        accounts.removeAll { $0.id == id }
        prunePinIfDangling()
        saveToDisk()
        aggregateGlobalStatus()
    }

    // MARK: - Antigravity linking

    func linkAntigravity() async -> String? {
        guard let creds = AntigravityService.login() else {
            return "Could not find ~/.gemini/oauth_creds.json"
        }
        agAccount = CliAccount(token: creds.token, email: creds.email, status: .syncing)
        saveToDisk()
        await refreshAntigravity()
        aggregateGlobalStatus()
        return nil
    }

    func unlinkAntigravity() {
        agAccount = nil
        prunePinIfDangling()
        saveToDisk()
        aggregateGlobalStatus()
    }

    // MARK: - Gemini CLI linking

    func linkGemini() async -> String? {
        guard let creds = GeminiService.login() else {
            return "Could not find ~/.gemini/oauth_creds.json"
        }
        geminiAccount = CliAccount(token: creds.token, email: creds.email, status: .syncing)
        saveToDisk()
        await refreshGemini()
        aggregateGlobalStatus()
        return nil
    }

    func unlinkGemini() {
        geminiAccount = nil
        prunePinIfDangling()
        saveToDisk()
        aggregateGlobalStatus()
    }

    // MARK: - Command Code linking

    func linkCommandCode() async -> String? {
        guard let creds = CommandCodeService.login() else {
            return "Could not find ~/.commandcode/auth.json — run `cmd` and sign in first."
        }
        commandCodeAccount = CommandCodeAccount(token: creds.token, email: creds.email, status: .syncing)
        saveToDisk()
        await refreshCommandCode()
        aggregateGlobalStatus()
        return nil
    }

    func unlinkCommandCode() {
        commandCodeAccount = nil
        prunePinIfDangling()
        saveToDisk()
        aggregateGlobalStatus()
    }

    // MARK: - Settings

    func setRefreshMinutes(_ minutes: Int) {
        guard minutes > 0 else { return }
        refreshMinutes = minutes
        saveToDisk()
        restartAutoRefreshTimer()
    }

    func setAlertThreshold(_ threshold: Int) {
        alertThreshold = threshold
        // Re-arm so a new threshold can fire against current usage.
        for i in accounts.indices {
            accounts[i].alertedHighUsage = false
            accounts[i].alertedModelWeekly.removeAll()
        }
        agAccount?.alertedHighUsage = false
        geminiAccount?.alertedHighUsage = false
        commandCodeAccount?.alertedHighUsage = false
        saveToDisk()
        for i in accounts.indices where accounts[i].status == .online {
            checkSessionUsageAlert(index: i)
            checkModelWeeklyAlerts(index: i)
        }
        checkCliUsageAlert(\.agAccount, providerName: "Antigravity")
        checkCliUsageAlert(\.geminiAccount, providerName: "Gemini CLI")
        checkCommandCodeUsageAlert()
    }

    // MARK: - Session automation

    func startSession(account: Account) {
        SessionWindowController.start(accountId: account.id, sessionKey: account.sessionKey)
    }

    // MARK: - Timers & watchers

    private func restartAutoRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, refreshMinutes) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }

    private func setupFileWatchers() {
        fileWatchers.forEach { $0.stop() }
        fileWatchers = Persistence.watchedFiles.map { url in
            FileWatcher(url: url) { [weak self] in
                self?.debouncedWatchRefresh()
            }
        }
    }

    private func debouncedWatchRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { await self?.refreshAll() }
            }
            self.watchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }
}
