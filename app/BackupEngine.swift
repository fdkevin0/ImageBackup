import Foundation
import Observation
import Photos

struct BackupConfig {
    var serverURL: String
    var username: String
    var password: String
    var deviceName: String
}

extension BackupConfig {
    static func configured() -> BackupConfig {
        let defaults = UserDefaults.standard
        return BackupConfig(
            serverURL: defaults.string(forKey: "serverURL") ?? "",
            username: defaults.string(forKey: "username") ?? "",
            password: Keychain.load("webdavPassword"),
            deviceName: defaults.string(forKey: "deviceName") ?? "")
    }
}

enum BackupError: LocalizedError {
    case noPhotoAccess
    case badServerURL(String)
    /// The run stopped rather than retry every remaining file against a server that is not
    /// answering. Carries the last real error, so the user sees the cause and not just a count.
    case givingUp(afterFiles: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .noPhotoAccess:
            "Photo library access denied. Settings → Privacy → Photos → ImageBackup."
        case .badServerURL(let s):
            "Not a usable server URL: \(s)"
        case .givingUp(let files, let message):
            """
            Stopped: \(files) files in a row failed. Check the NAS address, and that this phone is \
            on its network.

            Last error: \(message)
            """
        }
    }
}

/// Foreground-only MVP: walks the chosen date range and PUTs each original to WebDAV.
///
/// Deliberately NOT the PHAssetResourceUploadJob path. That API is the right destination
/// (research §1) but needs an app extension, entitlements, a paid team and a physical
/// device before it can be tested at all. This proves the transport and the folder layout first.
@MainActor
@Observable
final class BackupEngine {
    // A @State property initializer cannot call a MainActor initializer under Swift 6.
    nonisolated init() {}

    enum Phase: Equatable {
        case idle, running, done, cancelled
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var assetsDone = 0
    private(set) var assetsTotal = 0
    private(set) var uploadedFiles = 0
    private(set) var currentFile = ""
    private(set) var skippedCollisions = 0
    private(set) var unverifiedFiles = 0
    private(set) var failures: [String] = []
    private(set) var hasLimitedAccess = false
    private(set) var state = BackupState()

    private var task: Task<Void, Never>?

    func loadState() {
        state = BackupState.load()
    }

    enum Window {
        case sinceLastRun
        case everything
    }

