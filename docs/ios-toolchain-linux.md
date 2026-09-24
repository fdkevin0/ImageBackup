# iOS Toolchain on Linux — Local Setup, Usage & Maintenance, 2026-09-24

**Scope:** operating and maintaining the iOS build toolchain on *this* machine (Ubuntu 26.04.1 LTS, x86_64, 6 cores / 19 GB RAM). What is installed and where, how to use it daily, how to update each piece, and how to work around the one upstream bug that currently affects it.
**Companion doc:** [`ios-dev-on-linux.md`](./ios-dev-on-linux.md) — the survey of *why* this stack was chosen and what the alternatives are. This document is the operational counterpart: it assumes that decision has been made and covers running it.
**Facts as of:** 2026-09-24. This file states versions and paths, not guarantees — re-verify with §8 rather than trusting the dates here.

---

## TL;DR

1. **The stack works end to end.** xtool 1.20.1 + Swift 6.4.0 (via swiftly 1.2.0) + a Darwin Swift SDK extracted from Xcode 27.0 builds, signs and packages a real iOS app. Verified output: `Mach-O 64-bit arm64`, `CFBundleSupportedPlatforms: ['iPhoneOS']`, `MinimumOSVersion: 17.0`.
2. **There is no simulator on Linux.** A connected iPhone over USB is the only way to run what you build. `usbmuxd` and `libimobiledevice` are already installed.
3. **One upstream bug blocks every `swiftly install` / `swiftly update` here.** swiftly downloads swift.org's GPG key file and writes the gzip-encoded body to disk without decompressing it, so `gpg --import` fails and the install aborts. A small wrapper fixes it *without* weakening signature verification — §4.1. The copy currently at `/tmp/gpgfix/gpg` is in `/tmp` and **will not survive a reboot**; §4.1 has the durable version.
4. **Disk footprint ≈ 15 GB**: SDK 9.4 GB + Swift toolchain 3.6 GB + `Xcode_27.xip` 1.9 GB. The xip is deletable, but you need it again to re-extract the SDK — keep it unless space is tight.
5. **`xtool dev build --ipa` packages the IPA itself** — 1.20.1 has both `--ipa` and `--sign`. Without `--sign` the result is unsigned (no `_CodeSignature`) and a device will refuse it. Do not look for either flag under `xtool dev --help`, which lists only subcommands; they are on `dev build` (§3).
6. **Deadline worth a calendar entry:** the App Store SDK floor lands around **April 2027** (iOS 27 SDK ⇒ Xcode 27). Plan the next SDK re-extraction before then (§4.4).

---

## 1. What is installed, and where

| Component | Version | Path | Role |
|---|---|---|---|
| xtool | 1.20.1 | `/usr/local/bin/xtool` (static ELF, 56 MB) | Driver: SwiftPM → `.app`, signing, device operations |
| Swift toolchain | 6.4.0 | `~/.local/share/swiftly/toolchains/6.4.0` (3.6 GB) | The compiler itself |
| swiftly | 1.2.0 | `~/.local/share/swiftly/bin/swiftly` | Toolchain manager |
| Darwin Swift SDK | `epoch=2, darwinTools=1.1.0, oam=1.3.0` | `~/.swiftpm/swift-sdks/darwin.artifactbundle` (9.4 GB) | iOS + macOS SDKs and the Xcode default toolchain |
| Xcode source archive | Xcode 27.0 (`27A266a`) | `~/Xcode_27.xip` (1.9 GB) | Input for (re)building the Darwin SDK |
| Apple credentials | — | `~/.config/xtool/data/` (`XTLAuthToken`, `XTLProvisioningInfo`, `XTLLocalUserUID`, `XTLRoutingInfo`) | Code signing / provisioning. **Secret, user-specific — never commit** |
| Device stack | libimobiledevice 1.4.0, usbmuxd 1.1.1 | `/usr/sbin/usbmuxd`, `/usr/bin/idevice_id` | USB transport to the iPhone |

**PATH wiring:** `~/.config/fish/config.fish` line 128 sources `~/.local/share/swiftly/env.fish`, which prepends `~/.local/share/swiftly/bin` to `PATH`. That directory holds the `swift`/`swiftc` shims that point at the active toolchain. New shells get it automatically; a shell that predates the install needs `hash -r` or a restart.

---

## 2. How the pieces fit

```
 Xcode_27.xip ──(xtool sdk build)──► ~/.swiftpm/swift-sdks/darwin.artifactbundle
                                      ├── Developer/Platforms/iPhoneOS.platform/…/iPhoneOS.sdk   (250 MB)
                                      ├── Developer/Platforms/MacOSX.platform/…/MacOSX27.0.sdk
                                      └── Developer/Toolchains/XcodeDefault.xctoolchain
                                                    │
 swiftly ──► swift 6.4.0 compiler ───────────────────┤
                                                    ▼
                                          xtool: swift build --swift-sdk darwin
                                                    ▼
                                       .app  ──►  sign  ──►  install to device
```

