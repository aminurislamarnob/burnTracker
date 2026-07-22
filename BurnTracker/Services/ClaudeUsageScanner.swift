import Foundation

/// Builds a daily token/cost trend for Claude by scanning Claude Code's local
/// session logs (`~/.claude/projects/**/*.jsonl`) — the same source `ccusage`
/// uses. Runs off the main actor; parsed files are cached in memory by path +
/// size + mtime, so refreshes and re-opens only re-parse changed files.
///
/// This is a pragmatic port of OpenUsage's `ClaudeLogUsageScanner`: it keeps the
/// core semantics (usage-line marker, token normalization, dedup by
/// message.id + requestId, per-local-day aggregation, unpriced entries excluded)
/// but omits the heavier machinery (Cowork sandboxes, advisor iterations,
/// on-disk cache, CLAUDE_CONFIG_DIR multi-root resolution).
actor ClaudeUsageScanner {
    static let shared = ClaudeUsageScanner()

    /// One parsed usage line, kept compact for caching.
    private struct Entry {
        let timestamp: Date
        let tokens: TokenBreakdown
        let messageID: String?
        let requestID: String?
        let model: String?
    }

    /// Per-file cache record keyed by path; invalidated when size or mtime changes.
    private struct FileCache {
        let size: Int
        let mtime: Date
        let entries: [Entry]
    }

    private var cache: [String: FileCache] = [:]

    private var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Scan the last `daysBack` days. Returns nil when there's no Claude log
    /// directory at all; an empty trend when logs exist but have no recent usage.
    func scan(daysBack: Int = 30, now: Date = Date()) -> ClaudeUsageTrend? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else { return nil }

        let files = jsonlFiles(under: projectsDir)
        guard !files.isEmpty else {
            return ClaudeUsageTrend(days: [], generatedAt: now)
        }

        // Reuse cached parses for unchanged files; re-parse changed/new ones.
        var allEntries: [Entry] = []
        var freshCache: [String: FileCache] = [:]
        for url in files {
            let path = url.path
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? Int) ?? -1
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast

            if let cached = cache[path], cached.size == size, cached.mtime == mtime {
                freshCache[path] = cached
                allEntries.append(contentsOf: cached.entries)
            } else if let data = try? Data(contentsOf: url) {
                let entries = Self.parseFile(data)
                freshCache[path] = FileCache(size: size, mtime: mtime, entries: entries)
                allEntries.append(contentsOf: entries)
            }
        }
        cache = freshCache

        let deduped = Self.dedup(allEntries)
        let since = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -(daysBack - 1), to: now) ?? now)
        return Self.aggregate(deduped, since: since, now: now)
    }

    // MARK: - File discovery

    private func jsonlFiles(under root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }  // deterministic dedup keep-first
    }

    // MARK: - Parsing

    private static let usageMarker = Data(#""usage":{"#.utf8)

    private static func parseFile(_ data: Data) -> [Entry] {
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: usageMarker) != nil else { continue }
            if let entry = parseLine(Data(line)) { entries.append(entry) }
        }
        return entries
    }

    private static func parseLine(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = isoDate(timestampRaw),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? NSNumber,
              let output = usage["output_tokens"] as? NSNumber
        else { return nil }

        var cw5m = 0, cw1h = 0
        if let cc = usage["cache_creation"] as? [String: Any] {
            cw5m = (cc["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
            cw1h = (cc["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        } else {
            cw5m = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        }

        let tokens = TokenBreakdown(
            input: input.intValue,
            output: output.intValue,
            cacheWrite5m: cw5m,
            cacheWrite1h: cw1h,
            cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0)

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        return Entry(
            timestamp: timestamp,
            tokens: tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            model: model)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - Dedup

    private static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        for e in entries {
            guard let mid = e.messageID else { out.append(e); continue }
            let key = "\(mid)\u{1}\(e.requestID ?? "")"
            if seen.insert(key).inserted { out.append(e) }
        }
        return out
    }

    // MARK: - Aggregation

    private static func aggregate(_ entries: [Entry], since: Date, now: Date) -> ClaudeUsageTrend {
        let cal = Calendar.current
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]

        for e in entries where e.timestamp >= since {
            // Only priceable entries count, so tokens and dollars stay coherent.
            guard let model = e.model, let cost = ClaudePricing.cost(model: model, tokens: e.tokens)
            else { continue }
            let day = cal.startOfDay(for: e.timestamp)
            var bucket = byDay[day] ?? (0, 0)
            bucket.tokens += e.tokens.total
            bucket.cost += cost
            byDay[day] = bucket
        }

        let days = byDay
            .map { DayUsage(day: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
            .sorted { $0.day < $1.day }
        return ClaudeUsageTrend(days: days, generatedAt: now)
    }
}
