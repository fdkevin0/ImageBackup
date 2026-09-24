# ImageBackup

An iOS app that backs the user's photo library up to their own NAS, built on Apple's PhotoKit
background-upload API rather than a home-grown transfer engine.

Research first, then prove the transport. Start with whichever line below matches what you need.

| | |
|---|---|
| **Why this design, and what it can't do** | [`docs/photo-to-nas.md`](docs/photo-to-nas.md) — the Apple SDK survey, the storage layout, and the recommendation. §11 lists what is still unverified. |
| **Building it from Linux** | [`docs/ios-dev-on-linux.md`](docs/ios-dev-on-linux.md) — toolchains, VMs, cloud Macs. Its §9 records the ExtensionKit blocker for the PhotoKit path. |
| **Running something now** | [`app/README.md`](app/README.md) — the foreground WebDAV MVP: three Swift files, no dependencies, plus a script that checks your NAS before you build. |

## State

- The **MVP works in the foreground**: date range → photo library → WebDAV `PUT`, with the
  collision and folder-creation rules from the research already implemented.
- The **background path is unbuilt**. It needs an app extension, a paid team, and a physical
  device — and one experiment before anything else: whether the system's uploader can be aimed at
  an arbitrary user-supplied NAS hostname (`BackgroundUploadURLBase` validation,
  `docs/photo-to-nas.md` §11.1). That single test decides the architecture.

## Constraints

- Research before building; use Apple's SDK where one fits rather than re-implementing it.
- Everything here is deliberately dependency-free.