The important consequence: **the iOS SDK comes from an `Xcode.xip` you supply, but Xcode itself never runs and no Mac is involved.** xtool extracts the SDK and hands it to SwiftPM as a Swift SDK.

Target triples present in the SDK: `arm64-apple-ios`, `arm64-apple-ios-simulator`, `x86_64-apple-ios-simulator`, `arm64-apple-macosx`, `x86_64-apple-macosx`. The simulator triples can be *built* but not *run* on Linux.

---

## 3. Daily use

```bash
# A new shell already has swift on PATH. In an old one:
hash -r    # bash   |   rehash    # fish

xtool auth status                 # Apple ID, team ID, token expiry
xtool sdk status                  # Darwin SDK presence/version
```

**Create a project** (creates `Package.swift`, `xtool.yml`, `.gitignore`, `Sources/<Name>/`):

```bash
xtool new MyApp
```

**Build** — writes `xtool/MyApp.app`:

```bash
cd MyApp
xtool dev build
xtool dev build --triple arm64-apple-ios-simulator   # builds for the sim target (cannot be run here)
```

**Build + run on a device** (installs and launches over USB):

```bash
xtool dev                        # = run; the default subcommand
```

**Device operations:**

```bash
xtool devices [--usb|--network|--all] [--wait]   # list; --wait blocks until one appears
xtool install  [--udid <udid>] <path>            # accepts an .app or an .ipa
xtool launch   <bundle-id> [args…]
xtool uninstall <bundle-id>
```

**Other useful subcommands:**

```bash
xtool dev generate-xcode-project   # emit an Xcode project — the handoff path to a Mac
xtool sdk install|update|remove|status
xtool auth login|logout|status
```

