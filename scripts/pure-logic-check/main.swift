// The one check in this repo that needs no device, no server and no SDK.
//
// Run it with `scripts/check-pure-logic.sh`. It covers the retry decision table because everything
// else needs Photos or a phone.
//
// The filename matters: `swiftc` allows top-level code in exactly one file, and it must be called
// `main.swift`. The body lives in a function because top-level code is MainActor-isolated under
// Swift 6 and a top-level `var` cannot carry that isolation itself.

import Foundation

@MainActor
private func runChecks() -> Int {
    var failures = 0

    func check(_ condition: Bool, _ label: String) {
        print(condition ? "  ok   \(label)" : "  FAIL \(label)")
        if !condition { failures += 1 }
    }

    print("RetryPolicy: what is worth trying again")
    for code in [401, 403, 404, 405, 409, 501, 505, 507] {
        check(!RetryPolicy.isTransient(WebDAVError.status(code, "p")), "HTTP \(code) is not retried")
    }
    for code in [408, 429, 500, 502, 503, 504] {
        check(RetryPolicy.isTransient(WebDAVError.status(code, "p")), "HTTP \(code) is retried")
    }
    for code in [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet] {
        check(RetryPolicy.isTransient(URLError(code)), "URL error \(code.rawValue) is retried")
    }
    for code in [URLError.badURL, .unsupportedURL, .cancelled,
                 .appTransportSecurityRequiresSecureConnection] {
        check(!RetryPolicy.isTransient(URLError(code)), "URL error \(code.rawValue) is not retried")
    }
    check(!RetryPolicy.isTransient(NSError(domain: "elsewhere", code: 1)),
          "an unknown error is not retried")

    print("RetryPolicy: the wait between attempts")
    check(RetryPolicy.delay(afterAttempt: 1) == .seconds(2), "first wait is 2s")
    check(RetryPolicy.delay(afterAttempt: 2) == .seconds(4), "second wait is 4s")

    return failures
}

let failures = runChecks()
print(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
