import Foundation

/// Separate from `WebDAVClient.swift` so retry behavior can be checked on Linux without `Security`.
enum WebDAVError: LocalizedError {
    case notHTTP
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .notHTTP: "Server did not return HTTP."
        case .status(let code, let path): "HTTP \(code) for \(path)"
        }
    }
}

/// What a HEAD found at a path.
///
/// Three cases rather than an `Int64?`: "no Content-Length" is not a size, and a sentinel like `-1`
/// is exactly how a file that can never be verified ends up reading as already backed up.
enum RemoteFile {
    case absent
    case sized(Int64)
    case unsized
}