**Project toolchain pin — `.swift-version`.** swiftly selects the toolchain from this file when it is present in the working directory **or any parent**, and it is designed to sit at the repository root and be committed so every contributor builds with the same version ([swiftly docs](https://github.com/swiftlang/swiftly/blob/main/Documentation/SwiftlyDocs.docc/use-toolchains.md)). This repo pins `6.4.0`.

```bash
swiftly use 6.4.0                   # writes/updates .swift-version at the repo root
swiftly use --global-default 6.4.0  # machine-wide default; never creates the file
swiftly install                     # with no argument, installs the pinned version
```

**Producing an IPA.**

```bash
xtool dev build --ipa          # writes xtool/MyApp.ipa
xtool dev build --ipa --sign   # signed with the credentials from `xtool auth`
```

The output is the standard layout — `Payload/MyApp.app/` holding the binary and `Info.plist`, zipped (verified: 4 entries for a single-target app). Without `--sign` there is no `_CodeSignature` directory, so the archive installs on nothing. If you need the manual form — to drop a file into the bundle, say — the layout is exactly that directory zipped:

```bash
mkdir -p Payload && cp -R xtool/MyApp.app Payload/
zip -qry MyApp.ipa Payload
```

Uploading that IPA to App Store Connect does not require a Mac (see companion doc §6 for the `iTMSTransporter` / App Store Connect API routes).

---

## 4. Maintenance

### 4.1 The GPG workaround — required for every toolchain install

**Symptom.** `swiftly install` fails right at the start:

```
Error: RunProgramError(terminationStatus: exited(2), config: Configuration(
    executable: executable(gpg), arguments: ["--import", "/tmp/swiftly-XXXXXXXX"], …
))
```

Note swiftly swallows gpg's stderr, so you never see gpg's own message (*"no valid OpenPGP data found"*). Add a PATH wrapper to see it, or trust the diagnosis below.

**Root cause.** `swiftly` downloads swift.org's key bundle and writes the HTTP body straight to a temp file, then imports that file — with no decompression step:

```swift
// Sources/LinuxPlatform/Linux.swift:506 (1.2.0); same pattern inline at :276 in 1.1.4
private func importGpgKeys(_ ctx: SwiftlyCoreContext) async throws {
    let tmpFile = self.getTempFilePath()
    try await fs.create(.mode(0o600), file: tmpFile, contents: nil)
    try await fs.withTemporary(files: tmpFile) {
        try await ctx.httpClient.getGpgKeys().download(to: tmpFile)   // ← gzip body, written verbatim
        try await sys.gpg()._import(key: tmpFile).run(quiet: true)
    }
}
```

swift.org serves that endpoint gzip-encoded, and Foundation **on Linux** does not decode `Content-Encoding` (on macOS URLSession does — which is why this is rarely reported). gpg cannot read a bare gzip stream, so the import fails.

**Evidence it is exactly this:** the temp file begins with `1f 8b`; gunzip yields the genuine 21975-byte key bundle; swift.org's own copy (`https://www.swift.org/keys/all-keys.asc`) is byte-identical in size at 12782 gzipped. The same diagnosis, with the same byte counts, was filed as [swift-org-website#1328](https://github.com/swiftlang/swift-org-website/issues/1328) — and fixed only in the *documentation*, by adding `curl --compressed` to the install page ([PR #1432](https://github.com/swiftlang/swift-org-website/pull/1432)). **The program was never fixed, and nobody has filed it against swiftly.**

**Not a 1.2.0 regression.** 1.1.4 contains the same download-then-import code, so downgrading does not help.

**The fix.** A wrapper that decompresses *only* the argument following `--import` and passes everything else — including the ~1 GB signed tarball — straight through. Signature verification still runs for real:

```bash
#!/bin/bash
# ~/.local/libexec/gpgzipfix/gpg
ARGS=(); prev=""
for a in "$@"; do
  if [ "$prev" = "--import" ] && [ -f "$a" ] && [ "$(head -c 2 "$a" | xxd -p 2>/dev/null)" = "1f8b" ]; then
    t=$(mktemp /tmp/gpgfix-XXXXXX.gpg)
    if gunzip -c "$a" > "$t" 2>/dev/null; then ARGS+=("$t"); prev="$a"; continue; fi
  fi
  ARGS+=("$a"); prev="$a"
done
exec /usr/bin/gpg "${ARGS[@]}"
```

Install it durably (the current copy is in `/tmp` and will be lost on reboot):

```bash
mkdir -p ~/.local/libexec/gpgzipfix
# write the script above to ~/.local/libexec/gpgzipfix/gpg
chmod +x ~/.local/libexec/gpgzipfix/gpg
```

Then either prefix each install manually:

```bash
PATH=$HOME/.local/libexec/gpgzipfix:$PATH swiftly install 6.4.0
```

…or make it automatic in fish, **without shadowing `gpg` for anything else**:

```fish
# ~/.config/fish/functions/swiftly.fish
function swiftly
    set -lx PATH $HOME/.local/libexec/gpgzipfix $PATH
    command swiftly $argv
end
```

**Do not use `--no-verify`.** That disables signature verification of the downloaded toolchain; the wrapper preserves it. A newer gpg from Homebrew does **not** help — GnuPG has no gzip handling on the import path (`g10/import.c` has zero matches for `gzopen|gzip|inflate`), and installing it would shadow `/usr/bin/gpg` (Homebrew's bin is 2nd in `PATH`, `/usr/bin` 11th) while pulling ~40 dependencies.

> **Caveat:** the earlier, over-broad version of this wrapper decompressed *every* gzip argument, including the 1 GB tarball, which made verification fail with a BAD signature. The `prev = "--import"` guard is what makes it correct — do not drop it.

### 4.2 Updating the Swift toolchain

```bash
swiftly list-available                      # queries upstream for this platform
PATH=$HOME/.local/libexec/gpgzipfix:$PATH swiftly install <version>   # or: swiftly update
swift --version
```

swiftly **does not cache downloads**: if verification fails you pay for the full ~1 GB again. Get the wrapper working before starting.

### 4.3 Updating xtool

xtool has no self-update subcommand. Download the release binary from <https://github.com/xtool-org/xtool/releases> and replace `/usr/local/bin/xtool` (needs write access there), then check `xtool --version`. If the new version needs a newer SDK, do §4.4 as well — the installed SDK version is reported by `xtool sdk status`.

### 4.4 Updating the Darwin SDK / Xcode.xip

The SDK is rebuilt from an `Xcode.xip` you download yourself from <https://developer.apple.com/download/> with an Apple ID that has Xcode access.

```bash
xtool sdk build          # (re)build the SDK from the xip  (--arch <arch> to force host arch)
xtool sdk update         # update an already-installed SDK
xtool sdk status         # confirm
```

**Do this before ≈ April 2027**, when the App Store starts requiring the iOS 27 SDK. Budget ~15 GB free disk for the rebuild and a further 1.9 GB for the new xip.

### 4.5 Verifying signatures by hand

The wrapper keeps verification automated, but this is what it is doing — useful when something looks wrong:

```bash
curl --compressed -o /tmp/all-keys.asc https://www.swift.org/keys/all-keys.asc
gpg --import /tmp/all-keys.asc

BASE=https://download.swift.org/swift-6.4.0-release/ubuntu2604/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-ubuntu26.04.tar.gz
curl -O $BASE && curl -O $BASE.sig
gpg --verify $BASE.sig $BASE
```

Expected output:

```
gpg: Good signature from "Swift 6.x Release Signing Key <swift-infrastructure@forums.swift.org>" [expired]
gpg: Note: This key has expired!
```

**Exit code 0 — this is not an error.** The key genuinely expired on 2026-09-16 and the 6.4.0 tarball was signed 2026-09-14, two days earlier; the keyserver and swift.org both report the same expiry. If you ever see `BAD signature`, do *not* install the artifact.

### 4.6 Disk hygiene

| Action | Frees | Command |
|---|---|---|
| Remove the Darwin SDK | 9.4 GB | `xtool sdk remove` |
| Remove a Swift toolchain | 3.6 GB | `swiftly uninstall 6.4.0` |
| Delete the Xcode archive | 1.9 GB | `rm ~/Xcode_27.xip` — re-download before the next SDK update |

---

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `RunProgramError … executable(gpg) … exited(2)` during `swiftly install` | gzip-encoded key body (§4.1) | Use the wrapper |
| `Signature verification failed … exited(1)` | Wrapper decompressed the tarball too — the `--import` guard is missing | Restore the guard (§4.1) |
| `gpg: Good signature … [expired]` | The Swift 6.x key expired 2026-09-16 | Informational; exit code is 0. Not an error |
| `swift: command not found` | Shell predates the install | `hash -r` / `rehash`, or open a new shell |
| `Swiftly is currently unlinked…` | swiftly is not bound to a toolchain | `swiftly link` |
| `swiftly use` created a `.swift-version` in the repo | **Documented behaviour, not a side effect** — see §3 | Keep it committed as the project pin; use `swiftly use --global-default` for a machine-wide default that never writes the file |
| `.app` builds but nothing runs | No simulator on Linux | Connect a device; `xtool devices` then `xtool dev` |
| `xtool sdk status` shows nothing installed | SDK removed or never built | `xtool sdk build` against a local `Xcode.xip` |
| No devices listed | iPhone not trusted / not in USB mode | Unlock and "Trust", check `systemctl status usbmuxd` |

---

## 6. Known limitations

- **No simulator.** Simulator triples can be built but not run; any runtime behaviour must be checked on a physical device.
- **An unsigned IPA is refused by a device.** `--ipa` on its own writes no `_CodeSignature`; add `--sign` (§3).
- **No App Store upload step** in xtool. Use `iTMSTransporter` (there is an official Linux build) or the App Store Connect API — companion doc §6.
- **The xip is a hard dependency** for (re)building the SDK: keep an Apple ID with Xcode download access, and keep a copy of the archive if you care about reproducible rebuilds.
- **Free-tier Apple IDs** carry bundle-ID and provisioning restrictions; the account in use here has a team ID, so this has not been exercised.

---

## 7. Removal / rollback

```bash
xtool sdk remove                       # drop the Darwin SDK
swiftly uninstall 6.4.0                # drop the toolchain
rm -rf ~/.local/libexec/gpgzipfix      # drop the workaround
rm ~/Xcode_27.xip                      # drop the archive
xtool auth logout                      # drop stored credentials
# remove the PATH wiring: delete line 128 of ~/.config/fish/config.fish
```

Nothing here touches system packages, so every step is reversible by reinstalling.

---

## 8. Verification appendix

The end-to-end check that this setup works. Expected outputs in comments.

```bash
swift --version                       # Swift version 6.4 (swift-6.4-RELEASE) / x86_64-unknown-linux-gnu
xtool --version                       # 1.20.1
xtool sdk status                      # "Darwin SDK is installed" + path + version tuple
xtool auth status                     # logged in; note token expiry

cd /tmp && rm -rf smoke && mkdir smoke && cd smoke
xtool new SmokeTest --skip-setup
cd SmokeTest && xtool dev build       # "Build complete! … Wrote to …/xtool/SmokeTest.app"

file xtool/SmokeTest.app/SmokeTest    # Mach-O 64-bit arm64 executable
python3 -c "import plistlib;d=plistlib.load(open('xtool/SmokeTest.app/Info.plist','rb'));print(d['CFBundleSupportedPlatforms'], d['MinimumOSVersion'])"
                                      # ['iPhoneOS'] 17.0
xtool dev build --ipa                 # writes xtool/SmokeTest.ipa
unzip -l xtool/SmokeTest.ipa          # Payload/SmokeTest.app/… — no _CodeSignature until --sign
```

A build completes in ~6 s cold on this host. If it does, the whole chain — Swift toolchain, Darwin SDK, xtool, signing setup — is intact.
