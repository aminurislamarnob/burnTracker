import Foundation

/// Finds Antigravity's local Connect-RPC servers and the CSRF tokens they require.
///
/// The IDE spawns a `language_server` whose argv carries both tokens and the
/// extension server's port:
///
///     language_server --csrf_token <t> --extension_server_port 51381 \
///                     --extension_server_csrf_token <t2> --app_data_dir antigravity …
///
/// so `ps` is where those values live. The *listening ports* are not in argv, so
/// they come from `lsof` scoped to that pid — much narrower than scanning every
/// listening socket on the machine, which is what this replaced.
///
/// The `agy` CLI also serves the same RPC service but publishes no token in its
/// argv. Recent builds nonetheless reject token-less calls, so a CLI-only
/// machine may be undiscoverable; it is still reported last so older builds,
/// which accept token-less calls, keep working.
enum LanguageServerDiscovery {

    enum Kind {
        /// The IDE's `language_server` — carries CSRF tokens in its argv.
        case languageServer
        /// The `agy` CLI's embedded server — no token published.
        case cli
    }

    struct Server {
        let kind: Kind
        let pid: Int32
        let csrfToken: String?
        let ports: [Int]
        let extensionPort: Int?
        let extensionCSRFToken: String?
    }

    /// Antigravity servers currently running, richest source first
    /// (`language_server` before `agy`).
    static func discover() -> [Server] {
        guard let listing = run("/bin/ps", ["-ax", "-ww", "-o", "pid=,command="]) else { return [] }

        var languageServers: [Server] = []
        var cliServers: [Server] = []

        for line in listing.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[trimmed.startIndex..<space]) else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])

            guard let kind = kind(ofCommand: command) else { continue }
            let ports = listeningPorts(pid: pid)
            let extensionPort = flagValue("--extension_server_port", in: command).flatMap(Int.init)
            // A process with neither a reachable port nor an extension port has
            // nothing we can call.
            guard !ports.isEmpty || extensionPort != nil else { continue }

            let server = Server(
                kind: kind,
                pid: pid,
                csrfToken: flagValue("--csrf_token", in: command),
                ports: ports,
                extensionPort: extensionPort,
                extensionCSRFToken: flagValue("--extension_server_csrf_token", in: command))

            switch kind {
            case .languageServer: languageServers.append(server)
            case .cli:            cliServers.append(server)
            }
        }

        return languageServers + cliServers
    }

    // MARK: - Classification

    private static func kind(ofCommand command: String) -> Kind? {
        if command.contains("language_server") { return .languageServer }
        // Match the executable only: a stray argument containing "agy" (a file
        // path, say) must not turn an unrelated process into a quota source.
        let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        if (executable as NSString).lastPathComponent == "agy" { return .cli }
        return nil
    }

    /// Reads `--flag value` out of a command line. Also accepts `--flag=value`,
    /// which `ps` renders verbatim for processes that were launched that way.
    private static func flagValue(_ flag: String, in command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        for (index, part) in parts.enumerated() {
            if part == flag, index + 1 < parts.count {
                let value = parts[index + 1]
                return value.hasPrefix("--") ? nil : value
            }
            if part.hasPrefix(flag + "=") {
                return String(part.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    // MARK: - Ports

    /// TCP ports `pid` is listening on. Scoped with `-a -p` so this never
    /// enumerates unrelated sockets.
    private static func listeningPorts(pid: Int32) -> [Int] {
        guard let output = run("/usr/sbin/lsof",
                               ["-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-P", "-n"])
        else { return [] }

        var ports: [Int] = []
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: #":(\d+)\s+\(LISTEN\)"#, options: .regularExpression) else { continue }
            let digits = line[range].dropFirst().prefix { $0.isNumber }
            if let port = Int(digits), !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    // MARK: - Process helper

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
