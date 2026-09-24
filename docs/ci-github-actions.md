# CI on GitHub Actions — Compile Testing, 2026-09-24

**Scope:** what it takes to compile and sanity-check this app in GitHub Actions, and which runner that requires. Not a general Actions tutorial.
**Facts as of:** 2026-09-24. Runner images move fast — re-check §1 against the image's own README before trusting a version here.
**Companion docs:** [`photo-to-nas.md`](./photo-to-nas.md) (the app and its constraints), [`ios-toolchain-linux.md`](./ios-toolchain-linux.md) (the local Linux build path this complements).

---

## TL;DR

1. **CI can build this app on exactly one image.** The `xcode-27` runner ships **Xcode 27.0 with the iOS 27.0 SDK**. Every other macOS image tops out at Xcode 26.x with the iOS **26** SDK, and a 27.0 deployment target cannot be built against it. That label is a requirement, not a preference.
2. The image is **arm64-only** and in **public preview** (announced 2026-07-16; moved to macOS 27 on 2026-09-10) — expect occasional queueing.
3. **It costs nothing here**, because this repo is public: standard GitHub-hosted runners are free in public repositories. Larger runners are *always* billed — so never `xcode-27-xlarge`.
4. **No secrets, certificates or Apple account.** `CODE_SIGNING_ALLOWED=NO` builds for a device without signing anything.
5. **CI does not replace the device test.** It cannot exercise the photo library, the local-network prompt, or ATS against a real NAS — those need a physical iPhone (`app/README.md`).
6. Its first real value is settling what could not be checked locally: that the hand-edited project file builds in actual Xcode, and that the app launches without crashing.

## 1. What the runner has

From the image's own README — [`images/macos/xcode-27-arm64-Readme.md`](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md):

| | |
|---|---|
| OS | macOS 27.0 (26A5406e) |
| Xcode | **27.0 (default)** — build 27A266a, at `/Applications/Xcode_27_Release_Candidate.app`, symlinked as `Xcode.app` |
| iOS SDK | **iPhoneOS 27.0** (`iphoneos27.0`), plus `iphonesimulator27.0` |
| Simulators | iOS 27.0 runtimes — iPhone 17, 17e, 18 Pro, 18 Pro Max, Air; iPad (A16), Air, mini (A17 Pro), Pro (M5) |
| Arch | arm64 only |

## 2. Why the label is not optional

GitHub supports **one Xcode major per macOS image** (all its minor versions; betas only in the newest image). So `macos-26` cannot exceed Xcode 26 / iOS 26 SDK. This project sets `IPHONEOS_DEPLOYMENT_TARGET = 27.0` and calls iOS 27-only APIs (`PHAssetResource.dataSize`, `PHAssetResource.filename`), so on any other image it fails before compiling a line of Swift.

```yaml
runs-on: xcode-27     # arm64, standard runner, free in public repos
```

`xcode-27` is a floating label: the Xcode major stays fixed while the macOS underneath it moves — that is exactly what happened in September 2026 (26 → 27).

## 3. Cost

