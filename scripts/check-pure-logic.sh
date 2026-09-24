#!/bin/sh
# The check that runs anywhere: no device, no simulator, no NAS, no iOS SDK.
#
# It compiles the app's Foundation-only retry logic and runs its assertions.
#
# Needs `swiftc` on PATH (the swiftly shim; see docs/ios-toolchain-linux.md).

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

swiftc -swift-version 6 -o "$out/check" \
    "$root/app/RetryPolicy.swift" \
    "$root/app/WebDAVTypes.swift" \
    "$root/scripts/pure-logic-check/main.swift"

"$out/check"
