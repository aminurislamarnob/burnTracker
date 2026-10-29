import AppKit
import Foundation
import Security

/// Shared Keychain reader — **at most one interactive password sheet per launch**.
///
/// macOS prompts per Keychain *item*. Cursor Safe Storage and Copilot are
/// different items, so allowing UI for both produced two sheets. This gate lets
/// the first needed item prompt; everything else stays silent until the user
/// taps Refresh on that card (which calls `invalidate(rearmPrompt: true)`).
enum KeychainAccess {
    enum Outcome: Equatable {
        case value(String)
        case missing
        case denied
    }

    private static let lock = NSLock()
    private static var cache: [String: Outcome] = [:]
    /// True after any interactive Keychain sheet this process (or since rearm).
    private static var didPromptInteractively = false
    private static let uiGate = DispatchQueue(label: "BurnTracker.KeychainAccess.ui")

    static func invalidateAll() {
        lock.lock()
        cache.removeAll()
        didPromptInteractively = false
        lock.unlock()
    }

    /// Clears cache for a service. Pass `rearmPrompt: true` only from a manual
    /// card Refresh so macOS may ask again for *that* item — never from a write
    /// or background sync (that was re-arming Copilot right after Cursor).
    static func invalidate(service: String, account: String? = nil, rearmPrompt: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if rearmPrompt {
            didPromptInteractively = false
        }
        if let account {
            cache.removeValue(forKey: cacheKey(service: service, account: account))
        }
        for existing in Array(cache.keys) where existing.hasPrefix(service + "\u{1f}") {
            cache.removeValue(forKey: existing)
        }
    }

    // MARK: - SecItem

    static func readGenericPassword(service: String, account: String?, allowInteractive: Bool = true) -> String? {
        readGenericPassword(service: service, accounts: [account], allowInteractive: allowInteractive)
    }

    /// Fail-first across accounts, then at most one process-wide interactive try
    /// when `allowInteractive` is true.
    static func readGenericPassword(service: String, accounts: [String?], allowInteractive: Bool = true) -> String? {
        if let hit = readGenericPasswordSilently(service: service, accounts: accounts) {
            return hit
        }
        guard allowInteractive else { return nil }
        let unique = orderedUnique(accounts)
        let preferred = unique.first { $0 != nil } ?? unique.first ?? nil
        if case .value(let text) = secItem(service: service, account: preferred, allowUI: true) {
            return text
        }
        return nil
    }

    static func readGenericPasswordSilently(service: String, accounts: [String?]) -> String? {
        for account in orderedUnique(accounts) {
            if case .value(let text) = secItem(service: service, account: account, allowUI: false) {
                return text
            }
        }
        return nil
    }

    // MARK: - security CLI (Claude Code ACL)

    static func readViaSecurityCLI(service: String, account: String?, allowInteractive: Bool = true) -> Outcome {
        readViaSecurityCLI(service: service, accounts: [account], allowInteractive: allowInteractive)
    }

    static func readViaSecurityCLI(service: String, accounts: [String?], allowInteractive: Bool = true) -> Outcome {
        let unique = orderedUnique(accounts)
        for account in unique {
            let silent = securityCLI(service: service, account: account, allowUI: false)
            if case .value = silent { return silent }
        }
        guard allowInteractive else {
            return unique.isEmpty ? .missing : securityCLI(service: service, account: unique.first ?? nil, allowUI: false)
        }
        let preferred = unique.first { $0 != nil } ?? unique.first ?? nil
        return securityCLI(service: service, account: preferred, allowUI: true)
    }

    static func readViaSecurityCLIValue(service: String, account: String?, allowInteractive: Bool = true) -> String? {
        if case .value(let text) = readViaSecurityCLI(service: service, account: account, allowInteractive: allowInteractive) {
            return text
        }
        return nil
    }

    // MARK: - Internals

    private static func secItem(service: String, account: String?, allowUI: Bool) -> Outcome {
        let key = cacheKey(service: service, account: account)
        if let cached = cached(key) { return cached }

        let silent = performSecItem(service: service, account: account, allowUI: false)
        if case .value = silent {
            store(silent, for: key)
            return silent
        }
        guard allowUI else {
            if case .missing = silent { store(silent, for: key) }
            return silent
        }

        return uiGate.sync {
            if let cached = cached(key) { return cached }
            lock.lock()
            let already = didPromptInteractively
            if already {
                lock.unlock()
                store(silent == .missing ? .missing : .denied, for: key)
                return silent == .missing ? .missing : .denied
            }
            didPromptInteractively = true
            lock.unlock()

            activateApp()
            let prompted = performSecItem(service: service, account: account, allowUI: true)
            store(prompted, for: key)
            return prompted
        }
    }

    private static func securityCLI(service: String, account: String?, allowUI: Bool) -> Outcome {
        let key = cacheKey(service: service, account: account) + "\u{1f}cli"
        if let cached = cached(key) { return cached }

        let viaSecItem = performSecItem(service: service, account: account, allowUI: false)
        if case .value = viaSecItem {
            store(viaSecItem, for: key)
            return viaSecItem
        }

        guard allowUI else {
            if case .missing = viaSecItem { store(viaSecItem, for: key) }
            return viaSecItem == .missing ? .missing : .denied
        }

        return uiGate.sync {
            if let cached = cached(key) { return cached }
            lock.lock()
            let already = didPromptInteractively
            if already {
                lock.unlock()
                let fallback: Outcome = viaSecItem == .missing ? .missing : .denied
                store(fallback, for: key)
                return fallback
            }
            didPromptInteractively = true
            lock.unlock()

            activateApp()
            let prompted = performSecurityCLI(service: service, account: account)
            store(prompted, for: key)
            return prompted
        }
    }

    private static func orderedUnique(_ accounts: [String?]) -> [String?] {
        var seen = Set<String>()
        var out: [String?] = []
        for account in accounts {
            let marker = account ?? "*"
            guard seen.insert(marker).inserted else { continue }
            out.append(account)
        }
        return out
    }

    private static func cached(_ key: String) -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private static func store(_ outcome: Outcome, for key: String) {
        lock.lock()
        cache[key] = outcome
        lock.unlock()
    }

    private static func cacheKey(service: String, account: String?) -> String {
        service + "\u{1f}" + (account ?? "*")
    }

    private static func activateApp() {
        if Thread.isMainThread {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    private static func performSecItem(service: String, account: String?, allowUI: Bool) -> Outcome {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: allowUI
                ? kSecUseAuthenticationUIAllow
                : kSecUseAuthenticationUIFail
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return .missing }
            return .value(text)
        case errSecItemNotFound:
            return .missing
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        default:
            return allowUI ? .missing : .denied
        }
    }

    private static let securityNotFoundStatus: Int32 = 44

    private static func performSecurityCLI(service: String, account: String?) -> Outcome {
        var args = ["find-generic-password"]
        if let account { args += ["-a", account] }
        args += ["-s", service, "-w"]
        let result = runSecurity(args)
        if result.status == 0,
           let text = String(data: result.output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return .value(text)
        }
        if result.status == securityNotFoundStatus { return .missing }
        if result.status != 0 { return .denied }
        return .missing
    }

    static func runSecurity(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            do { try process.run() } catch { return (-1, Data()) }
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        } else {
            do { try process.run() } catch { return (-1, Data()) }
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