    func start(config: BackupConfig, window: Window) {
        guard task == nil else { return }
        loadState()

        // The engine takes an exclusive end, hence the extra day: "today" has to include today.
        let end = Date.now.addingTimeInterval(86_400)
        let start: Date = switch window {
        case .everything:
            .distantPast
        case .sinceLastRun:
            (state.lastRunEnd ?? Date.now.addingTimeInterval(-30 * 86_400))
                .addingTimeInterval(-7 * 86_400)
        }

        task = Task { [weak self] in
            await self?.run(config: config, from: start, to: end)
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(config: BackupConfig, from: Date, to: Date) async {
        phase = .running
        assetsDone = 0
        assetsTotal = 0
        uploadedFiles = 0
        skippedCollisions = 0
        unverifiedFiles = 0
        failures = []
        Self.resetStaging()

        do {
            guard let base = URL(string: config.serverURL),
                  let scheme = base.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  base.host != nil else {
                throw BackupError.badServerURL(config.serverURL)
            }

            let assets = try await fetchAssets(from: from, to: to)
            assetsTotal = assets.count

            let client = WebDAVClient(base: base,
                                      username: config.username,
                                      password: config.password)
            var consecutiveFailures = 0

            for asset in assets {
                try Task.checkCancellation()
                for resource in Self.resourcesToBackUp(asset) {
                    try Task.checkCancellation()
                    let path = Self.remotePath(for: asset,
                                               resource: resource,
                                               device: config.deviceName)
                    currentFile = Self.filename(of: resource)
                    do {
                        try await upload(resource, path: path, client: client)
                        consecutiveFailures = 0
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures.append(path)
                        consecutiveFailures += 1
                        // ponytail: three in a row is a guess at "this is not a blip". Without
                        // it an unreachable NAS costs files × attempts × backoff before the app
                        // says so, which on a 30-day window is the difference between a message
                        // and an hour of nothing.
                        if consecutiveFailures >= 3 {
                            throw BackupError.givingUp(afterFiles: consecutiveFailures,
                                                       message: error.localizedDescription)
                        }
                    }
                }
                assetsDone += 1
            }
            phase = .done
        } catch is CancellationError {
            phase = .cancelled
        } catch {
            phase = .failed(error.localizedDescription)
        }
        currentFile = ""
        recordOutcome(walkedTo: to)
    }

    private func recordOutcome(walkedTo end: Date) {
        state.lastRun = BackupState.Run(uploaded: uploadedFiles,
                                        skipped: skippedCollisions,
                                        failed: failures.count)
        if case .done = phase, failures.isEmpty {
            state.lastRunEnd = end
        }
        state.save()
    }

    private func fetchAssets(from: Date, to: Date) async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw BackupError.noPhotoAccess
        }
        // `.limited` means the walk sees only the photos the user picked. The run will look
        // complete and be incomplete, so the UI has to say so.
        hasLimitedAccess = status == .limited

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                        from as NSDate, to as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Prefetch the extended-metadata group instead of letting PhotoKit fetch it per asset.
        options.prefetchAssetExtendedMetadata = true

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func upload(_ resource: PHAssetResource,
                        path: String,
                        client: WebDAVClient) async throws {
        var attempt = 1
        while true {
            do {
                try await uploadOnce(resource, path: path, client: client)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < RetryPolicy.maxAttempts, RetryPolicy.isTransient(error) else {
                    throw error
                }
                try await Task.sleep(for: RetryPolicy.delay(afterAttempt: attempt))
                attempt += 1
            }
        }
    }

    private func uploadOnce(_ resource: PHAssetResource,
                            path: String,
                            client: WebDAVClient) async throws {
        try await client.ensureDirectory(Self.parentDirectory(of: path))

        // dataSize is iOS 27+ and Int? — nil means unknown, not zero.
        let expected = resource.dataSize.map { Int64($0) }

        switch try await client.existing(path: path) {
        case .absent:
            break

        case .sized(let stored):
            // Never overwrite. A size mismatch means a different asset already owns this name,
            // which is a real collision and must be surfaced, not silently resolved either way.
            // ponytail: skip + count for the MVP. Add deterministic renaming once the count says
            // it is worth building.
            if let expected, expected > 0, stored != expected {
                skippedCollisions += 1
            }
            return

        case .unsized:
            // Something is there but the server would not say how big — a HEAD with no
            // Content-Length. It cannot be compared, so it is left alone and *counted*, rather than
            // assumed complete: an unverifiable file that reports as done is the quiet kind of hole.
            unverifiedFiles += 1
            return
        }

        let temp = try await download(resource)
        defer { try? FileManager.default.removeItem(at: temp) }

        // false means someone else won the race between the HEAD and the PUT; nothing to do.
        if try await client.put(fileURL: temp, path: path) {
            uploadedFiles += 1
        }
    }

    /// Streams to disk, never into memory — a 4K video as `Data` gets the app killed (research §4.2).
    private func download(_ resource: PHAssetResource) async throws -> URL {
        let destination = Self.stagingDirectory
            .appending(path: "\(UUID().uuidString)-\(Self.filename(of: resource))")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // required, or iCloud-only assets fail outright

        try await PHAssetResourceManager.default().writeData(for: resource,
                                                            toFile: destination,
                                                            options: options)
        return destination
    }

    // Clear files left behind when a prior run was killed before its defer executed.
    private static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "imagebackup")
    }

    private static func resetStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.createDirectory(at: stagingDirectory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: - Layout rules (research §6)

    // fullSize renders are derivable; adjustmentBase variants may duplicate the original.
    private static let wantedTypes: Set<PHAssetResourceType> = [
        .photo, .video, .pairedVideo, .audio, .adjustmentData,
    ]

    private static func resourcesToBackUp(_ asset: PHAsset) -> [PHAssetResource] {
        PHAssetResource.assetResources(for: asset).filter { wantedTypes.contains($0.type) }
    }

    /// `<device>/<YYYY>/<MM>/<originalFilename>` — device-first kills cross-device name collisions,
    /// monthly keeps directories under the ~10k listing cliff without a MKCOL per day.
    private static func remotePath(for asset: PHAsset,
                                   resource: PHAssetResource,
                                   device: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        // Pinned to the device's timezone at run time and never changed — an unpinned zone
        // moves a 23:30 shot into the wrong month (research §6.3).
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: asset.creationDate ?? Date())
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let deviceDirectory = device.isEmpty ? "" : "\(sanitize(device))/"
        return "\(deviceDirectory)\(year)/\(month)/\(filename(of: resource))"
    }

    private static func parentDirectory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// `originalFilename` is deprecated in iOS 27 and its replacement `filename` is nullable, so a
    /// resource with no name gets a UUID from `sanitize` — an odd filename beats a dropped photo.
    private static func filename(of resource: PHAssetResource) -> String {
        sanitize(resource.filename ?? "")
    }

    /// Not filesystem-safe as-is: "/" would invent a path level and ":" is illegal on SMB.
    private static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? UUID().uuidString : cleaned
    }

}
