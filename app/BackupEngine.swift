import Foundation
import Observation
import Photos

struct BackupConfig {
    var serverURL: String
    var username: String
    var password: String
    var deviceName: String
}

enum BackupError: LocalizedError {
    case noPhotoAccess
    case badServerURL(String)

    var errorDescription: String? {
        switch self {
        case .noPhotoAccess:
            "Photo library access denied. Settings → Privacy → Photos → ImageBackup."
        case .badServerURL(let s):
            "Not a usable server URL: \(s)"
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
    /// Every stored property below has a default, so construction needs no isolation. Without
    /// this, `@State private var engine = BackupEngine()` in a View is a call to a MainActor
    /// initializer from a nonisolated property initializer — a Swift 6 error, not a warning.
    nonisolated init() {}

    enum Phase: Equatable {
        case idle, running, done, cancelled
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var assetsDone = 0
    private(set) var assetsTotal = 0
    private(set) var uploadedBytes: Int64 = 0
    private(set) var currentFile = ""
    private(set) var activity: [String] = []

    private var task: Task<Void, Never>?

    func start(config: BackupConfig, from: Date, to: Date) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(config: config, from: from, to: to)
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
        uploadedBytes = 0
        activity = []

        do {
            guard let base = URL(string: config.serverURL),
                  let scheme = base.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  base.host != nil else {
                throw BackupError.badServerURL(config.serverURL)
            }

            let assets = try await fetchAssets(from: from, to: to)
            assetsTotal = assets.count
            guard !assets.isEmpty else { phase = .done; return }

            let client = WebDAVClient(base: base,
                                      username: config.username,
                                      password: config.password)

            for asset in assets {
                try Task.checkCancellation()
                for resource in Self.resourcesToBackUp(asset) {
                    try Task.checkCancellation()
                    currentFile = resource.filename ?? "(unnamed)"
                    try await upload(resource, of: asset, device: config.deviceName, client: client)
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
    }

    private func fetchAssets(from: Date, to: Date) async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw BackupError.noPhotoAccess
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                        from as NSDate, to as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func upload(_ resource: PHAssetResource,
                        of asset: PHAsset,
                        device: String,
                        client: WebDAVClient) async throws {
        let path = Self.remotePath(for: asset, resource: resource, device: device)
        try await client.ensureDirectory(Self.parentDirectory(of: path))

        // dataSize is iOS 27+ and Int? — nil means unknown, not zero.
        let expected = resource.dataSize.map { Int64($0) }

        if let stored = try await client.existingSize(path: path) {
            // Never overwrite. A size mismatch means a different asset already owns this name,
            // which is a real collision and must be surfaced, not silently resolved either way.
            // ponytail: skip + log for the MVP. Add deterministic renaming once you've seen how
            // often this actually fires on your library.
            if let expected, expected > 0, stored > 0, stored != expected {
                note("! \(path) — stored \(stored)B vs \(expected)B: name collision, skipped")
            } else {
                note("= \(path) (already there)")
            }
            return
        }

        let temp = try await download(resource)
        defer { try? FileManager.default.removeItem(at: temp) }

        switch try await client.put(fileURL: temp, path: path) {
        case .uploaded:
            if let expected { uploadedBytes += expected }
            note("↑ \(path)")
        case .alreadyThere:
            note("= \(path) (raced, already there)")
        }
    }

    /// Streams to /tmp, never into memory — a 4K video as `Data` gets the app killed (research §4.2).
    private func download(_ resource: PHAssetResource) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-\(Self.filename(of: resource))")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // required, or iCloud-only assets fail outright

        try await PHAssetResourceManager.default().writeData(for: resource,
                                                            toFile: destination,
                                                            options: options)
        return destination
    }

    // MARK: - Layout rules (research §6)

    /// Originals + Live Photo motion. Skips `fullSize*` renders (derivable) and `adjustment*`
    /// data — see research §6.5 for why that's the policy rather than a shortcut.
    private static let wantedTypes: Set<PHAssetResourceType> = [.photo, .video, .pairedVideo, .audio]

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
        return "\(sanitize(device))/\(year)/\(month)/\(filename(of: resource))"
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

    private func note(_ line: String) {
        activity.append(line)
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }
}
