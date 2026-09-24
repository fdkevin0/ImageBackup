import Foundation
import Security

/// Minimal WebDAV: MKCOL, HEAD, PUT. No dependency — URLRequest.httpMethod is a free-form String.
///
/// The error/result types live in `WebDAVTypes.swift` so they can be compiled without `Security`.
///
/// ponytail: one client per backup run; `createdDirs` is in-memory only, so a relaunch re-MKCOLs
/// every folder it touches. That's one extra round trip per folder per run — worth a persistent
/// cache only if folder count ever becomes the bottleneck.
actor WebDAVClient {
    private let base: URL
    private let authHeader: String
    private let session: URLSession
    private var createdDirs: Set<String> = []

    init(base: URL, username: String, password: String) {
        self.base = base
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        self.authHeader = "Basic \(token)"

        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 120
        // A request timeout with no resource ceiling can still wait forever: with
        // `waitsForConnectivity` set, a request made off the network parks rather than fails. An
        // hour covers a multi-GB video over a LAN, and bounds the rest into an error the user sees
        // instead of a spinner that never stops.
        cfg.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: cfg)
    }

    private func makeRequest(_ method: String, path: String) -> URLRequest {
        var r = URLRequest(url: base.appending(path: path))
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return r
    }

    private func send(_ r: URLRequest, fromFile: URL? = nil) async throws -> HTTPURLResponse {
        let response: URLResponse
        if let fromFile {
            (_, response) = try await session.upload(for: r, fromFile: fromFile)
        } else {
            (_, response) = try await session.data(for: r)
        }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.notHTTP }
        return http
    }

    /// Creates every missing collection on the way to `dir`.
    /// RFC 4918 §9.7.1: PUT must not create intermediate collections, so each level needs its own MKCOL.
    func ensureDirectory(_ dir: String) async throws {
        var walked: [String] = []
        for part in dir.split(separator: "/") {
            walked.append(String(part))
            let key = walked.joined(separator: "/")
            if createdDirs.contains(key) { continue }

            let status = try await send(makeRequest("MKCOL", path: key)).statusCode
            // 201 created · 405 already exists (RFC 4918) · 409 or 403 = parent missing.
            // Servers disagree on the already-exists code — rclone answers 201, not 405
            // (measured) — so both are accepted and neither is treated as an error.
            guard status == 201 || status == 405 else {
                throw WebDAVError.status(status, key)
            }
            createdDirs.insert(key)
        }
    }

    /// What is already stored at `path`.
    ///
    /// This is a HEAD rather than a conditional PUT because `If-None-Match: *` is **not**
    /// dependable: rclone's WebDAV ignores it and silently overwrites (verified against
    /// rclone v1.75.1, 2026-09-24 — same path, same header, 201 instead of 412). A HEAD that
    /// returns 412 on one server and 201 on another is not something a backup can rest on.
    /// One extra round trip per file, correct everywhere.
    func existing(path: String) async throws -> RemoteFile {
        let http = try await send(makeRequest("HEAD", path: path))
        switch http.statusCode {
        case 404:
            return .absent
        case 200, 204:
            let length = http.expectedContentLength
            return length >= 0 ? .sized(length) : .unsized
        case let code:
            throw WebDAVError.status(code, path)
        }
    }

    /// Still sends `If-None-Match: *` as a second line of defence for servers that honour it.
    /// Where it's ignored this behaves as a plain PUT — which is why the caller HEADs first.
    ///
    /// Returns false when the server refused because something is already there: for the caller that
    /// case needs no more handling than a successful upload.
    func put(fileURL: URL, path: String) async throws -> Bool {
        var r = makeRequest("PUT", path: path)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue("*", forHTTPHeaderField: "If-None-Match")

        switch try await send(r, fromFile: fileURL).statusCode {
        case 200, 201, 204: return true
        case 412:           return false
        case let code:      throw WebDAVError.status(code, path)
        }
    }
}

/// The NAS credential is the one real secret here, so it goes in the Keychain, not UserDefaults.
enum Keychain {
    /// Follows the app's own identifier rather than the hand-copied `com.example.imagebackup` that
    /// used to sit here — one fewer place to update when the bundle id moves. The consequence of
    /// the change today: a password saved by an older build is not found, and is typed in once more.
    private static let service = Bundle.main.bundleIdentifier ?? "com.fdkevin.imagebackup"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(_ account: String) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