| | |
|---|---|
| Public repo, standard runner | **free** — "The use of standard GitHub-hosted runners is free" ([billing docs](https://docs.github.com/en/billing/concepts/product-billing/github-actions)) |
| Larger runners (`-xlarge`) | **always charged**, even in public repos |
| Private repo, macOS 3/4-core | $0.062/min — roughly 10× the Linux rate, for reference only |

## 4. Recommended workflow

`.github/workflows/build.yml`:

```yaml
name: build

on:
  push:
    branches: [main]
  pull_request:

jobs:
  ios:
    runs-on: xcode-27
    steps:
      - uses: actions/checkout@v7
      - name: Toolchain
        run: xcodebuild -version
      - name: Build for device (unsigned)
        run: |
          xcodebuild \
            -project ImageBackup.xcodeproj \
            -target ImageBackup \
            -sdk iphoneos \
            -configuration Debug \
            CODE_SIGNING_ALLOWED=NO \
            build
```

Why these choices:

- **`-target`, not `-scheme`.** No shared scheme is committed — schemes live in `xcuserdata/`, which is gitignored — so `-scheme ImageBackup` has nothing to resolve in a fresh checkout. Building by target needs no scheme file. If that ever fails, share the scheme from Xcode (Product → Scheme → Manage Schemes → Shared) and commit it. *Unverified: whether Xcode 27 still accepts `-target`. It is the long-standing form and nothing suggests its removal, but the first run is the test.*
- **`CODE_SIGNING_ALLOWED=NO`** — compiles and links with no certificate or provisioning profile, which is all a compile check needs.
- **`xcodebuild -version` in its own step**, so a runner image change appears in the log instead of surfacing as a strange compile error.
- `actions/checkout@v7` is current (v7.0.1, 2026-07-20) — most tutorials still say `@v4`.

## 5. Optional: a smoke test that it launches

The image carries iOS 27 simulators, so CI can install and launch the app. That catches the two failures a compile cannot: a launch crash and an invalid `Info.plist`. It still cannot test photo access, the LAN prompt, or the NAS.

```yaml
      - name: Build for simulator
        run: |
          xcodebuild -project ImageBackup.xcodeproj -target ImageBackup \
            -sdk iphonesimulator -configuration Debug \
            -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
      - name: Boot, install, launch
        run: |
          xcrun simctl boot "iPhone 17"
          xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/ImageBackup.app
          xcrun simctl launch booted com.fdkevin.imagebackup
```

*Expect to adjust this one: the product path under `-derivedDataPath` is asserted from the documented layout, not observed. If `install` cannot find the `.app`, print the real path with `xcodebuild -showBuildSettings`. The app is expected to launch to its form; the photo prompt will not appear on the Simulator (TN3179).*

## 6. Optional: a structural check in seconds

A Linux job (free, 1× minutes, no queue) that parses `ImageBackup.xcodeproj/project.pbxproj` and asserts that no object reference dangles. That is the failure mode of hand-editing the file, and it otherwise surfaces only as "Xcode refuses to open the project".

Trade-off: roughly 40 lines of Python to maintain, asserting structure rather than correctness. Worth it while this file is being edited by hand or by agents; skip it if it won't be.

## 7. What CI cannot do

- **No device and no NAS.** The photo library, the local-network permission prompt (TN3179), and the ATS exceptions against a real `192.168.x.x` address all need the physical test in `app/README.md`. That is the test this project is actually waiting on.
- **No App Store upload.** Not a packaging or distribution path either — see the companion docs.

## 8. What the first run settles

1. **That the project file builds at all.** The synchronized group pointing at `app/`, the `membershipExceptions` that keep `Info.plist` out of Copy Bundle Resources, `INFOPLIST_FILE`, `GENERATE_INFOPLIST_FILE = NO` — none of it has been through real Xcode. This is the single most valuable thing CI does for this repo today.
2. **`-target` acceptance** by Xcode 27 (§4).
3. **Apple's compiler agreeing with the local one.** `SWIFT_VERSION = 6.0` with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` was verified with a Linux Swift 6.4 against the same SDK — close, not identical.

---

## Sources

- [GitHub Changelog, 2026-09-10 — "Xcode 27 runner image now runs on macOS 27"](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/) — labels, arm64-only, preview status
- [`actions/runner-images` — `xcode-27-arm64-Readme.md`](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) — OS build, Xcode version/path, installed SDKs and simulators
- [`actions/runner-images` issue #14404](https://github.com/actions/runner-images/issues/14404) — Xcode 27 preview availability and capacity caveat
- [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) — public-repo free standard runners, larger runners always billed, macOS rate
- [actions/checkout releases](https://github.com/actions/checkout/releases) — current major version
