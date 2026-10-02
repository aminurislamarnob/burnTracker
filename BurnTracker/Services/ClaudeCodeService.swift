import Foundation

/// Tracks the Claude account that Claude Code (the `claude` CLI) is signed in
/// to on this Mac — no session key needed. Ported from openusage's Claude
/// provider (`Sources/OpenUsage/Providers/Claude/`).
///
/// The OAuth credential is read fresh from Claude Code's own store on every
/// fetch (the macOS Keychain item `Claude Code-credentials`, else
/// `~/.claude/.credentials.json`) and never copied into `tracker-settings.json`.
/// The usage payload from `api.anthropic.com/api/oauth/usage` is the same shape
/// as claude.ai's, so it decodes straight into `QuotaData`.
///
/// **Refresh writes back.** Anthropic rotates the refresh token on every use, so
/// refreshing without saving would sign Claude Code out. The write is guarded:
/// the store is re-read first and left alone if Claude Code changed it mid-way,
/// and only `accessToken` / `refreshToken` / `expiresAt` are merged, so every
/// other field Claude Code keeps there survives untouched.
actor ClaudeCodeService {
    static let shared = ClaudeCodeService()

    // MARK: - Types

    struct Identity: Equatable {
        var accountUuid: String?
        var email: String?
        var organizationName: String?
    }

    enum FetchError: LocalizedError {
        case notLoggedIn
        case keychainDenied
        case missingScope
        case sessionExpired
        case tokenExpired
        case status(Int)
        case connection(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "No Claude Code login found. Run `claude` and sign in, then try again."
            case .keychainDenied: return "Keychain access to Claude Code's login was denied. Refresh and choose Allow."
            case .missingScope: return "This Claude Code login can't read usage. Run `claude` and log in again."
            case .sessionExpired: return "Session expired. Run `claude` to log in again."
            case .tokenExpired: return "Token expired. Run `claude` to log in again."
            case .status(let code): return "Server returned status \(code)"
            case .connection(let m): return "Connection failed: \(m)"
            case .invalidResponse: return "Unexpected response from Anthropic."
            }
        }
    }

    enum Outcome {
        case success(QuotaData, Identity?)
        /// Anthropic throttled us; no fetch is attempted before `until`.
        case rateLimited(until: Date)
        case failure(FetchError)
    }

    /// Where a credential was read from, so a refreshed token is written back
    /// to the same place.
    private enum Source: Equatable {
        /// `account` is the item's `acct` attribute, kept so `-U` updates the
        /// existing item rather than adding a second one.
        case keychain(account: String?)
        case file(URL)
    }

    private struct Stored {
        var source: Source
        /// The whole stored document, so a write-back preserves fields we
        /// don't model (MCP logins and the like).
        var document: [String: Any]
        var accessToken: String
        var refreshToken: String?
        /// Epoch milliseconds.
        var expiresAt: Double?
        var scopes: [String]?
    }

    // MARK: - Constants

    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let refreshScope =
        "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    /// Refresh when the access token is this close to expiring.
    private static let refreshMargin: TimeInterval = 5 * 60
    /// Cooldown when a 429 carries no usable `Retry-After`.
    private static let defaultCooldown: TimeInterval = 5 * 60

    private static var claudeDir: URL { Persistence.claudeDir }
    private static var credentialsFileURL: URL { claudeDir.appendingPathComponent(".credentials.json") }
    private static var stateFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "BurnTracker/\(version)"
    }()

    // MARK: - State

    private var cooldownUntil: Date?
    /// Collapses overlapping fetches (popover open + file watcher) into one, so
    /// two refreshes can never race on the same rotating refresh token.
    private var inFlight: Task<Outcome, Never>?

    // MARK: - Public API

    /// Checks that a usable login exists, for the Connect button. Reading the
    /// Keychain here is what surfaces macOS's access prompt, right after the
    /// user clicked rather than unprompted at launch.
    func checkLogin() -> Result<Identity?, FetchError> {
        switch Self.readStored() {
        case .failure(let error):
            return .failure(error)
        case .success(let stored):
            if let scopes = stored.scopes, !scopes.isEmpty, !scopes.contains("user:profile") {
                return .failure(.missingScope)
            }
            return .success(Self.readIdentity())
        }
    }

    func fetchUsage() async -> Outcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.performFetch() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    // MARK: - Fetch

    private func performFetch() async -> Outcome {
        if let until = cooldownUntil, until > Date() { return .rateLimited(until: until) }
        cooldownUntil = nil

        var stored: Stored
        switch Self.readStored() {
        case .failure(let error): return .failure(error)
        case .success(let s): stored = s
        }
        if let scopes = stored.scopes, !scopes.isEmpty, !scopes.contains("user:profile") {
            return .failure(.missingScope)
        }

        var refreshed = false
        if let expiresAt = stored.expiresAt,
           Date(timeIntervalSince1970: expiresAt / 1000).timeIntervalSinceNow <= Self.refreshMargin,
           stored.refreshToken != nil {
            switch await refresh(stored) {
            case .success(let s): stored = s; refreshed = true
            case .failure(let error): return .failure(error)
            }
        }

        var result = await requestUsage(token: stored.accessToken)
        // One refresh-and-retry on an auth failure, unless we just refreshed.
        if case .unauthorized = result, !refreshed, stored.refreshToken != nil {
            switch await refresh(stored) {
            case .success(let s): stored = s
            case .failure(let error): return .failure(error)
            }
            result = await requestUsage(token: stored.accessToken)
        }

        switch result {
        case .success(let quota):
            return .success(quota, Self.readIdentity())
        case .unauthorized:
            return .failure(.tokenExpired)
        case .rateLimited(let until):
            cooldownUntil = until
            return .rateLimited(until: until)
        case .failure(let error):
            return .failure(error)
        }
    }

    private enum UsageResult {
        case success(QuotaData)
        case unauthorized
        case rateLimited(Date)
        case failure(FetchError)
    }

    private func requestUsage(token: String) async -> UsageResult {
        var req = URLRequest(url: Self.usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard let h = resp as? HTTPURLResponse else { return .failure(.invalidResponse) }
            data = d; http = h
        } catch {
            return .failure(.connection(error.localizedDescription))
        }

        switch http.statusCode {
        case 200:
            guard let quota = try? JSONDecoder().decode(QuotaData.self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(quota)
        case 401, 403:
            return .unauthorized
        case 429:
            let wait = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? Self.defaultCooldown
            return .rateLimited(Date().addingTimeInterval(wait))
        default:
            return .failure(.status(http.statusCode))
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date.
    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(1, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(1, date.timeIntervalSinceNow)
    }

    // MARK: - Token refresh

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    private func refresh(_ stored: Stored) async -> Result<Stored, FetchError> {
        guard let refreshToken = stored.refreshToken else { return .failure(.tokenExpired) }

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientId,
            "scope": Self.refreshScope
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard let h = resp as? HTTPURLResponse else { return .failure(.invalidResponse) }
            data = d; http = h
        } catch {
            return .failure(.connection(error.localizedDescription))
        }

        guard http.statusCode == 200 else {
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if (http.statusCode == 400 || http.statusCode == 401) && err == "invalid_grant" {
                return .failure(.sessionExpired)
            }
            return .failure(.status(http.statusCode))
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            return .failure(.invalidResponse)
        }

        var updated = stored
        updated.accessToken = token.access_token
        updated.refreshToken = token.refresh_token ?? refreshToken
        updated.expiresAt = token.expires_in.map { Date().timeIntervalSince1970 * 1000 + $0 * 1000 }
        Self.saveIfUnchanged(updated, original: stored)
        return .success(updated)
    }

    /// Writes the refreshed tokens back, but only when the store still holds
    /// the credential this refresh started from. If Claude Code refreshed in
    /// the meantime its copy is newer and wins; the new access token is then
    /// used for this fetch only. A failed write is likewise non-fatal.
    private static func saveIfUnchanged(_ updated: Stored, original: Stored) {
        guard case .success(let latest) = readStored(),
              latest.source == original.source,
              latest.refreshToken == original.refreshToken,
              latest.accessToken == original.accessToken else {
            NSLog("BurnTracker: Claude Code login changed during refresh; not writing back")
            return
        }

        var document = latest.document
        var oauth = document["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = updated.accessToken
        if let refreshToken = updated.refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt = updated.expiresAt { oauth["expiresAt"] = Int64(expiresAt) }
        document["claudeAiOauth"] = oauth

        guard let data = try? JSONSerialization.data(withJSONObject: document,
                                                     options: [.withoutEscapingSlashes]) else { return }
        switch latest.source {
        case .keychain(let account):
            if !Keychain.write(data, service: keychainService, account: account) {
                NSLog("BurnTracker: failed to write refreshed Claude Code token to the Keychain")
            }
        case .file(let url):
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                NSLog("BurnTracker: failed to write refreshed Claude Code token: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Credential store

    /// Keychain first (what Claude Code uses on macOS), then the plain file it
    /// falls back to where the Keychain is unavailable.
    private static func readStored() -> Result<Stored, FetchError> {
        var denied = false
        switch Keychain.read(service: keychainService) {
        case .found(let data, let account):
            if let stored = parse(data, source: .keychain(account: account)) { return .success(stored) }
        case .denied:
            denied = true
        case .notFound:
            break
        }
        if let data = try? Data(contentsOf: credentialsFileURL),
           let stored = parse(data, source: .file(credentialsFileURL)) {
            return .success(stored)
        }
        return .failure(denied ? .keychainDenied : .notLoggedIn)
    }

    private static func parse(_ data: Data, source: Source) -> Stored? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = document["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else { return nil }
        return Stored(source: source,
                      document: document,
                      accessToken: accessToken,
                      refreshToken: (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      expiresAt: CliQuotaSupport.asDouble(oauth["expiresAt"]),
                      scopes: oauth["scopes"] as? [String])
    }

    /// The signed-in account, from Claude Code's state file (`oauthAccount`).
    private static func readIdentity() -> Identity? {
        guard let state = CliQuotaSupport.readJSONObject(stateFileURL),
              let account = state["oauthAccount"] as? [String: Any] else { return nil }
        return Identity(accountUuid: account["accountUuid"] as? String,
                        email: account["emailAddress"] as? String,
                        organizationName: account["organizationName"] as? String)
    }
}

// MARK: - Keychain via /usr/bin/security

/// Reads and writes Claude Code's Keychain item through the `security` tool
/// rather than Security.framework. Claude Code itself goes through `security`,
/// so the tool is already on the item's access list — reading it this way
/// prompts at most once, and the ACL stays exactly as Claude Code expects. A
/// native `SecItem` call would instead be judged by BurnTracker's own ad-hoc
/// signature, which changes every release and would re-prompt each update.
private enum Keychain {
    enum ReadResult {
        case found(Data, account: String?)
        case notFound
        case denied
    }

    /// `security`'s exit status for errSecItemNotFound.
    private static let notFoundStatus: Int32 = 44

    static func read(service: String) -> ReadResult {
        let user = NSUserName()
        // Scoped to this user first (how Claude Code writes it), then unscoped.
        let scoped = run(["find-generic-password", "-a", user, "-s", service, "-w"])
        if scoped.status == 0, let data = decode(scoped.output) { return .found(data, account: user) }
        // Anything but "not found" means the item exists and access was refused;
        // retrying unscoped would only show the user a second prompt.
        if scoped.status != 0 && scoped.status != notFoundStatus { return .denied }

        let unscoped = run(["find-generic-password", "-s", service, "-w"])
        if unscoped.status == 0, let data = decode(unscoped.output) {
            return .found(data, account: accountAttribute(service: service))
        }
        if scoped.status == notFoundStatus && unscoped.status == notFoundStatus { return .notFound }
        return .denied
    }

    /// Updates the item in place (`-U`). The secret is passed as hex through
    /// `security -i` on stdin, so it never appears in the process list and
    /// needs no shell quoting. Interactive mode exits 0 even when a command
    /// fails, so success is confirmed by reading the value back.
    static func write(_ data: Data, service: String, account: String?) -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        var command = "add-generic-password -U"
        if let account { command += " -a \(quoted(account))" }
        command += " -s \(quoted(service)) -X \(hex)\n"
        _ = run(["-i"], input: Data(command.utf8))

        let check = account.map { run(["find-generic-password", "-a", $0, "-s", service, "-w"]) }
            ?? run(["find-generic-password", "-s", service, "-w"])
        return check.status == 0 && decode(check.output) == data
    }

    /// The item's `acct` attribute, from `security`'s attribute dump.
    private static func accountAttribute(service: String) -> String? {
        let result = run(["find-generic-password", "-s", service])
        guard result.status == 0, let text = String(data: result.output, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            guard let start = line.range(of: "<blob>=\"")?.upperBound,
                  let end = line.lastIndex(of: "\""), end >= start else { continue }
            return String(line[start..<end])
        }
        return nil
    }

    /// `-w` prints the value as text, or as hex when it holds non-printable
    /// bytes; accept either.
    private static func decode(_ output: Data) -> Data? {
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("{") { return Data(text.utf8) }
        var hex = Substring(text)
        if hex.hasPrefix("0x") { hex = hex.dropFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Quotes an argument for `security -i`'s command-line parser.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        do {
            try process.run()
        } catch {
            return (-1, Data())
        }
        if let stdin, let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
