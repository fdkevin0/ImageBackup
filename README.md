# ImageBackup

An iOS app that backs the user's photo library up to their own NAS, built on Apple's PhotoKit
background-upload API rather than a home-grown transfer engine.

Research first, then prove the transport. Start with whichever line below matches what you need.

| | |
|---|---|
| **Why this design, and what it can't do** | [`docs/photo-to-nas.md`](docs/photo-to-nas.md) — the Apple SDK survey, the storage layout, and the recommendation. §11 lists what is still unverified. |
| **Choosing a Linux setup** | [`docs/ios-dev-on-linux.md`](docs/ios-dev-on-linux.md) — toolchains, VMs, cloud Macs, and why. Its §9 records the ExtensionKit blocker for the PhotoKit path. |
| **Operating this machine's setup** | [`docs/ios-toolchain-linux.md`](docs/ios-toolchain-linux.md) — what is installed here, daily commands, the swiftly GPG workaround, upkeep. |
| **Running the app** | [`app/README.md`](app/README.md) — the foreground WebDAV MVP. Open `ImageBackup.xcodeproj` on a Mac, or `xtool dev build` here. |
| **Compiling it in CI** | [`docs/ci-github-actions.md`](docs/ci-github-actions.md) — the `xcode-27` runner is the only image with the iOS 27 SDK, and it is free on this public repo. |

## State

- The **MVP is written, compiles, and packages** — `xtool dev build` on Linux produces an arm64
  `.app` (and an unsigned `.ipa` with `--ipa`). **It has not run against a NAS or on a device yet.**
- The **background path is unbuilt**. It needs an app extension, a paid team, and a physical
  device — and one experiment before anything else: whether the system's uploader can be aimed at
  an arbitrary user-supplied NAS hostname (`BackgroundUploadURLBase` validation,
  `docs/photo-to-nas.md` §11.1). That single test decides the architecture.

## Constraints

- Research before building; use Apple's SDK where one fits rather than re-implementing it.
- Everything here is deliberately dependency-free.
