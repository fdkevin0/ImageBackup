# ImageBackup — WebDAV foreground app

Foreground-only. Walks the photo library from a watermark, and PUTs each original to your NAS.
**The transport and the layout are proven** against a real rclone WebDAV server; what is left is
making it unattended.

Three screens, no more: a **Welcome** screen that appears only before a server address exists, a
**home** screen whose job is to answer "are my photos backed up?" and offer one button, and
**Settings** behind the gear — WebDAV and what does and does not get uploaded.

**Not** the `PHAssetResourceUploadJob` path from the research. That is still the destination, and it
is still gated on two things: an on-device experiment (does the system uploader accept an arbitrary
NAS hostname — [`../docs/photo-to-nas.md`](../docs/photo-to-nas.md) §11.1) and ExtensionKit support
in xtool, which does not exist yet (`photo-to-nas.md` §9, xtool issue #138). The research's §2
fallback — background `URLSession` + `BGProcessingTask`, no extension — is the next stage and is
buildable from Linux today.

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

No dependencies. Deployment target **iOS 27** — `PHAssetResource.dataSize` and
`PHAssetResource.filename` are both 27.0+ (the latter replaced `originalFilename`, deprecated in 27;
it is nullable, so `BackupEngine.filename(of:)` falls back to a UUID). Swap those two to build on 17+.

**Xcode:** open `../ImageBackup.xcodeproj`, set your signing team, run on a physical device. This
folder is a *synchronized* group, so files in it compile without being added to the project by hand.

**xtool (from Linux):** wired up — `xtool dev build` at the repo root writes
`xtool/ImageBackup.app`, and `--ipa` packages it (add `--sign` to make it installable). Toolchain
setup and troubleshooting live in [`../docs/ios-toolchain-linux.md`](../docs/ios-toolchain-linux.md).
The ExtensionKit blocker — written up in [`../docs/photo-to-nas.md`](../docs/photo-to-nas.md) §9,
not in the toolchain doc — does not apply here: this app has no extension.

Packaging lives in `../xtool.yml`. Its bundle ID must match the Xcode project, its icon is
`../Artwork/AppIcon.png`, and it copies `PrivacyInfo.xcprivacy` to the app bundle root. The Keychain
service follows the bundle ID automatically.

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

The xtool build reads the token-free `ImageBackup-Info.plist` at the repo root. **Change an ATS rule,
a usage string, or the version in both plists.**

## What a run does

- **Two windows, two buttons, no date pickers.** *Back up now* covers since the last run (less a
  week of overlap); *Back up everything* is the escape hatch for the hole below. The watermark and
  the last run's summary live in UserDefaults.
- **Known hole in that default:** the walk filters on `creationDate`, so a photo *taken* long ago but
  *imported* after the last run — a camera-roll import, an AirDrop from another phone — falls outside
  the window until you press "Everything". The fix is delta selection via a persistent change token
  (research §2), which is stage 2.
- **One bad file no longer ends the run.** Each file gets three attempts on transient failures
  (timeouts, 5xx, 429); anything else — a 401, a 405 — is not retried at all, because retrying
  configuration only delays the message. Three consecutive failures stop the run with the last error
  rather than grinding through the rest.
- **Failures are listed by path** in the Progress section, because a count you cannot act on is not a
  report.
- **The watermark advances only after a clean run.** A run with failures leaves it where it was, so
  the next run re-covers the same window instead of burying those files behind it forever.
- **Limited photo access is called out.** Under `.limited` the walk sees only the photos you picked,
  and a run that looks complete would be an incomplete backup.

## Testing notes

- **`sh ../scripts/check-pure-logic.sh` runs before you ever touch a device.** It compiles the
  Foundation-only retry policy and asserts its decision table on Linux or in CI.
- **Test on a physical device.** The local-network permission prompt doesn't appear in the
  Simulator, so a Simulator run fails with a network error and no prompt (TN3179).
- **Accept the local network prompt when it appears.** If it was denied, the app gets errors with no
  prompt ever shown again — fix it in Settings → Privacy → Local Network.
- **"Device folder" is optional.** Leave it empty for one `YYYY/MM` tree, or set a label to keep
  multiple devices separate.
- **Run it twice.** The second run should upload nothing — that's the HEAD-before-PUT check working.
  If the "Uploaded" counter moves, HEAD isn't behaving (run `scripts/verify-webdav.sh`).
- **Add one photo, run again.** Exactly one upload, which is the watermark plus that HEAD check.
- **Pull the Wi-Fi mid-run.** The run should finish with failed paths listed, not abort; restore the
  network and run again to retry them.
- **Watch the "Skipped" line.** It counts name collisions: a different asset already owns that
  filename, detected by a `Content-Length` mismatch. Nothing was overwritten. A non-zero count on
  your library is the signal that deterministic renaming is worth building.
- **"Unverified" is not "fine".** It counts paths the server would not report a size for, so the app
  can neither confirm nor replace them. A server that never sends `Content-Length` on HEAD will make
  every file after the first run unverified.

## Skipped on purpose

| Skipped | Add when |
|---|---|
| Background upload (`PHAssetResourceUploadJob` + extension) | The §11.1 experiment is run on a device **and** xtool supports ExtensionKit (issue #138) |
| Unattended runs without an extension (research §2: background `URLSession` + `BGProcessingTask`) | Next stage — buildable from this Linux box today |
| Renaming on collision (counted and skipped) | The `Skipped` count is non-zero on your library |
| Arbitrary sync ranges (date pickers) | The watermark plus "everything" stops covering the case — a custom window is then one sheet, not four pieces of view state |
| Resumable upload (`104` + `Location`) | You're routinely failing on multi-GB videos |
| Edited *renders* (`fullSize*`) | Never, without a reason: they are derivable from the original plus its adjustment data (research §6.5) |
| `adjustmentBase*` resources | Something shows they do not duplicate the original — `adjustmentData` is already uploaded |
| Delta selection by `PHPersistentChangeToken` | Stage 2, where it also closes the late-import hole above |
| A per-asset upload index | A run stops being cheap — today the watermark means a run only walks what is new |
| Keychain `kSecAttrAccessible` tuning, biometric gating | Never, for a personal test build |
| An `Assets.xcassets` app icon | Someone builds on a Mac: `iconPath` covers the xtool build, the Xcode build has no icon until a catalogue exists |
| Progress within a single file | You have videos so large the per-asset counter feels frozen |
