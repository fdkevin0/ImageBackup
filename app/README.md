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
was found (`docs/photo-to-nas.md` §6.4 carries the measurements). A `412` on your NAS proves
nothing about the next one, so nothing depends on it.

## Build

Three sources, no dependencies. Deployment target **iOS 27** (`PHAssetResource.dataSize` is 27.0+;
delete that one line in `BackupEngine.upload` to build on 17+).

**Xcode:** new iOS App project → drag these three `.swift` files in → set the target to iOS 27.

**xtool:** not wired up — `xtool dev` needs a SwiftPM package (`Package.swift`), and this directory
is three loose files. Either create one, or use Xcode. The ExtensionKit blocker in
`docs/ios-dev-on-linux.md` §9 does not apply here: this MVP has no extension.

## Required Info.plist keys

Without these the app either can't read the library or silently can't reach the NAS.

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Backs up your photos to your own NAS.</string>

<key>NSLocalNetworkUsageDescription</key>
<string>Uploads your photos to a NAS on your local network.</string>

<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

`NSAllowsLocalNetworking` is what permits a plain `http://` NAS address without disabling ATS
wholesale. Use `https://` and you don't need it.

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
| EDITED versions (`fullSize*`) and edit history (`adjustment*`) | You see unedited photos on the NAS and it bothers you — research §6.5 |
| A persistent upload index (skips by HEAD only) | You want the app to know *why* a file is there, or to survive offline |
| Keychain `kSecAttrAccessible` tuning, biometric gating | Never, for a personal test build |
| Progress within a single file | You have videos so large the per-asset counter feels frozen |
