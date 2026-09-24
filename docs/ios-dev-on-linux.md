# iOS Development on Linux — State of the Art, 2026-09-24

**Scope:** how to build/ship iOS apps from an Ubuntu-family x86_64 Linux box, and whether local macOS VMs are a mature option.
**All sources last verified:** 2026-09-24 (unless a version/date is stated inline).
**Method:** primary sources preferred (GitHub APIs for repo/release dates, vendor docs/pricing pages, Apple developer news). Where only secondary sources exist, that is flagged explicitly.
**Companion docs:** [`photo-to-nas.md`](./photo-to-nas.md) — the app this toolchain question was raised to build; its §9 is where this doc's ExtensionKit finding becomes a blocker. [`ios-toolchain-linux.md`](./ios-toolchain-linux.md) — the operational counterpart, for the machine where the stack is already installed: stop reading this survey and go there.

---

## TL;DR

1. **2026 changed the local-VM answer decisively.** macOS 26 "Tahoe" is the **final macOS release for Intel Macs**; macOS 27 "Golden Gate" (released **2026-09-14**) is **Apple silicon only** ([Apple Developer News, 2026-09-09](https://developer.apple.com/news/?id=k1mtkt1k)). Xcode 27 is reported **Apple-silicon-only** ([byteiota](https://byteiota.com/xcode-27-is-out-apple-silicon-only-swift-6-4-agents/), [blakecrosley](https://blakecrosley.com/zh-Hant/blog/xcode-27-release), [DevelopersIO release-notes summary](https://dev.classmethod.jp/articles/xcode-27-ios-27-beta-release-notes/)) — note Apple's own [system-requirements page](https://developer.apple.com/xcode/system-requirements/) does not list a hardware row, so this is **high-confidence-but-secondary** (see §9).
2. **Therefore "hackintosh-in-a-VM" on an x86_64 Linux host is now a dead end for new work.** It can never run Xcode 27, and the practical ceiling is macOS 26 Tahoe + Xcode 26.x. Combined with the **April 2027 App Store SDK floor** (iOS 27 SDK → Xcode 27), Intel-on-KVM has an **expiry date of roughly April 2027** for App Store uploads.
3. **The genuinely interesting 2026 development is `xtool`**, which builds and signs real iOS apps from **Linux x86_64** using the Swift 6.4 toolchain plus a Darwin Swift SDK that *you extract from `Xcode.xip` yourself*. Latest release **1.20.1 (2026-09-21)** explicitly supports **Xcode 27** and Swift 6.4 ([GitHub API](https://github.com/xtool-org/xtool/releases)). It is the only path that plausibly satisfies the April 2027 SDK rule with no Mac anywhere. No longer theoretical: the companion app was built into a real arm64 `.app` this way on 2026-09-24 ([`ios-toolchain-linux.md`](./ios-toolchain-linux.md)).
4. **The reliable, boring answer remains rented Apple hardware.** Scaleway Mac mini M1 at **€75/mo / €0.11/hr** ([pricing](https://www.scaleway.com/en/pricing/apple-silicon/)) and MacStadium M2.S at **$109/mo** ([pricing](https://www.macstadium.com/pricing)) are the cheapest compliant persistent GUI boxes; AWS EC2 Mac is **$1.23/hr for `mac-m4.metal`** with a mandatory **24-hour** minimum ([AWS docs](https://docs.aws.amazon.com/en_jp/AWSEC2/latest/UserGuide/ec2-mac-instances.md), secondary price source [bigbell.ai](https://bigbell.ai/coin/aws/ec2/mac-m4.metal)).
5. **For cross-platform frameworks, the "develop on Linux, rent only the final build" split is real and mature.** Expo **EAS Build** (free tier: 15 iOS builds/mo; $2/build medium worker) + **EAS Submit** (free, accepts any valid `.ipa`, not just EAS-built ones) removes the Mac from a solo dev's loop ([expo.dev/pricing](https://expo.dev/pricing), [docs.expo.dev/submit](https://docs.expo.dev/deploy/submit-to-app-stores.md)).
6. **Uploading from Linux is officially supported now.** Apple's `iTMSTransporter` ships Linux builds, and the App Store Connect API added a **build-upload REST flow** (`POST /v1/buildUploads` + `buildUploadFiles`) at WWDC 2025 ([Apple docs](https://developer.apple.com/documentation/appstoreconnectapi/build-uploads)). `altool` needs macOS; `notarytool` is irrelevant to App Store uploads.
7. **Metal is the reason simulators fail in VMs.** Since Xcode 11 the Simulator renders via Metal; no Metal device = black simulator window. The new **`reims-vgpu`** project (created 2026-07-26, alpha) implements a paravirtual GPU for QEMU macOS guests by attaching to macOS's built-in `AppleParavirtGPU.kext` and translating Metal→Vulkan on the host — **the most plausible 2026 route to a working simulator inside a KVM macOS VM, but unverified for that use** ([steelbrain/reims-vgpu](https://github.com/steelbrain/reims-vgpu)).

---

## 0. 2026 timeline of relevant changes

| Date | Event | Source |
|---|---|---|
| 2025-09 | macOS 26 Tahoe ships; Xcode 26 ships, with a separate **Apple-silicon-only build** from Beta 5 (Universal build still runs on Intel) | [9to5Mac](https://9to5mac.com/2025/08/05/apple-now-offers-a-separate-xcode-26-beta-build-for-apple-silicon-macs/) |
| 2025-11-11 | **Docker-OSX** reverts its default image from Tahoe back to Sequoia ("White screen tahoe") — last commit to date | [`gh api` commit log](https://github.com/sickcodes/Docker-OSX/commit/master) |
| 2025-12-16 | GitHub announces up to **39 % hosted-runner price cut**, effective 2026-01-01; self-hosted $0.002/min charge **postponed** | [GitHub Changelog](https://github.blog/changelog/2025-12-16-coming-soon-simpler-pricing-and-a-better-experience-for-github-actions/) |
| 2026-01-26 | **kholia/OSX-KVM** adds "Support for macOS Tahoe" (latest commit as of today) | [`gh api` commits](https://github.com/kholia/OSX-KVM) |
| 2026-02-03 | Apple announces the **2026-04-28 minimum-SDK rule** (iOS 26 SDK / Xcode 26 for uploads) | [Apple Developer News](https://developer.apple.com/news/?id=ueeok6yw) |
| 2026-02-05 | **ultimate-macOS-KVM v0.14.1** ("full Tahoe support", rebrand) | [GitHub API](https://github.com/Coopydood/ultimate-macOS-KVM) |
| 2026-02-21 | **LongQT-sea/OpenCore-ISO v0.7** — OpenCore ISO supporting "Mac OS X 10.4 … macOS 26" | [GitHub API](https://github.com/LongQT-sea/OpenCore-ISO) |
| 2026-06 | WWDC 2026: iOS 27 / Xcode 27 announced | [Apple docs updates](https://developer.apple.com/documentation/updates) |
| 2026-07-26 | **`reims-vgpu`** created — experimental virtual GPU for macOS guests | [`gh api`](https://github.com/steelbrain/reims-vgpu) |
| 2026-09-09/10 | Apple: Xcode 27 RC; submissions open for iOS 27; **April 2027 = iOS 27 SDK floor**; "macOS 26 is the final release supporting Intel Mac computers and Rosetta" | [Apple Developer News](https://developer.apple.com/news/?id=k1mtkt1k) |
| 2026-09-14 | **macOS 27 "Golden Gate"** released — Apple silicon only | [MacObserver](https://www.macobserver.com/news/macos-27-golden-gate-drops-intel-macs-rosetta/) |
| 2026-09-21 | **xtool 1.20.1** — Swift 6.4 + SwiftUI macros + Xcode 27 linking fixes | [GitHub releases](https://github.com/xtool-org/xtool/releases) |

---

## 1. The hard constraint: what actually requires macOS/Xcode

### 1.1 Genuinely macOS-only (no workaround as of 2026-09)

| Thing | Why | Workaround status |
|---|---|---|
| **Xcode IDE (GUI)** | macOS app; Xcode 27 reported Apple-silicon-only | Darling runs Xcode's **command-line toolchain** but **not the IDE** ([Darling status summary](https://github.com/sitedata/darling)) |
| **iOS Simulator** | Runs only on macOS; since Xcode 11 the render pipeline is **Metal**, and the host must enumerate a Metal device or the window is black | Only via a macOS VM with a GPU stack — `reims-vgpu` is the 2026 attempt; not verified for Simulator use |
| **Simulator runtimes on Intel** | WWDC25: Xcode's download size shrank "by removing default Intel support from Simulator runtimes" | Need a **Universal** runtime image; x86_64 guests otherwise fail with "architecture not supported on this host" ([flutter#173760](https://github.com/flutter/flutter/issues/173760)) |
| **`xcodebuild` / `xcrun`** | macOS binaries | Reimplemented by xtool/SwiftPM for SwiftPM projects; KMP and MAUI still shell out to Xcode |
| **`codesign`** | macOS binary | **zsign** (C++, Linux/macOS/Windows/Android/FreeBSD) and ports (`zsign-rs`, `go-codesign`) re-sign IPAs on Linux ([zhlynn/zsign](https://github.com/zhlynn/zsign)) |
| **SwiftUI Previews, Interface Builder, Instruments, XCTest/XCUITest against simulators** | Xcode-shipped, GUI/simulator dependent | Not available on Linux |
| **Metal shader toolchain** | Xcode 26 moved it to conditional downloads | xtool links with `ld64.lld` instead of Apple's linker |
| **Transporter app** | Mac App Store app | `iTMSTransporter` CLI has an official **Linux** build |
| **`notarytool`** | macOS-only; *notarization for macOS distribution* | Irrelevant to iOS App Store submission |
| **`xcrun altool`** | Bundled with Xcode → macOS-only | Deprecated only for *notarization*; uploads still use it on Macs. Use `iTMSTransporter -assetFile` or the ASC API on Linux |

### 1.2 Genuinely doable on Linux today

- Writing all source code (Swift, Kotlin, Dart, TS, C#).
- **Compiling** Swift to `arm64-apple-ios` — via xtool, `osxcross`, or `apple-sdk-tools` + vanilla LLVM.
- **Signing** a Mach-O/IPA with `zsign` (needs an Apple-issued `.p12` + `.mobileprovision`, both obtainable via the App Store Connect API).
- **Installing to a physical iPhone** over USB via `usbmuxd`/`libimobiledevice` ([xtool Linux install docs](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md)).
- **Uploading to App Store Connect** via `iTMSTransporter` (Linux build) or the ASC REST API.
- **Triggering Xcode Cloud builds** from Linux via `POST /v1/ciBuildRuns` with a JWT from an API key ([Apple docs](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-cibuildruns)).
- Building/tests for **Android** locally, and **iOS in the cloud**.

### 1.3 Apple licensing — what the SLA actually says

The macOS SLA §2B(iii) grants the right

> "to install, use and run up to two (2) additional copies or instances of the Apple Software within virtual operating system environments on **each Mac Computer you own or control** that is already running the Apple Software"

and only for software development, testing during development, macOS Server, or personal non-commercial use — and it "does not permit you to use the virtualized copies … in connection with service bureau, time-sharing, terminal sharing or other similar types of services."
Separately, the "Other Use Restrictions" section states the license does **not** permit you "to install, use or run the Apple Software on any **non-Apple-branded computer**."
Sources: [macOS Sequoia SLA PDF](https://www.apple.com/legal/sla/docs/macOSSequoia.pdf), [Apple Discussions thread](https://discussions.apple.com/thread/250646417?sortBy=rank), [Apple Developer Forums: 2-VM SLA limit and CI](https://developer.apple.com/forums/thread/830383).

**Consequences:**
- Running macOS in QEMU/KVM on an x86_64 **Linux PC** violates the SLA (non-Apple hardware), independent of any technical feasibility. OSX-KVM's own docs point to the [Dortania legality notes](https://dortania.github.io/OpenCore-Install-Guide/why-oc.html#legality-of-hackintoshing) and its `macOS-Cloud.md` says bluntly: *"This pretty much violates everything hardware-wise in the macOS EULA that one could violate."*
- **Renting real Apple hardware (AWS/Scaleway/MacStadium) is the compliant path**, and is why those vendors impose a 24-hour minimum: it is a licensing artifact, not a technical one.

---

## 2. Local virtualization / "hackintosh-in-a-VM" on Linux

### 2.1 `sickcodes/Docker-OSX`

| | |
|---|---|
| Stars / license | 52.9 k / GPL-3.0 |
| **Last commit** | **2025-11-11** — "White screen tahoe. Revert default to sequoia…" → **~10 months stale as of 2026-09-24** |
| Default guest | **Sequoia (15)** (Tahoe reverted) |
| Documented guests | High Sierra → Sonoma; Quick Start also lists `SHORTNAME=sequoia` and `SHORTNAME=tahoe` |
| Requirements | x86_64 **KVM-capable** host, `/dev/kvm`, 20 GB+ disk (50 GB with Xcode, 60 GB partition for Xcode 12) |
| ARM hosts | **Not supported** — image is x86_64-only ([issue #487](https://github.com/sickcodes/Docker-OSX/issues/487), open since 2022) |

**Simulator reality:** Docker-OSX's docs list Xcode as a use case, but the **iOS Simulator is not mentioned** in the README, and the issue tracker tells the story: [#920 "Black screen on iphone simulator running flutter app" (open, 2026-04-05)](https://github.com/sickcodes/Docker-OSX/issues/920), [#708 "black/grey screen in simulator" (open)](https://github.com/sickcodes/Docker-OSX/issues/708), [#737 "Xcode can't run simulator due to docker not allowing more than 3.91 GB of RAM"](https://github.com/sickcodes/Docker-OSX/issues/737). Community reports also put in-VM builds at **~5× slower** than native.

**Verdict:** viable as a security-research/iMessage toy and as a *compiler* box for older SDKs; **not** a mature iOS dev workstation in 2026, and now on a hard expiry track (see §0/§2.6).

### 2.2 `kholia/OSX-KVM`

| | |
|---|---|
| Stars | 23.7 k |
| **Last commit** | **2026-01-26** — "Support for macOS Tahoe" |
| `fetch-macOS-v2.py` options | High Sierra → Ventura, **"Sonoma (14) - RECOMMENDED"**, **Sequoia (15)**, **Tahoe (26)** |
| Requirements | Ubuntu 24.04+ 64-bit, **QEMU ≥ 8.2.2**, VT-x/SVM, SSE4.1 (≥ Sierra), **AVX2 (≥ Ventura)** |
| Support model | README: *"Only commercial (paid) support is available now."* |
| Explicit caveat | README "Setting Expectations Right": the setup *"lacks graphical acceleration"* plus reliable audio/USB-3; beyond-native performance *"does require work, patience, and a bit of luck"* |
| Docs for Xcode | ships `Xcode-Tutorial.md` — the answer there is USB-passthrough the iPhone and use Xcode normally | 

**Verdict:** the most credible x86_64 path *technically*, and it does support Tahoe. Still no GPU acceleration by default (which is precisely the Simulator blocker), and the same SLA problem.

### 2.3 Newer / alternative projects

| Project | Status (2026-09-24) | Notes |
|---|---|---|
| **Coopydood/ultimate-macOS-KVM** | **v0.14.1, 2026-02-05**, 1.7 k★ | "Now with macOS Tahoe support", easy automation for KVM/libvirt |
| **LongQT-sea/OpenCore-ISO** | **v0.7, 2026-02-21** (repo pushed 2026-08-18), 844★ | OpenCore ISO for Proxmox VE / QEMU-KVM, "Mac OS X 10.4 through macOS 26", no OVMF patches. Companion `macos-iso-builder` produces installers **from Apple servers via GitHub Actions, no Mac required** |
| **quickemu** | **4.9.9, 2026-02-10** (repo pushed 2026-09-14), 16.3 k★ | Supports Mojave…Sonoma (+Sequoia listed); auto-downloads OpenCore/OVMF from OSX-KVM. **No GPU acceleration.** AMD hosts hit a TSC stability check → add `tsc=reliable` |
| **sosumi (snap)** | **Dead.** Snap Store latest/stable = **2020-03-06**; repo archived; popey confirmed unlisting | Store shows "hasn't been updated in a while… may be unmaintained". Don't use on 24.04/26.04 |
| **UTM** | **macOS/iOS host only** — 4.7.5 stable (QEMU 10.0.2), 5.0.0 beta | Asahi Linux users are told to use `virt-manager` instead. Not a Linux option |
| **Darling** | **v0.1.20260608**, active again since Oct 2025 | Runs **Xcode's extracted CLI toolchain** on Linux x86_64; **cannot run the Xcode IDE** |
| **reims-vgpu** | Created **2026-07-26**, last push 2026-09-03, 479★, **alpha** | See §2.5 |

### 2.4 macOS 26 (Tahoe) and Xcode 26 in VMs

- Tahoe **can** install in KVM (OSX-KVM commit 2026-01-26; OpenCore-ISO supports "macOS 26"), but Docker-OSX's Tahoe path produced a **white screen**, causing the default revert. Expect per-host CPU tuning (`Skylake-Client-v4`/`Skylake-Server-v4`, `tsc=reliable` on AMD).
- Xcode 26 is the last Xcode that runs on Intel — via the **Universal** build ([Apple system requirements](https://developer.apple.com/xcode/system-requirements/): Xcode 26 requires macOS Sequoia 15.6 – Tahoe 26.x; [flutter#173760](https://github.com/flutter/flutter/issues/173760) documents the arm-only trap).
- **Simulator runtimes in Xcode 26 dropped Intel by default** (WWDC25), so even a working Tahoe KVM guest needs Universal runtime images *and* a Metal device.

### 2.5 GPU/Metal and the `reims-vgpu` development

The Simulator question reduces to Metal. `reims-vgpu` is the notable 2026 answer:

- Attaches to macOS's built-in paravirtual driver **`AppleParavirtGPU.kext`** (present since Big Sur) — **no guest kext to install**.
- Three pathways documented, including **"x86 macOS / Linux Vulkan": Linux x86_64 host with KVM, PCI device `reims-vgpu-pci`, host **Vulkan** backend via [`metal2vulkan`](https://github.com/steelbrain/metal2vulkan) (Metal AIR → SPIR-V).
- Requires `/dev/kvm`, a working Vulkan stack, and an in-tree patched QEMU.
- Explicitly **alpha / research-grade**: *"the QEMU device ABI, boot scripts, crate layout, backend behavior… may change without a stable compatibility guarantee."*
- **macOS 13 Ventura is the recommended bring-up guest**; guest "rails" exist for `macos-11 … macos-26`.
- **No report found of the iOS Simulator actually running under it.** Treat as promising-unproven.
- There is also a separate proof-of-concept for **macOS ARM64 guests on Asahi Linux** (`steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64`, pushed 2026-08-18, 35★) using QEMU `vmapple` + KVM — boots **Ventura 13.6** on an M2 Pro, requires kernel/QEMU/Reims patches and temporary macOS access to extract `AVPBooter.vmapple2.bin`.

### 2.6 Apple Silicon (arm64) macOS guests

- **On an x86_64 Linux host: no.** macOS arm64 guests need `AVPBooter.vmapple2.bin` from Apple's Virtualization.framework and Apple-silicon host support; there is no x86_64 path. Docker-OSX and OSX-KVM are x86_64-guest only.
- **On an Apple Silicon Linux host (Asahi):** only the experimental path above, needing patches and a one-time macOS dependency. Notably, if you *have* an Apple silicon Mac, running macOS natively is strictly better — the Asahi angle is a research curiosity, not a dev strategy.
- **The bigger point:** because macOS 27 is Apple-silicon-only, "Apple-silicon macOS guest" and "just use macOS" converge. The exotic path buys you nothing.

### 2.7 Bottom line for local VMs

A KVM macOS guest on Linux is a **hobby/experiment path with a hard expiry**: it can never run Xcode 27, and the April 2027 SDK rule ends its usefulness for App Store uploads. Its remaining legitimate uses are security research, iMessage/iCloud tooling, and pre-April-2027 builds on an existing Tahoe+Xcode 26 setup. Simulator inside the VM is unreliable at best; with `reims-vgpu` it is *plausibly* achievable but unproven.

---

## 3. Non-Xcode / Xcode-less iOS build toolchains

### 3.1 `xtool` — the headline Linux-native option

Repo: [xtool-org/xtool](https://github.com/xtool-org/xtool) (formerly `kabiroberai/xtool`). Self-description: *"Cross-platform Xcode replacement. Build and deploy iOS apps with SwiftPM on Linux, Windows, and macOS."*

| | |
|---|---|
| **Latest release** | **1.20.1, 2026-09-21** (1.20.0 same day) — very actively developed (releases 1.18.1 → 1.20.1 within Sept 2026) |
| Stars / license | 5.5 k★ / MIT |
| Platforms | **Linux (x86_64 & arm64 AppImage)**, **Windows via WSL**, macOS |
| How it works | Installs **Swift 6.4** from swift.org, then you point it at an **`Xcode.xip` you download yourself** from `developer.apple.com/download/all`; it extracts the Darwin Swift SDK and installs it as `swift sdk install` (`swift sdk list` → `darwin`) |
| Auth | **API key** (paid Apple Developer Program, public ASC API, Team Key with App Manager role) **or password** (works with any Apple ID using private APIs — use a throwaway ID) |
| Device deploy | via `usbmuxd`/`libimobiledevice`; `xtool devices/install/launch` |
| Signing | built-in AutoSigner; identity `.real(cert, key)` or `.adhoc`; entitlements mapped to Apple CapabilityTypes and registered on the App ID |
| IPA | `xtool dev build --ipa` (wraps `.app` in `Payload/`) |
| Extensions | widgets / appexes supported via `xtool.yml` `extensions:` |

**What it can do**
- Build a SwiftPM package into a real iOS `.app`/`.ipa`, sign it, install it on a physical iPhone, manage certs/profiles via Apple Developer Services (`xtool ds certificates|profiles`).
- Build for the simulator target: `xtool dev build --triple arm64-apple-ios-simulator` — but **running** the simulator requires macOS ([PR closing #74](https://github.com/xtool-org/xtool/issues/74)).
- Works with **Xcode 27**: 1.20.1 fixed `ld64.lld` "unknown architecture: arm64e.x1-ios" "when linking apps built using **Xcode 27**".

**What it cannot do (as of 1.20.1)**
- **No App Store upload command.** Issue [#117 "Upload build to App Store" is still **open** (created 2025-06-13, last updated 2026-01-19)](https://github.com/xtool-org/xtool/issues/117); [#175 was closed](https://github.com/xtool-org/xtool/issues/175). The maintainer-community position is that generated IPAs must be uploaded with another tool (Transporter / Fastlane / ASC API / `iTMSTransporter`). The maintainer has noted `iTMSTransporter` is cross-platform and the ASC-API infrastructure is already in place, so integration is *possible* but unimplemented.
- **No iOS Simulator on Linux** (macOS only).
- No Xcode project generation for arbitrary app targets (`Generate Xcode project` exists but the model is SwiftPM-first).
- You still must supply `Xcode.xip` and comply with Apple's license — so xtool is "no Mac", not "no Apple".

**Why this matters in 2026:** xtool consumes the **SDK** from Xcode 27 without needing to *run* Xcode 27. Since the April 2027 App Store rule is an **SDK** floor, xtool is the only Mac-free path that could still be compliant after April 2027 — contingent on Apple's upload-time validation accepting it (unverified; see §9).

**Running it:** this section is the *decision*; the *manual* — install, daily commands, maintenance, troubleshooting — is [`ios-toolchain-linux.md`](./ios-toolchain-linux.md).

### 3.2 Swift SDKs / cross-compilation from Linux

- Swift SDKs (SE-0387) landed in SwiftPM in **Swift 6.1** (`swift sdk install|list|configure`), making cross-builds a single flag ([swift.org docs discussion](https://github.com/swiftlang/docs/issues/19)).
- **swift.org's official "Static Linux SDK" is for cross-compiling *to Linux*, not to iOS.** The `swift-sdk-generator` supported-platform table lists FreeBSD and Linux as host+target and **macOS only as a host**; **no Apple/iOS target is listed** ([swift-sdk-generator README](https://raw.githubusercontent.com/swiftlang/swift-sdk-generator/refs/heads/main/README.md)).
- **The working iOS cross-SDK is xtool's "darwin" Swift SDK**, built by extracting Xcode's iPhoneOS SDK. That is the practical state of the art.
- `swift build` *can* target iOS on Linux once such an SDK is installed; xtool wraps the environment plumbing (it passes `--sdk`, not `SDKROOT`, and handles CGO cross-compilation).

### 3.3 `osxcross` and `apple-sdk-tools`

- **tpoechtrager/osxcross**: hosts Linux/*BSD on x86/x86_64/ARM/AArch64; targets arm64, arm64e, x86_64, i386. Three flavors; the **`llvm` flavor (LLVM tools + `ld64.lld`) is recommended for new projects**. Requires the **iPhoneOS.sdk extracted from Xcode** (via `tools/gen_sdk_package.sh` on a Mac, or from the `.xip`). Caveat from a 2026 write-up: *"won't let you build full-fledged UIKit apps (easily)"* — good for CLI tools/services.
- **bitcoin-core/apple-sdk-tools** is the cleaner modern approach: on Linux, `python3 apple-sdk-tools/extract_xcode.py -f Xcode_26.1.xip | cpio -d -i`, then use **vanilla LLVM/clang** with `-isysroot`. Bitcoin Core's `contrib/macdeploy/README.md` documents Xcode **26.1.1** this way; [godot#11486](https://github.com/godotengine/godot-docs/issues/11486) explicitly recommends this over osxcross. **SDKs are free to download but not redistributable.**
- **No iOS Simulator on Linux** in any of these; testing needs a device or a macOS host.

### 3.4 Theos

[theos/theos](https://github.com/theos/theos) — 4.9 k★, last pushed **2026-09-18** (actively maintained; submodule bumps). Still the standard for building iOS **tweaks/jailbreak apps** on Linux/macOS. Its last tagged release is **2.5 (2019-01-30)** — the project tracks git, not releases. It needs a **macOS SDK copy** (same legal posture as above). Perfectly usable on Linux for non-App-Store targets; not a route to App Store apps.

### 3.5 Darling

[darlinghq/darling](https://github.com/darlinghq/darling) — GPL-3.0, 13.4 k★, last pushed **2026-09-06**; latest release **v0.1.20260608**. Releases resumed Oct 2025 after a 2022–2025 stall.
- **Can:** mount Xcode DMGs / extract `.xip`, copy `Xcode.app`, export Apple clang + SDK, and *"`xcodebuild` reportedly runs reasonably well for command-line tools and build workflows."*
- **Cannot:** run the Xcode IDE/GUI or most AppKit/Metal/Quartz apps. Officially **x86_64 Linux only**. UIKit/iOS app support remains an aspiration.
- **Not a substitute for a Mac for iOS work.**

### 3.6 Containers / adjacent tools worth knowing

- **MobAI `iosbox`** (Docker): extracts the iOS SDK + Swift toolchain from *your* `Xcode.xip` and cross-compiles **Flutter** with SwiftPM + prebuilt `ld64.lld`, producing `Runner.ipa`. Documented limits, verbatim: *"Debug builds only"*, *"Release (AOT) builds are in progress"*, *"Xcode 26.3 or earlier required"* (26.4+ ships SDK headers as stubs), *"Only physical devices are supported (`arm64-apple-ios`), no simulator"*, *"The `.ipa` is unsigned"*, *"for research and educational use only"*. SwiftUI/native iOS and React Native are **planned**, not supported ([MobAI-App/iosbox](https://github.com/MobAI-App/iosbox)).
- **MobAI `ios-builder`**: CLI that drives **GitHub Actions / Codemagic / Bitrise** macOS runners from Linux/Windows, plus device hot-reload via MobAI, and can assemble a `.p12` + provisioning profile without a Mac ([pkg.go.dev](https://pkg.go.dev/github.com/MobAI-App/ios-builder), [GitHub](https://github.com/MobAI-App/ios-builder)).
- **`zsign`** (and `zsign-rs`, `go-codesign`): Linux-native IPA signing. AUR `zsign-bin 1.1.1-1` first submitted 2026-08-11.
- **MacFree iOS Builder for Unity**: Unity Asset Store tool that ships iOS builds to TestFlight from Windows/Linux via a cloud machine (GitHub Actions / Unity Build Automation) — included for completeness since it's a real 2026 product for a specific niche.

---

## 4. Cloud macOS / remote Mac

### 4.1 Rented dedicated Apple hardware

| Provider | Cheapest relevant config | Price | Notes |
|---|---|---|---|
| **Scaleway** (fr-par) | Mac mini **M1**, 8 GB / 256 GB | **€75/mo, €0.11/hr** | M2-M €115/mo (€0.17/hr); M2 Pro €139/mo; **M4-S €149/mo (€0.22/hr)**; M4 Pro €335/mo. **24-hour minimum lease**; billed while assigned, even powered off; delete explicitly to stop billing. **Latest compatible Xcode pre-installed**, MacPorts, fail2ban for VNC. Remote desktop + SSH documented. No physical access, no macOS Recovery, **SIP cannot be disabled** ([pricing](https://www.scaleway.com/en/pricing/apple-silicon/), [FAQ](https://raw.githubusercontent.com/scaleway/docs-content/refs/heads/main/pages/apple-silicon/faq.mdx), validation date 2026-02-18) |
| **MacStadium** | **M2.S** M2 8-core / 8 GB / 256 GB | **$109/mo** | M4.S $149; M2.M $199; M4.L (M4 Pro 12-core, 48 GB) $349; Mac Studio M2 Ultra from $369. **Apple Silicon only.** Monthly contracts cost 15–30 % more than annual. No free trials. macOS "Sonoma or Ventura on request". GUI via separate **Mac VDI** product line ([pricing](https://www.macstadium.com/pricing)) |
| **MacinCloud** | Managed (shared) ~**$25–30/mo**; Dedicated **M2 $99/mo**, **M4 $124.99/mo** | — | Pay-as-you-go ~**$1/hr** (prepaid 25 h / 7 day credit; credits expire after 60 days idle). Managed = no admin rights. Dedicated = root/admin. Physical Apple Silicon (M1/M2/M4), 8/16 GB. Server Colocation available. *Prices from third-party comparisons dated June–Sept 2026; MacinCloud's own pricing page was not retrievable during this research* ([payg page](https://www.macincloud.com/pages/payg.html), [greenmini comparison](https://www.greenmini.nl/compare/macincloud-alternative/), [myremotemac](https://myremotemac.com/best-mac-cloud-hosting)) |
| **AWS EC2 Mac** | `mac-m4.metal` (M4, 24 GB) | **~$1.23/hr** → **~$886/mo** | `mac-m4pro.metal` ~$1.97/hr (third-party). **Dedicated Host only**, one instance per host, **24-hour minimum allocation**, billed per host not instance, no Spot/RIs (On-Demand + Savings Plans ≤44 % off for 3-yr). Families: `mac-m4`, `mac-m4pro`, `mac-m4max`, `mac-m3ultra`, `mac2-m2`, `mac2-m2pro`, `mac2-m1ultra`, `mac2`, `mac1`. M4 Pro/M4 add a 2 TB instance store ([instance types](https://aws.amazon.com/ec2/instance-types/mac/), [billing docs](https://docs.aws.amazon.com/en_jp/AWSEC2/latest/UserGuide/ec2-mac-instances.md), price from [bigbell.ai](https://bigbell.ai/coin/aws/ec2/mac-m4.metal) — **AWS's own pricing page renders no dollar figures and its Dedicated Hosts page has no Mac rates**, so treat these as unconfirmed by AWS directly) |
| Others | MyRemoteMac from ~$85/mo (M4), Green Mini (EU), Roundfleet, Flow Swiss, MrHost | — | Long tail of boutique Mac-mini hosts; pricing not primary-verified here |
| **Hetzner / OVH** | **No productized Apple silicon lineup found** | — | Community reports only ("Hetzner sometimes have them if you can snag one") ([LowEndTalk](https://lowendtalk.com/discussion/215702/mac-mini-macos-based-hosting)) |

**Remote-desktop latency:** Scaleway documents an "Access the remote desktop of a Mac mini" how-to plus SSH; MacStadium sells Mac VDI separately; MacinCloud charges extra for VNC on some plans (Roundfleet reports +$15/mo). Web-based VNC/Screen Sharing over a consumer link is usable for Xcode editing and builds; it is *not* pleasant for heavy Interface Builder work. A common working pattern is **SSH + CLI/Xcode Cloud for builds, VNC only when a GUI is unavoidable**.

### 4.2 CI / cloud build services

| Service | Free tier | macOS pricing | Can it replace a local Mac? |
|---|---|---|---|
| **Xcode Cloud** (Apple) | **25 compute hours/mo included** with the $99/yr Developer Program | 100 h $49.99; 250 h $99.99; 1,000 h $399.99; 10,000 h $3,999.99 /mo. No overage — step tiers. Hours **do not roll over** | Builds+tests+TestFlight distribution. Workflows are created in Xcode normally, **but can be created and triggered entirely via the ASC API from Linux** (`POST /v1/ciBuildRuns`). Community CLI: [`eba-cli`](https://www.npmjs.com/package/eba-cli), [`asc-cli`](https://github.com/tddworks/asc-cli), [`xcode-cloud-mcp`](https://github.com/cjhowe-us/xcode-cloud-mcp). Sources: [Xcode Cloud pricing](https://developer.apple.com/xcode-cloud/), [get started](https://developer.apple.com/xcode-cloud/get-started/), [ciBuildRuns](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-cibuildruns) |
| **GitHub Actions** | **Standard runners free & unlimited on public repos** (incl. macOS); private: 2,000 min free (Free), 3,000 (Pro/Team), 50,000 (Ent. Cloud), **macOS consumes at 10× for standard runners on private repos** | **Price cut up to 39 % on 2026-01-01**: standard macOS `actions_macos` **$0.062/min**; macOS 12-core `macos_l` **$0.077**; macOS 5-core M2 Pro `macos_xl` **$0.102**. **Included minutes cannot be used for larger runners** (billed from minute 1, even on public repos) | Images: `macos-26` (arm64, default for `macos-latest`), `macos-26-intel`, `macos-15`, plus an **Xcode 27 preview** arm64 image. Free macOS CI is the single best free "final build" tool. Sources: [runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing), [GitHub Changelog](https://github.blog/changelog/2025-12-16-coming-soon-simpler-pricing-and-a-better-experience-for-github-actions/), [runner-images](https://github.com/actions/runner-images) |
| **Codemagic** (Flutter/mobile specialist) | **500 free macOS M2 minutes/month** (individuals only, not Teams), 1 parallel build, 120-min build cap | Pay-as-you-go: **M2 $0.095/min**, **M4 $0.114/min**, Linux/Windows $0.045/min, extra concurrency $49. Fixed plans **$3,990 / $5,400 / $9,000 per year** (M2 / M4 / M4 Max, unlimited usage, 3 concurrency). Enterprise from $12,000/yr | Yes for Flutter/RN/Capacitor — handles certs+profiles automatically and publishes to App Store Connect. Free tier is genuinely enough for a solo dev releasing occasionally. Sources: [codemagic.io/pricing](https://codemagic.io/pricing/), [docs.codemagic.io/billing/pricing](https://docs.codemagic.io/billing/pricing/) |
| **Bitrise** | free plan reportedly 45 build minutes | **Per-build** pricing (predictable regardless of duration), machines up to M4 Pro 14 vCPU | Yes; commonly described as pricier than self-hosted. Pricing page not primary-verified here ([bitrise vs circleci](https://bitrise.io/resources/compare/bitrise-vs-circle-ci)) |
| **CircleCI** | credits model | **macOS M4 Pro Medium 200 credits/min; Large 400 credits/min** ([resource-class tables](https://codeables.dev/article/circleci-pricing-where-is-the-current-price-list-for-credits-minute)) | Yes — credit burn on iOS is the main complaint |
| **Expo EAS Build / Submit** | **Free: 15 iOS + 15 Android builds/mo**, low-priority queue, 45-min timeout, store submission included | **iOS $2/build medium worker, $4/build large**; Starter $19/mo (+$45 credit), Production $199/mo (+$225 credit) | **Yes — this is the cleanest Mac-free iOS path for RN/Expo.** EAS Submit is separate, on every plan including Free, and accepts **any** valid `.ipa`/`.aab`, not just EAS-built ones. Sources: [expo.dev/pricing](https://expo.dev/pricing), [docs.expo.dev/deploy/submit-to-app-stores](https://docs.expo.dev/deploy/submit-to-app-stores.md) |
| **Capgo Build** / **Capawesome Cloud** (Capacitor) | — | Cloud Mac Mini M4 (16 GB, macOS Tahoe 26.2, Xcode 26.2 per provider docs), CLI-driven, signs + uploads to ASC/TestFlight | Yes for Capacitor ([Capgo](https://capgo.app/blog/introducing-capgo-cloud-build/), [Capawesome](https://capawesome.io/docs/cloud/native-builds/faq/)) |
| **Ionic Appflow** | — | Managed macOS/Linux stacks, "no Mac hardware required" | Works, **but Ionic announced end of its commercial products by late 2027** ([Capawesome blog](https://capawesome.io/blog/page/8/)) — transitional only |

---

## 5. Cross-platform frameworks — what actually works on Linux

The pattern across every framework: **you can write and iterate on Linux; the final iOS compile+sign+upload must happen on macOS somewhere.** The differentiator is whether the framework ships a *first-party cloud build* that removes the Mac from your workflow entirely.

| Framework | Dev loop on Linux | iOS build on Linux? | First-party cloud build | Verdict |
|---|---|---|---|---|
| **Expo / React Native** | Full JS/TS + Metro + Android; iOS debug needs a Mac | **No** — `xcodebuild`, `codesign` are macOS ([docs](https://docs.expo.dev/build/introduction/)) | **Yes — EAS Build.** Official docs: *"EAS Build works with existing React Native projects created with `npx react-native init` or similar tools"* and it's *"designed to work for any native project, whether or not you use Expo and React Native"* (docs modified 2026-07-22). EAS Submit is free on all plans | **Best Mac-free story.** Bare RN with custom native modules still wants a Mac for interactive simulator work; Expo managed flow is genuinely Mac-free |
| **Flutter** | Full local dev + hot reload on Android/Linux desktop | **No** — `flutter build ios` requires Xcode | Codemagic (Flutter-native), or GitHub Actions macOS | Excellent: Codemagic's free 500 M2 min/mo + automatic signing is a complete solo-dev answer |
| **Kotlin Multiplatform / Compose MP** | Shared Kotlin + Android fine on Linux | **No.** Kotlin docs (updated 2026-07-21): *"To create iOS applications, you need a macOS host with Xcode installed. Your IDE will run Xcode under the hood to build iOS frameworks."* Compose MP: *"This is a general limitation of iOS development."* Android Developers: *"If you want to build an iOS app, you need a macOS machine with Xcode installed."* | None first-party | **Needs a Mac** (local or rented) for the iOS framework build. Sources: [KMP quickstart](https://kotlinlang.org/docs/multiplatform/quickstart.html), [Compose MP](https://kotlinlang.org/docs/multiplatform/compose-multiplatform-create-first-app.html), [KMP FAQ](https://kotlinlang.org/docs/multiplatform/faq.html) |
| **.NET MAUI** | Android + Windows + (experimental) Linux GTK4 | **No.** `error MAUI0001: iOS workload not available on Linux`; `error NETSDK1100: iOS target frameworks require macOS` | None first-party; needs a networked Mac build host | **Needs a Mac.** Standard Linux CI pattern is conditional `TargetFrameworks` so Linux builds Android only ([MAUI Linux GTK4 docs](https://learn.microsoft.com/en-us/dotnet/maui/developer-tools/platform-backends/linux-gtk4?view=net-maui-11.0), [PR #32186](https://github.com/dotnet/maui/pull/32186)) |
| **Capacitor / Ionic** | Full web dev on Linux; `npx cap sync ios` works | **No** (native compile needs Xcode) | **Yes — Capgo Build, Capawesome Cloud**, Ionic Appflow (EOL late 2027) | Mac-free viable, but via smaller vendors than Expo/Codemagic |

**Practical split that works well:** develop 100 % on Linux (including Android and hot reload) → push → cloud macOS runner does `pod install`/Gradle → `xcodebuild archive` → sign → upload to TestFlight. The friction is *iterating on iOS-specific UI/behaviour*: for that you want a GUI Mac, even an intermittent one.

---

## 6. Uploading a build from Linux

**The upload step is now OS-agnostic. The build step is not.**

| Path | Platform | Status 2026 |
|---|---|---|
| **App Store Connect API — Build Uploads** | Any OS (plain HTTPS + JWT) | Introduced WWDC 2025 (session 324), now in official docs. `POST /v1/buildUploads` → `POST /v1/buildUploadFiles` (returns pre-signed `uploadOperations` with offset/length chunks and required headers) → PUT chunks → `PATCH ... uploaded: true`. Webhook `BUILD_UPLOAD_STATE_UPDATED` (HMAC-SHA256 in `X-Apple-SIGNATURE`); poll `GET /v1/builds` → `processingState`. **This is the modern, fully documented, Mac-free upload path.** [Apple docs](https://developer.apple.com/documentation/appstoreconnectapi/build-uploads), [WWDC25-324 summary](https://wwdc-quick-look.swiftgg.team/en/articles/wwdc2025-324/) |
| **`iTMSTransporter` CLI** | **macOS, Windows, Linux** | The only *Apple* CLI with an official Linux build. **2026 change: `.ipa`/`.pkg` uploads must use `-assetFile` instead of the legacy `-f`.** Keep Transporter updated to retain Aspera/Signiant. Caveat: a developer-forum report of `ITMS-90529 Invalid package` from the CLI Transporter on an IPA the macOS GUI accepted — suspicious version skew ([App Store Connect Help](https://developer.apple.com/help/app-store-connect/manage-asset-packs/upload-apple-hosted-asset-packs/), [forum thread](https://developer.apple.com/forums/thread/733973)) |
| **`xcrun altool`** | **macOS only** | Bundled with Xcode. Deprecation applies only to *notarization*, **not** uploads. Not usable from Linux |
| **`notarytool`** | **macOS only** | For **macOS** notarization, not iOS App Store submission. Irrelevant here |
| **EAS Submit** | Any OS (Node CLI) | Free on all plans, accepts any valid `.ipa`. The most ergonomic Linux uploader |
| **Xcode Cloud builds from Linux** | Any OS | `POST /v1/ciBuildRuns` — 3 calls: workflow → `repositoryID`, then git reference for the branch, then create the build run. Auth = ASC API key JWT ([Apple docs](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-cibuildruns)) |

**Gotcha:** you can *upload* an unsigned-invalid IPA and it will fail validation asynchronously. Uploading ≠ acceptance; the April 2026 / April 2027 SDK floors are enforced at upload time (`ITMS-90725` style rejections) per reporting ([code2native](https://code2native.com/blog/do-i-need-a-mac-to-publish-an-app)).

---

## 7. Recommendation matrix

Ranked, with honest cost/effort. Effort scale: ★ = an afternoon, ★★★★★ = a project in itself. Costs are monthly unless noted.

### 7.1 Hobbyist — wants to build a simple app, no budget

| Rank | Setup | Cost | Effort | Why |
|---|---|---|---|---|
| 1 | **Expo (managed) + EAS Build free tier + EAS Submit** | **$0** + **$99/yr Apple Developer Program** | ★★ | 15 iOS builds/mo free; EAS Submit free and unlimited-ish; no Mac anywhere. Requires accepting Expo's managed workflow — use `eas build --local` or Xcode Cloud if you exhaust the quota |
| 2 | **Flutter + Codemagic free tier** | **$0** + $99/yr | ★★ | 500 free macOS M2 min/mo, Codemagic generates the signing cert + profile for you |
| 3 | **xtool on Linux** (Swift-native, SwiftUI) | **$0** (free Apple ID works via password auth) | ★★★ | Build + sign + install on your own iPhone with no Mac. Free-account bundle IDs get prefixed (`XTL-1234.com.example.App`) and expire on the usual 7-day cycle. **No App Store upload command yet** — you'd add `iTMSTransporter`/ASC API yourself |
| 4 | **Docker-OSX / OSX-KVM on your existing Linux PC** | **$0** | ★★★★★ | Free only if you value your time at zero. Expect 5× slower builds, broken simulator, SLA violation, and a **hard April 2027 expiry**. Not recommended even at $0 |

**Do not** start a fresh hackintosh/KVM macOS VM in 2026 for iOS work. It cannot run Xcode 27 and has a known end date.

### 7.2 Solo indie developer shipping to the App Store

| Rank | Setup | Cost | Effort | Why |
|---|---|---|---|---|
| 1 | **Linux dev + Codemagic (Flutter) or EAS Build (RN/Expo) + rented Mac for occasional GUI work (Scaleway M1 €75/mo or MacStadium M2.S $109/mo)** | **$75–110/mo** + $99/yr | ★★ | Cloud CI handles the routine build/sign/upload; the rented box is for simulator debugging, Interface Builder, and Xcode 27-only tasks. Scaleway bills €0.11/hr with a 24-hour minimum, so **burst usage costs ~€2.64/session** if you delete the machine — the cheapest "real Mac when I need one" on the market |
| 2 | **All-cloud: EAS/Codemagic + Xcode Cloud (25 free compute hours) + GitHub Actions macOS for public repos** | **$0–19/mo** + $99/yr | ★★ | Fully Mac-free release pipeline. The gap is interactive iOS debugging — no simulator, no Xcode. Acceptable for simpler apps; painful for heavy UIKit/SwiftUI work |
| 3 | **xtool (native Swift) + `iTMSTransporter`/ASC API for upload** | **$0** + $99/yr | ★★★★ | Genuinely Mac-free *and* native Swift. Pay the effort cost in signing/provisioning/upload scripting that xtool doesn't automate yet |
| 4 | **Buy a Mac mini M4 (~$600)** | ~$600 one-time | ★ | Not what you asked, but at 5–8 months of MacStadium pricing it becomes the rational choice if you're shipping continuously. macOS 26 Tahoe on M4 is the cheapest Xcode 27-capable hardware |

### 7.3 Team / production app

| Rank | Setup | Cost | Effort | Why |
|---|---|---|---|---|
| 1 | **Rented dedicated Apple Silicon (MacStadium / Scaleway) or a self-hosted Mac mini colocated, fronted by GitHub Actions (arm64 macOS runners or self-hosted) + fastlane** | **$109–349/mo** per box | ★★★ | Predictable, compliant (real Apple hardware), reproducible. Watch the **2-VM-per-Mac SLA limit** if you plan to virtualise on the Mac itself ([Apple Developer Forums](https://developer.apple.com/forums/thread/830383)) |
| 2 | **Production CI: Codemagic fixed plan ($3,990/yr) or Bitrise + Xcode Cloud ($49.99–399.99/mo tiers) + fastlane** | **$332/mo+** | ★★ | Managed signing, concurrency, artifact retention. Add Xcode Cloud when you want Apple's own TestFlight/App Review integration |
| 3 | **AWS EC2 Mac (`mac-m4.metal` ~$1.23/hr) for burst capacity** | **~$886/mo if always-on**, or pay the 24-h minimum for short bursts | ★★★★ | Only worth it for genuinely bursty, short workloads or if you're already deep in AWS. At always-on it's 3–8× a Scaleway/MacStadium Mac mini — **do not run it continuously** |
| 4 | **Long-lived KVM macOS VMs for CI** | — | ★★★★★ | Not just unsupported and SLA-violating: **it can never run Xcode 27**, and the 2-VM SLA cap blocks a build farm anyway. Off the table |

---

## 8. What is uncertain / where sources conflict

1. **Xcode 27 hardware requirement — the single biggest uncertainty.** Apple's own [system-requirements page](https://developer.apple.com/xcode/system-requirements/) lists only "Supported macOS Versions" (Xcode 27 → macOS Tahoe 26.6 or later) and contains **no hardware row** and does not mention Intel. Multiple secondary sources ([byteiota](https://byteiota.com/xcode-27-is-out-apple-silicon-only-swift-6-4-agents/), [blakecrosley](https://blakecrosley.com/zh-Hant/blog/xcode-27-release), [DevelopersIO](https://dev.classmethod.jp/articles/xcode-27-ios-27-beta-release-notes/), [sftpmac](https://sftpmac.com/zh/blog/xcode-27-apple-silicon-qianyi.html)) quote Apple's **release notes** as saying *"Xcode 27 will only install and run on Apple silicon Macs"* and list Architecture = "Apple silicon only". **Verify in Xcode 27's release notes yourself before betting a workflow on Intel.** Note the conclusion holds either way for hackintosh: macOS 27 is Apple-silicon-only regardless, so Intel's ceiling is Tahoe.
2. **AWS EC2 Mac dollar figures could not be confirmed on an AWS-owned page.** The [Mac instance-types page](https://aws.amazon.com/ec2/instance-types/mac/) and the [Dedicated Hosts pricing page](https://aws.amazon.com/ec2/dedicated-hosts/pricing/) render no Mac rates. The $1.23/hr (`mac-m4.metal`) and $1.97/hr (`mac-m4pro.metal`) figures come from third-party listings. **Check the AWS Pricing Calculator for your region before committing.**
3. **MacinCloud's exact prices** come from third-party comparisons dated June–September 2026; macincloud.com's pricing page returned 403/404 during this research. Treat $25–30 (managed), $99 (dedicated M2), $124.99 (dedicated M4) as indicative.
4. **MacStadium pricing conflicts across third parties** (e.g. M2.M quoted at both $149 and $199). The numbers in §4.1 are from **macstadium.com/pricing** itself and should be authoritative.
5. **Docker-OSX "abandoned?"** — GitHub shows last commit **2025-11-11**; third-party trackers and mirrors variously report commits into April 2026. Regardless of which is right, it is low-maintenance and the Tahoe path is broken.
6. **`reims-vgpu` + iOS Simulator is unverified.** No source found demonstrates the Simulator running under it. The project targets macOS 13 Ventura for bring-up while Xcode 26 needs macOS 15+, so the supported combinations may not currently overlap. Do not plan around it.
7. **Xcode 27 on Linux via xtool for App Store uploads is plausible but unproven.** xtool 1.20.1 supports Xcode 27 SDKs, and the April 2027 rule is an SDK floor — but no source confirms Apple's upload validation accepts an xtool-built binary as "built with the iOS 27 SDK".
8. **EAS Build free-tier numbers conflict** between Expo's own pricing page (15 iOS + 15 Android) and third-party guides (30/mo, ~$3/build, "$99/mo Production"). Expo's page is authoritative.
9. **GitHub Actions 2026 pricing turbulence.** The Dec 2025 changelog and a Mar 2026 self-hosted-billing proposal caused confusion; the $0.002/min self-hosted charge was **postponed**. The per-minute rates in §4.2 come from GitHub's billing reference and should be re-checked before budgeting.

---

## 9. Source index (primary-source-first)

**Apple**
- macOS 27 / Intel sunset + April 2027 SDK floor + Xcode 27 RC — https://developer.apple.com/news/?id=k1mtkt1k
- 2026-04-28 SDK rule — https://developer.apple.com/news/?id=ueeok6yw
- Xcode system requirements — https://developer.apple.com/xcode/system-requirements/
- Xcode Cloud pricing — https://developer.apple.com/xcode-cloud/ and https://developer.apple.com/xcode-cloud/get-started/
- ASC API build uploads — https://developer.apple.com/documentation/appstoreconnectapi/build-uploads
- ASC API start Xcode Cloud build — https://developer.apple.com/documentation/appstoreconnectapi/post-v1-cibuildruns
- Upload builds / iTMSTransporter — https://developer.apple.com/help/app-store-connect/manage-asset-packs/upload-apple-hosted-asset-packs/
- macOS Sequoia SLA (2B(iii) + non-Apple-hardware restriction) — https://www.apple.com/legal/sla/docs/macOSSequoia.pdf

**Toolchains**
- xtool repo / docs / releases — https://github.com/xtool-org/xtool · https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md · https://github.com/xtool-org/xtool/releases
- xtool open issues: App Store upload #117, simulator entitlements #83, CFBundleSupportedPlatforms #191 — https://github.com/xtool-org/xtool/issues
- osxcross — https://github.com/tpoechtrager/osxcross
- apple-sdk-tools / Bitcoin Core macdeploy — https://github.com/bitcoin-core/apple-sdk-tools
- zsign — https://github.com/zhlynn/zsign
- Theos — https://github.com/theos/theos
- Darling — https://github.com/darlinghq/darling
- swift-sdk-generator (no iOS target) — https://github.com/swiftlang/swift-sdk-generator
- Swift Linux install — https://www.swift.org/install/linux/ubuntu/24_04/
- iosbox — https://github.com/MobAI-App/iosbox · ios-builder — https://github.com/MobAI-App/ios-builder

**Virtualization**
- Docker-OSX — https://github.com/sickcodes/Docker-OSX (issues #920, #708, #737, #487)
- OSX-KVM — https://github.com/kholia/OSX-KVM
- ultimate-macOS-KVM — https://github.com/Coopydood/ultimate-macOS-KVM
- OpenCore-ISO — https://github.com/LongQT-sea/OpenCore-ISO
- quickemu — https://github.com/quickemu-project/quickemu
- reims-vgpu — https://github.com/steelbrain/reims-vgpu · metal2vulkan — https://github.com/steelbrain/metal2vulkan
- macOS arm64 on Asahi experiment — https://github.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64
- sosumi snap (unmaintained) — https://snapcraft.io/sosumi

**Cloud / CI**
- AWS EC2 Mac — https://aws.amazon.com/ec2/instance-types/mac/ · billing https://docs.aws.amazon.com/en_jp/AWSEC2/latest/UserGuide/ec2-mac-instances.md
- Scaleway — https://www.scaleway.com/en/pricing/apple-silicon/ · https://raw.githubusercontent.com/scaleway/docs-content/refs/heads/main/pages/apple-silicon/faq.mdx
- MacStadium — https://www.macstadium.com/pricing
- MacinCloud — https://www.macincloud.com/pages/payg.html
- GitHub Actions runner pricing — https://docs.github.com/en/billing/reference/actions-runner-pricing · runner images https://github.com/actions/runner-images · changelog https://github.blog/changelog/2025-12-16-coming-soon-simpler-pricing-and-a-better-experience-for-github-actions/
- Expo pricing / submit docs — https://expo.dev/pricing · https://docs.expo.dev/build/introduction/ · https://docs.expo.dev/deploy/submit-to-app-stores.md
- Codemagic — https://codemagic.io/pricing/ · https://docs.codemagic.io/billing/pricing/
- Capgo / Capawesome / Ionic Appflow — https://capgo.app/blog/introducing-capgo-cloud-build/ · https://capawesome.io/docs/cloud/native-builds/faq/ · https://ionic.io/appflow/native-builds

**Framework constraints**
- Kotlin Multiplatform quickstart / FAQ — https://kotlinlang.org/docs/multiplatform/quickstart.html · https://kotlinlang.org/docs/multiplatform/faq.html
- .NET MAUI Linux GTK4 backend — https://learn.microsoft.com/en-us/dotnet/maui/developer-tools/platform-backends/linux-gtk4
- Flutter/Xcode-on-Intel issue — https://github.com/flutter/flutter/issues/173760

---

*Compiled 2026-09-24. Every non-obvious claim above is linked at the point of use; §8 lists the specific points where the evidence is weaker than the surrounding text implies.*
