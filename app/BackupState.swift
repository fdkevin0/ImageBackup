import Foundation

/// What survives a relaunch: the watermark the next run starts from, and what the last one did.
///
/// No per-asset index and no content hash — a file's presence is settled by HEAD against the server,
/// so the skip key is a path, not an asset identifier, and a device restore or library migration
/// costs time rather than correctness.
struct BackupState: Codable {
    struct Run: Codable {
        var uploaded: Int
        var skipped: Int
        var failed: Int
    }

    /// The **exclusive** end of the window the last clean run covered, nil if there has never been
    /// one. Advanced only when a run ends with zero failures: advance it past a failure and those
    /// files sit behind the watermark forever, invisible to the default range.
    var lastRunEnd: Date?

    var lastRun: Run?

    private static let key = "backupState"

    /// Anything unreadable is treated as "no state" — the run then falls back to the wide default
    /// window, which costs a re-walk and never a lost photo.
    static func load() -> BackupState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(BackupState.self, from: data)
        else { return BackupState() }
        return state
    }

    /// Best effort: a write that fails costs the next run a wider window, never correctness.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
