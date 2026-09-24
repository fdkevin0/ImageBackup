import Foundation

/// Which failures are worth trying again, and how long to wait between attempts.
///
/// No Photos import and no state, so it is testable without a device or a server — see
/// `scripts/check-pure-logic.sh`.
enum RetryPolicy {
    /// Per file, including the first attempt. Three covers a blip; an outage is caught by the
    /// engine's consecutive-failure stop rather than by retrying every remaining file.
    static let maxAttempts = 3

    /// 2s, then 4s. No jitter: there is one client, so there is no herd to stagger.
    static func delay(afterAttempt attempt: Int) -> Duration {
        .seconds(1 << attempt)
    }

    /// Transient means the network or the server hiccuped. Everything else is configuration or a
    /// limit on the other end, and retrying those only delays the message the user needs to read.
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL, .userAuthenticationRequired, .cancelled,
                 .fileDoesNotExist, .cannotOpenFile, .appTransportSecurityRequiresSecureConnection:
                return false
            default:
                return true    // timedOut, cannotConnect, networkConnectionLost, notConnected…
            }
        }

        if case WebDAVError.status(let code, _) = error {
            // Named rather than "5xx": several 5xx codes are permanent answers, and retrying a
            // permanent answer is three round trips of nothing. 501 means the server will never
            // implement it, 505 that it will not speak this HTTP, 507 that the NAS is full —
            // freeing space is the user's job, not the retry loop's.
            switch code {
            case 408, 429, 500, 502, 503, 504: return true
            default: return false
            }
        }

        return false
    }
}
