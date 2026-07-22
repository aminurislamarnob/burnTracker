import Foundation

/// Loads and saves `~/.claude/tracker-settings.json`.
///
/// Session keys are stored in plaintext on disk (unchanged from the original
/// build) — they are local-only and must never be logged or transmitted
/// anywhere except Claude.ai.
enum Persistence {
    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static var trackerSettingsURL: URL {
        claudeDir.appendingPathComponent("tracker-settings.json")
    }

    /// Files watched for changes to trigger a live re-sync.
    static var watchedFiles: [URL] {
        [
            claudeDir.appendingPathComponent("history.jsonl"),
            claudeDir.appendingPathComponent("stats-cache.json")
        ]
    }

    static func load() -> TrackerSettings {
        guard let data = try? Data(contentsOf: trackerSettingsURL) else {
            return TrackerSettings()
        }
        return (try? JSONDecoder().decode(TrackerSettings.self, from: data)) ?? TrackerSettings()
    }

    static func save(_ settings: TrackerSettings) {
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(settings)
            try data.write(to: trackerSettingsURL, options: .atomic)
        } catch {
            NSLog("BurnTracker: failed to write tracker-settings.json: \(error.localizedDescription)")
        }
    }
}
