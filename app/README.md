# ImageBackup — WebDAV MVP

Foreground-only. Picks a date range, walks the photo library, PUTs each original to your NAS.

**Not** the `PHAssetResourceUploadJob` path from the research. That's the right destination, but it
needs an app extension, entitlements, a paid team and a physical device before it can be tested at
all. This MVP proves the two things that would sink the real thing — that your NAS accepts the
transport, and that the folder layout holds up on real photos.

## Before you build: check your server

Run this against the real NAS first.

```sh
../scripts/verify-webdav.sh http://192.168.1.10:5005/PhotoBackup user 'password'
```

It tests the handful of `MKCOL`/`HEAD`/`PUT` behaviours the app depends on. **The important one is
HEAD** — that's how the app decides a file is already backed up.

It also reports conditional `PUT` (`If-None-Match: *`) as *informational, not pass/fail*, because
that header is not dependable: rclone's WebDAV ignores it and silently overwrites, and the same
server returned `412` once and `201` the next time. The app was rewritten around HEAD after that
was found ([`../docs/photo-to-nas.md`](../docs/photo-to-nas.md) §6.4 carries the measurements). A `412` on your NAS proves
nothing about the next one, so nothing depends on it.

## Build

Three sources, no dependencies. Deployment target **iOS 27** — `PHAssetResource.dataSize` and
`PHAssetResource.filename` are both 27.0+ (the latter replaced `originalFilename`, deprecated in 27;
it is nullable, so `BackupEngine.filename(of:)` falls back to a UUID). Swap those two to build on 17+.

**Xcode:** open `../ImageBackup.xcodeproj`, set your signing team, run on a physical device. This
folder is a *synchronized* group, so files in it compile without being added to the project by hand.

**xtool (from Linux):** wired up — `xtool dev build` at the repo root writes
`xtool/ImageBackup.app`, and `--ipa` packages it (add `--sign` to make it installable). Toolchain
setup and troubleshooting live in [`../docs/ios-toolchain-linux.md`](../docs/ios-toolchain-linux.md).
The ExtensionKit blocker in [`../docs/ios-dev-on-linux.md`](../docs/ios-dev-on-linux.md) §9 does not
apply here: this MVP has no extension.

## Info.plist

`app/Info.plist` is the target's plist (`GENERATE_INFOPLIST_FILE = NO`). Three keys in it matter:

- `NSPhotoLibraryUsageDescription` — without it the app is killed the moment it asks for the library.
- `NSLocalNetworkUsageDescription` — without it the LAN connection is refused with no prompt shown.
- `NSAppTransportSecurity` — iOS 17+ blocks IP-address loads; the private ranges are excepted here.
  Enter your NAS as a hostname (`nas.local`) and none of it applies, nor does it for `https://`.

The file exists because `NSAppTransportSecurity` is a nested dictionary that a build setting cannot
express — and `INFOPLIST_KEY_*` drops unknown keys silently.

Keep `Info.plist` and `README.md` out of the target (`membershipExceptions` in the project file) — a
second plist in this folder breaks the build on `Multiple commands produce`.

The xtool build reads `ImageBackup-Info.plist` at the repo root instead — the same three keys but
token-free, because xtool merges that file over its own generated plist and does not expand
`$(BUILD_SETTING)`. **Change an ATS rule or a usage string and both files need it.**

## Testing notes

- **Test on a physical device.** The local-network permission prompt doesn't appear in the
  Simulator, so a Simulator run fails with a network error and no prompt (TN3179).
- **Accept the local network prompt when it appears.** If it was denied, the app gets errors with no
  prompt ever shown again — fix it in Settings → Privacy → Local Network.
- **"Device folder" defaults to `iPhone`.** iOS 16+ returns a generic name from `UIDevice.current.name`
  unless the app has the device-name entitlement, so type your own label here.
- **Run it twice.** The second run should log `= … (already there)` and upload nothing — that's the
  HEAD-before-PUT check working. If it re-uploads, HEAD isn't behaving (run `scripts/verify-webdav.sh`).
- **Watch for `!` lines.** Those are name collisions: a different asset already owns that filename,
  detected by a `Content-Length` mismatch. Nothing was overwritten. Note how often it fires and on
  what — that tells you whether renaming is worth building.

## Skipped on purpose

| Skipped | Add when |
|---|---|
| Background upload (`PHAssetResourceUploadJob` + extension) | The transport is proven and you have a paid team ID |
| Renaming on collision (currently: logged and skipped) | You see `!` lines — first learn how often and why |
| Resumable upload (`104` + `Location`) | You're routinely failing on multi-GB videos |
| EDITED versions (`fullSize*`) and edit history (`adjustment*`) | You see unedited photos on the NAS and it bothers you — [research](../docs/photo-to-nas.md) §6.5 |
| A persistent upload index (skips by HEAD only) | You want the app to know *why* a file is there, or to survive offline |
| Keychain `kSecAttrAccessible` tuning, biometric gating | Never, for a personal test build |
| Progress within a single file | You have videos so large the per-asset counter feels frozen |
