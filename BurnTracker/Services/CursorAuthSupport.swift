import Foundation

/// Reads Cursor session tokens from the Cursor app's local state DB and Keychain.
/// Ported from openusage's `CursorAuthStore`.
enum CursorAuthSupport {
    enum Source: Equatable {
        case sqlite
        case keychain
    }

    struct AuthState: Equatable {
        var accessToken: String?
        var refreshToken: String?
        var source: Source
    }

    private static let stateDBPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }()
    private static let accessTokenKey = "cursorAuth/accessToken"
    private static let refreshTokenKey = "cursorAuth/refreshToken"
    private static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    private static let keychainAccessService = "cursor-access-token"
    private static let keychainRefreshService = "cursor-refresh-token"
    private static let refreshBuffer: TimeInterval = 5 * 60

    /// Cursor.app is installed and has a local state DB (the user has opened Cursor).
    static var hasCursorDatabase: Bool {
        FileManager.default.fileExists(atPath: stateDBPath)
    }

    static var hasCredentials: Bool { loadAuthState() != nil }

    /// Candidate auth sources. Prefer `state.vscdb` (one Safe Storage unlock) and
    /// **skip** the separate Cursor session Keychain items whenever SQLite already
    /// yields a usable JWT — those extra SecItem reads were stacking password sheets.
    static func loadAuthCandidates() -> [AuthState] {
        var candidates: [AuthState] = []
        if let state = sqliteAuthState() { candidates.append(state) }
        // Only fall through to cursor-access-token when SQLite has nothing usable.
        if candidates.isEmpty, let state = keychainAuthState() {
            candidates.append(state)
        }
        return candidates
    }

    static func loadAuthState() -> AuthState? {
        loadAuthCandidates().first
    }

    private static func keychainAuthState() -> AuthState? {
        let access = readKeychainPassword(service: keychainAccessService)
        // Refresh is optional — never show a second sheet for it.
        let refresh = KeychainAccess.readGenericPasswordSilently(
            service: keychainRefreshService,
            accounts: ["cursor-user", NSUserName(), nil])
        guard isUsableAccessToken(access) || isUsableRefreshToken(refresh) else { return nil }
        return AuthState(accessToken: access, refreshToken: refresh, source: .keychain)
    }

    private static func sqliteAuthState() -> AuthState? {
        // `cursor-agent` and the Cursor app store JWTs as `cursor-safe-storage:v1:`
        // ciphertext. Decrypt before treating the row as a session.
        let access = CursorSafeStorage.unwrap(readSQLiteValue(accessTokenKey))
        let refresh = CursorSafeStorage.unwrap(readSQLiteValue(refreshTokenKey))

        let usableAccess = isUsableAccessToken(access) ? access : nil
        let usableRefresh = isUsableRefreshToken(refresh) ? refresh : nil
        guard usableAccess != nil || usableRefresh != nil else { return nil }

        // Keep the decrypted token out of state.vscdb. A refresh must not replace
        // Cursor's encrypted blob with a raw JWT.
        return AuthState(accessToken: usableAccess, refreshToken: usableRefresh, source: .sqlite)
    }

    /// Cursor now stores encrypted blobs in `state.vscdb` (`cursor-safe-storage:v1:…`); only JWT-shaped
    /// values are usable as Bearer tokens. Live sessions are in Keychain (`cursor-access-token`).
    private static func isUsableAccessToken(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return false
        }
        if value.hasPrefix("cursor-safe-storage:") { return false }
        return value.split(separator: ".").count >= 3
    }

    private static func isUsableRefreshToken(_ value: String?) -> Bool {
        isUsableAccessToken(value)
    }

    static func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken, let exp = jwtExpiration(accessToken) else { return true }
        return exp.timeIntervalSinceNow <= refreshBuffer
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let sub = CliQuotaSupport.decodeJWTPayload(token)?["sub"] as? String else { return nil }
        let trimmed = sub.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resolveEmail(accessToken: String?) -> String? {
        if let token = accessToken,
           let payload = CliQuotaSupport.decodeJWTPayload(token) {
            if let email = payload["email"] as? String, !email.isEmpty { return email }
            if let sub = payload["sub"] as? String, sub.contains("@") { return sub }
        }
        if let cached = readSQLiteValue("cursorAuth/cachedEmail")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return cached
        }
        return nil
    }

    @discardableResult
    static func saveAccessToken(_ accessToken: String, source: Source) -> Bool {
        switch source {
        case .sqlite:
            return writeSQLiteValue(accessTokenKey, accessToken)
        case .keychain:
            return writeKeychainPassword(accessToken, service: keychainAccessService)
        }
    }

    // MARK: - SQLite

    private static func readSQLiteValue(_ key: String) -> String? {
        guard FileManager.default.fileExists(atPath: stateDBPath) else { return nil }
        let sql = "SELECT value FROM ItemTable WHERE key = '\(sqlEscaped(key))' LIMIT 1;"
        let output = runSQLite(args: ["-readonly", stateDBPath, sql])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func writeSQLiteValue(_ key: String, _ value: String) -> Bool {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(sqlEscaped(key))', '\(sqlEscaped(value))');
        """
        _ = runSQLite(args: [stateDBPath, sql])
        return readSQLiteValue(key) == value
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func runSQLite(args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Keychain (generic password services Cursor uses)

    /// Cursor stores the live session as a generic password with account `cursor-user`.
    /// One interactive sheet max for this service (account variants are Fail-first).
    private static func readKeychainPassword(service: String) -> String? {
        KeychainAccess.readGenericPassword(
            service: service,
            accounts: ["cursor-user", NSUserName(), nil])
    }

    private static func writeKeychainPassword(_ value: String, service: String) -> Bool {
        let user = NSUserName()
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(user.replacingOccurrences(of: "\"", with: "\\\""))\" -s \"\(service)\" -X \(hex)\n"
        _ = KeychainAccess.runSecurity(["-i"], input: Data(command.utf8))
        KeychainAccess.invalidate(service: service)
        return readKeychainPassword(service: service) == value
    }

    private static func jwtExpiration(_ token: String) -> Date? {
        guard let exp = CliQuotaSupport.decodeJWTPayload(token)?["exp"] else { return nil }
        guard let seconds = CliQuotaSupport.asDouble(exp) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
