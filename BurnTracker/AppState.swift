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
    @Published var agAccount: AgAccount?
    @Published var globalStatus: GlobalStatus = .offline
    @Published var refreshMinutes: Int = 15
    @Published var alertThreshold: Int = 80
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
        if !accounts.isEmpty || agAccount != nil {
            Task { await refreshAll() }
        } else {
            updateGlobalStatus()
        }
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
            Account(id: $0.id, label: $0.label, sessionKey: $0.sessionKey, status: .offline)
        }
        if let ag = settings.agAccount {
            agAccount = AgAccount(token: ag.token, email: ag.email, status: .offline)
        }
        refreshMinutes = settings.refreshMinutes
        alertThreshold = settings.alertThreshold
    }

    @discardableResult
    func saveToDisk() -> Bool {
        // Strip transient fields, matching `saveAccountsToDisk` in renderer.js.
        let persisted = accounts.map {
            TrackerSettings.PersistedAccount(id: $0.id, label: $0.label, sessionKey: $0.sessionKey)
        }
        let ag = agAccount.map { TrackerSettings.PersistedAg(token: $0.token, email: $0.email) }
        let settings = TrackerSettings(accounts: persisted,
                                       agAccount: ag,
                                       refreshMinutes: refreshMinutes,
                                       alertThreshold: alertThreshold)
        Persistence.save(settings)
        return true
    }

    // MARK: - Refresh triggers

    /// Re-syncs everything. Invoked by the popover opening, the background
    /// timer, and the file watchers.
    func refreshAll() async {
        guard !accounts.isEmpty || agAccount != nil else { return }

        restartAutoRefreshTimer()

        globalStatus = .syncing
        for i in accounts.indices { accounts[i].status = .syncing }
        if agAccount != nil { agAccount?.status = .syncing }
        updateGlobalStatus()

        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                let id = account.id
                let key = account.sessionKey
                group.addTask { [weak self] in
                    let result = await ClaudeService.fetchLiveLimits(sessionKey: key)
                    await self?.applyAccountResult(id: id, result: result)
                }
            }
            if agAccount != nil {
                group.addTask { [weak self] in
                    await self?.refreshAntigravity()
                }
            }
        }

        aggregateGlobalStatus()
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
        aggregateGlobalStatus()
    }

    func refreshAntigravity() async {
        guard let token = agAccount?.token, !token.isEmpty else { return }
        if let result = await AntigravityService.fetchQuota() {
            agAccount?.gemini = result.gemini
            agAccount?.claudeGpt = result.claudeGpt
            if let email = result.email { agAccount?.email = email }
            agAccount?.status = .online
        } else {
            agAccount?.status = .error
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
        saveToDisk()
        aggregateGlobalStatus()
    }

    // MARK: - Antigravity linking

    func linkAntigravity() async -> String? {
        guard let creds = AntigravityService.login() else {
            return "Could not find ~/.gemini/oauth_creds.json"
        }
        agAccount = AgAccount(token: creds.token, email: creds.email, status: .syncing)
        saveToDisk()
        await refreshAntigravity()
        aggregateGlobalStatus()
        return nil
    }

    func unlinkAntigravity() {
        agAccount = nil
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
        for i in accounts.indices { accounts[i].alertedHighUsage = false }
        saveToDisk()
        for i in accounts.indices where accounts[i].status == .online {
            checkSessionUsageAlert(index: i)
        }
    }

    // MARK: - Session automation

    func startSession(account: Account, prompt: String) {
        SessionWindowController.start(accountId: account.id, sessionKey: account.sessionKey, prompt: prompt)
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
