# ImageBackup

An iOS app that backs the user's photo library up to their own NAS, built on Apple's PhotoKit
background-upload API rather than a home-grown transfer engine.

Research first, then prove the transport. Start with whichever line below matches what you need.

| | |
|---|---|
| **Why this design, and what it can't do** | [`docs/photo-to-nas.md`](docs/photo-to-nas.md) — the Apple SDK survey, the storage layout, and the recommendation. §11 lists what is still unverified. |
| **Choosing a Linux setup** | [`docs/ios-dev-on-linux.md`](docs/ios-dev-on-linux.md) — toolchains, VMs, cloud Macs, and why. The ExtensionKit blocker for the PhotoKit path is written up in [`docs/photo-to-nas.md`](docs/photo-to-nas.md) §9, not there. |
| **Operating this machine's setup** | [`docs/ios-toolchain-linux.md`](docs/ios-toolchain-linux.md) — what is installed here, daily commands, the swiftly GPG workaround, upkeep. |
| **Running the app** | [`app/README.md`](app/README.md) — the foreground WebDAV MVP. Open `ImageBackup.xcodeproj` on a Mac, or `xtool dev build` here. |
| **Compiling it in CI** | [`docs/ci-github-actions.md`](docs/ci-github-actions.md) — the `xcode-27` runner is the only image with the iOS 27 SDK, and it is free on this public repo. |

## State

- The foreground transport and layout are proven against a real NAS; repeated runs upload nothing.
- Runs retry transient failures and advance their watermark only after a clean pass.
- Unattended backup remains unbuilt; [`app/README.md`](app/README.md) tracks the blockers and fallback.

## Constraints

- Research before building; use Apple's SDK where one fits rather than re-implementing it.
- Everything here is deliberately dependency-free.
