# iPhone Photos → User's Own NAS — Apple SDK Survey, 2026-09-24

**Scope:** can an iOS 27 app read the user's photo library with PhotoKit and sync it to a NAS the *user* specifies — using Apple-shipped SDK where one exists, rather than writing our own upload engine, SMB stack, or background scheduler?
**All sources last verified:** 2026-09-24.
**Method:** primary sources only — Apple framework reference pages pulled from `developer.apple.com/tutorials/data/...json` (the rendered HTML is JS-only and misleading), Apple technotes, Apple Developer News, vendor API specs, and third-party source code read directly via the GitHub API. Secondary sources are flagged inline; §11 lists where the evidence is weaker than the text implies.
**Companion doc:** [`ios-dev-on-linux.md`](./ios-dev-on-linux.md) — this project's build toolchain is assumed from there.
**Status:** the architecture below is unbuilt, but the *transport and layout* it depends on now has a working foreground MVP (`app/`) that was tested against a real WebDAV server on 2026-09-24. §6.4 records what that test changed.

---

## TL;DR

1. **Yes — Apple ships exactly this.** `PHAssetResourceUploadJob` (iOS 26.1+, refined and renamed in iOS 27) is a PhotoKit API whose entire purpose is *"Enable reliable cloud backup for photo library assets with background processing"*. The system — not your app — schedules and performs the uploads, including while the app is backgrounded or the device is locked. This removes the need for `BGTaskScheduler`, background `URLSession`, and any upload engine. ([Apple: Uploading asset resources in the background](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background)) §1
2. **The catch: the destination is an HTTP `URLRequest`.** The system uploads the bytes itself, so the NAS must expose an HTTP endpoint. That means **WebDAV (or Synology/QNAP's HTTP file API)** — *not* SMB and *not* SFTP. An SMB-only NAS cannot be a direct target of this API. §1.6
3. **This is a solved shape, and a production reference implementation exists.** Nextcloud's iOS app ships an extension literally named `BackgroundUploadExtension` implementing `PHBackgroundResourceUploadJobExtension`, uploading with a plain **WebDAV `PUT`** and Basic auth. Read that before writing ours. ([nextcloud/ios](https://github.com/nextcloud/ios/tree/master/BackgroundUploadExtension)) §7.1
4. **No special Apple entitlement is required** — the extension needs only app groups + keychain access groups, and PhotoKit needs only `NSPhotoLibraryUsageDescription` and a runtime `.readWrite` authorization. A standard $99/yr account suffices. §1.5
5. **Two constraints will bite and are easy to miss:**
   - **Local network privacy.** Making an outgoing TCP connection to a LAN address requires the Local Network privilege. **If the app performs that operation in the background while the privilege is still `undetermined`, the system denies it silently — no alert.** So the app must reach the NAS at least once in the foreground to trigger the prompt, before background backup can ever work. ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)) §8.1
   - **The extension is an ExtensionKit extension** (`@main` + `AppExtension`), which must live in `Foo.app/Extensions/`, not `Foo.app/PlugIns/`. **xtool cannot build this today** — [issue #138 "Support ExtensionKit"](https://github.com/xtool-org/xtool/issues/138) has been open since 2025-07-21. §9
6. **The biggest unknown is `BackgroundUploadURLBase`.** It is a *compile-time Info.plist key* holding "the base URL for your upload server", required "for network access validation" — but Apple publishes no statement of how that validation works. If the system only permits destinations under the declared base, this API may structurally fit "our fixed cloud service" apps better than "user types their own NAS address" apps. **Verify this on a device before committing to the architecture.** §11
7. **If (6) turns out to block the design,** the fallback is the well-trodden path: enumerate with `fetchPersistentChanges(since:)`, upload with a **background `URLSession`** (WebDAV `PUT`), schedule with `BGProcessingTask`. More code, but no host-validation question and no ExtensionKit dependency. §2
8. **Build-vs-buy:** the feature already exists commercially — **PhotoSync** does photo→SMB/WebDAV/SFTP/NAS, Pro is a one-time purchase in the tens of CNY. If the goal is "have my photos on my NAS", buying is strictly cheaper than building. Build only if the differentiator is something PhotoSync doesn't do — in practice, **system-scheduled background transfer** and **real throughput statistics**, the two things it structurally cannot offer. §7.4, §10
9. **The storage layout is a solved problem too, and its easy answer is wrong.** `<root>/<device>/<YYYY>/<MM>/<originalFilename>`, append-only, with a `HEAD` before every `PUT`. The obvious shortcut — a conditional `PUT` with `If-None-Match: *` — **was tested and silently overwrites on a real server**; do not build a backup's integrity on an optional request header. §6

---

## 0. Version timeline of the relevant APIs

| Version | What appeared | Source |
|---|---|---|
| iOS 16.0 | `fetchPersistentChanges(since:)`, `PHPersistentChangeToken` — durable cross-launch photo-library diff | [Apple](https://developer.apple.com/documentation/photos/phphotolibrary/fetchpersistentchanges(since:)) |
| iOS 26.0 | `BGContinuedProcessingTask` / `BGContinuedProcessingTaskRequest`; `com.apple.developer.background-tasks.continued-processing.gpu` entitlement | [Apple](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask) |
| **iOS 26.1** | **`PHAssetResourceUploadJob`, `PHAssetResourceUploadJobChangeRequest`, `PHBackgroundResourceUploadExtension`, `setUploadJobExtensionEnabled(_:)`, `uploadJobExtensionEnabled`** | [Apple](https://developer.apple.com/documentation/photos/phassetresourceuploadjob) |
| iOS 26.4 | `PHAssetResourceUploadJob.Type` (`upload` / `downloadOnly`); `responseHeaderFields` | [Apple](https://developer.apple.com/documentation/photos/phassetresourceuploadjob/type-swift.enum) |
| **iOS 27.0** | **`PHBackgroundResourceUploadJobExtension`** (async) — `PHBackgroundResourceUploadExtension` deprecated; **`PHPhotoLibraryPersistentChangesObserver`**; `enableUploadJobExtension(with:)`, `disableUploadJobExtension()`, `uploadJobExtensionOptions`, `PHAssetResourceUploadJobOptions.preventExpensiveNetworkAccess`; `assetResource(forUploadJob:)`; `PHAssetResource.filename`; `PHAssetResource.dataSize` | [Apple](https://developer.apple.com/documentation/photos/phbackgroundresourceuploadjobextension), [Apple](https://developer.apple.com/documentation/photos/phphotolibrarypersistentchangesobserver) |
| macOS 27.0 / Mac Catalyst 27.0 | Same upload-job API surface | [Apple](https://developer.apple.com/documentation/photos/phassetresourceuploadjob) |

Note the naming trap: the **async iOS 27 protocol is `PHBackgroundResourceUploadJobExtension`**; the **deprecated iOS 26.1 protocol is `PHBackgroundResourceUploadExtension`**. They differ by the word `Job`. The iOS 27 release notes' PhotoKit section covers only two unrelated deprecations — the upload API is documented in the article, not the release notes. ([iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes))

---

## 1. The API that answers the question: `PHAssetResourceUploadJob`

### 1.1 What it does

Apple's own summary, verbatim:

> "PhotoKit's Background Resource Upload extension enables apps to deliver seamless cloud backup experiences. The system manages uploads on your app's behalf, processing them in the background even when people switch to other apps or lock their devices. The system calls your extension to process uploads when conditions allow, scheduling work based on factors such as network availability, power state, and device activity."

This is not a thin wrapper — it is the whole backup engine. The system performs the byte transfer, handles retries and resumable uploads, and survives app suspension without `BGTaskScheduler`, `beginBackgroundTask`, or a background `URLSession` configuration.

### 1.2 The job lifecycle

| Stage | API | Notes |
|---|---|---|
| Create | `PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination:resource:)` | **Must be inside a `performChanges` block.** One job per `PHAssetResource`. |
| Track | `placeholderForCreatedAssetResourceUploadJob?.localIdentifier` | Your only handle on a job you just made. |
| Enumerate | `PHAssetResourceUploadJob.fetchJobs(action:options:)` | `action` ∈ `.process`, `.retry`, `.acknowledge`. Returns a `PHFetchResult`, **not** a `Sequence` — use index-based enumeration. |
| States | `.registered` → `.pending` → `.succeeded` / `.failed` / `.cancelled` | |
| Inspect | `.error` (NSURLErrorDomain), `.responseHeaderFields` (lowercased), `.destination`, `.type` | |
| Finish | `request.acknowledge()` / `.retry(destination:)` / `.cancel()` | All inside a change block. Cancelled jobs are auto-acknowledged and don't consume the limit. |

`jobLimit` is a class property bounding *unacknowledged* jobs (in-flight + succeeded + failed). Exceeding it throws `limitExceeded` from `performChanges`; the documented response is to acknowledge finished jobs and return `.processing` so the system calls you back. **Reference-implementation detail worth copying:** Nextcloud caps its own queue at `min(PHAssetResourceUploadJob.jobLimit, 20)` rather than trusting the system value. ([source](https://github.com/nextcloud/ios/blob/master/BackgroundUploadExtension/BackgroundUploadExtension%2BJobs.swift))

### 1.3 Waking up, and knowing what to upload

The extension is invoked via `processJobs() async -> PHBackgroundResourceUploadProcessingResult`:

- `.completed` — "up to date with the photos library"
- `.processing` — "partially completed… still requires more time" → **the system calls you again after the in-flight jobs finish.** This is the pump that keeps the queue fed.
- `.failure` — errored

There is **no** photo-library-change notification that wakes the extension. The extension is woken by the *system's* scheduling policy, and is expected to work out for itself what's new. Apple names the mechanism explicitly:

> "Your extension needs a mechanism to track which assets you've already processed… This typically involves persistent storage shared between your app and extension using an app group. Use `fetchPersistentChanges(since:)` with a `PHPersistentChangeToken` to track your progress."

The token is `NSSecureCoding`; archive it with `NSKeyedArchiver`. `PHPersistentObjectChangeDetails` gives you `insertedLocalIdentifiers`, `updatedLocalIdentifiers`, `deletedLocalIdentifiers` per `PHObjectType` — a complete insert/update/delete diff. Handle `persistentChangeTokenExpired` by discarding the token and returning `.processing` (the system pruned history past your save point).

**iOS 27 adds a real observer:** `PHPhotoLibraryPersistentChangesObserver` with `photoLibraryPersistentChangesDidUpdate(_:)` — new in 27.0, and not covered by the upload article. Useful for keeping the *host app's* UI in sync. ([Apple](https://developer.apple.com/documentation/photos/phphotolibrarypersistentchangesobserver))

Canonical `processJobs()` body (order matters, verified against Nextcloud): cancel requested → retry failed-and-not-yet-retried → acknowledge terminal jobs → create new upload jobs → return a result. On limit exhaustion, catch `NSError` with `domain == PHPhotosErrorDomain` and `code == PHPhotosError.limitExceeded.rawValue` and return `.processing` — [not an error](https://developer.apple.com/documentation/photos/phphotoserror-swift.struct/limitexceeded).

**`jobLimit` is the operational failure mode to instrument.** `acknowledge()` frees a slot and a successful `retry(destination:)` also frees one. An unacknowledged job leaks a slot, and enough leaks **silently stop all backup** with no user-visible error. Log slot exhaustion loudly — this is the "backup randomly stopped" bug you will otherwise spend a week on.

### 1.4 Resumable uploads (and the server work they imply)

The system supports resumable uploads "according to the draft protocol" (draft-ietf-httpbis-resumable-upload). Your server participates in **two** places, both required if you want resumption:

1. **Preflight.** The system sends `OPTIONS` to the upload endpoint. Respond `200 OK` with `Upload-Limit: <bytes>` to advertise support, or **`501 Not Implemented`** to decline. The capability check is cached.
2. **In-band.** After creating the upload resource, send a `104 (Upload Resumption Supported)` informational response carrying `Location:` before the final response. The doc states this is "the authoritative signal", and that your API must include **both** the `OPTIONS` preflight and the `104`.

Because resumption is opt-in via a `501`, a dumb WebDAV `PUT` that returns `501` to `OPTIONS` should still work — losing only resumability. **This is inferred, not documented; verify it.** (§11)

### 1.5 Setup, entitlements, and authorization

Info.plist on the **extension** target (verified against Nextcloud's shipped `Brand/BackgroundUploadExtension.plist`):

```xml
<key>BackgroundUploadURLBase</key><string>https://api.example.com</string>
<key>EXAppExtensionAttributes</key>
<dict><key>EXExtensionPointIdentifier</key>
      <string>com.apple.photos.background-upload</string></dict>
```

Entitlements actually needed — nothing Apple-special (verified against Nextcloud's shipped `.entitlements`):

```
com.apple.security.application-groups  →  group.<your-id>
keychain-access-groups                 →  $(AppIdentifierPrefix)<your-id>
```

Authorization: the **host app** must hold `.readWrite` → `.authorized` (full library access; Limited mode is not enough), then call `setUploadJobExtensionEnabled(true)`. iOS 27 adds the atomic `enableUploadJobExtension(with:)` and `disableUploadJobExtension()`, plus `uploadJobExtensionOptions` / `setUploadJobExtensionOptions(_:)` for `preventsExpensiveNetworkAccess`. Disable the extension on sign-out.

> **Simulator is not supported:** *"In iOS, this feature isn't available in Simulator; test on a physical device."*

### 1.6 The hard architectural constraint: HTTP only

`PHAssetResourceUploadJob.destination` is a **`URLRequest`**, and the system sends the asset resource's bytes as the body. Your code never touches the payload. Consequences:

| NAS protocol | Can it be the job destination? | Why |
|---|---|---|
| **WebDAV** | **Yes — the natural fit.** | Plain HTTP `PUT` with the raw bytes as body. Exactly what Nextcloud does. |
| **Synology HTTP API** (`SYNO.FileStation.Upload`) | No, not directly | It's `POST /webapi/entry.cgi` with **`multipart/form-data`** and the file as a named form field, alongside `api`/`version`/`method`/`path`/`create_parents` fields. You cannot inject the multipart preamble — the system owns the body. ([Synology File Station API](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf)) |
| **SMB / SMB2 / SMB3** | **No** | Apple ships no public SMB **client** API to third-party apps. |
| **SFTP** | No | Not HTTP; no Apple API. |
| **NFS** | No | Not HTTP; not a realistic iOS client target. |
| **Your own HTTP shim on the NAS** | Yes | Any endpoint accepting a raw-body `POST`/`PUT` works. |

**So the design collapses to: WebDAV, or run a small HTTP receiver on the NAS.** WebDAV is the lazy answer — Synology (Package Center → "WebDAV Server", default ports 5005/5006), QNAP (Control Panel → Applications → Web Server → WebDAV), and Nextcloud/ownCloud all speak it natively. TrueNAS does **not** ship WebDAV directly and needs a container (e.g. `hacdias/webdav`). ([Synology KB](https://kb.synology.com/en-global/DSM/help/WebDAVServer/webdav_server), [QNAP/mundobytes summary](https://mundobytes.com/id/Apa-itu-protokol-WebDAV--kegunaan-sebenarnya--dan-alternatifnya/))

**Payload transformation is impossible.** A job is `PHAssetResource` + destination request; the app never sees or modifies the bytes. An Open Radar from 2026-07-20 asks Apple for a body-provider hook precisely because this makes the extension unusable for end-to-end-encrypted backup products. If client-side encryption before upload is a requirement, **this API is disqualified** and you fall back to §2. ([FB23870865 via Open Radar](http://ileyf.cn.openradar.appspot.com/FB23870865))

### 1.7 What Apple does *not* give you

| Need | Apple API? | Notes |
|---|---|---|
| Reach an SMB share mounted in the **Files** app | **No** | `NSFileProviderManager.getDomainsWithCompletionHandler(_:)` is documented as "Returns all of the File Provider extension's **domains**" — i.e. only **your own** extension's. There is no API to enumerate the system's SMB provider (`com.apple.SMBClientProvider.FileProvider`). Third-party apps are sandboxed away from it. |
| Borrow another app's File Provider to do the transfer | **Only if that extension exposes an XPC service** | `FileManager.getFileProviderServicesForItem(at:)` reaches custom services a provider deliberately publishes, and only for a URL you already have access to. It is not a general backdoor. |
| An SMB/SFTP/rsync client | **No** | See §1.6. |
| A server-side component | **No** | You (or the user) must supply the HTTP endpoint. There is nothing to install on the NAS from Apple. |
| Client-side encryption before upload | **No** | See §1.6. |

The one adjacent Apple feature a user might reach for — mounting an SMB share in Files, picking a folder with `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`, and persisting a bookmark — is **iOS-real but documented as fragile for network volumes**: bookmarks resolve fine while the volume stays mounted, but cross-volume resolution is a known bug (r.102995804, iOS 16+), resolving after a disconnect throws `NSFileProviderErrorDomain -2001 "No file provider was found with the identifier com.apple.SMBClientProvider.FileProvider"`, and mount paths are unstable (`/private/var/mobile/Library/LiveFiles/com.apple.filesystems.smbclientd/<random>/…`). Note also that `.withSecurityScope` on **bookmark creation** is a macOS-only option; on iOS picker URLs are implicitly scoped. Treat this as a research curiosity, not a foundation. ([Apple Developer Forums 773970](https://developer.apple.com/forums/thread/773970), [131644](https://developer.apple.com/forums/thread/131644), [774114](https://developer.apple.com/forums/thread/774114), [Apple: Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories))

---

## 2. Fallback architecture (if §11.1 kills the PhotoKit path)

Standard, entirely public, no ExtensionKit, no host-validation question:

1. **Enumerate** — `fetchPersistentChanges(since:)` + `PHPersistentChangeToken` (same as §1.3).
2. **Upload** — `URLSessionConfiguration.background(withIdentifier:)` + `uploadTask(with:fromFile:)`, a WebDAV `PUT` per resource. Background sessions survive suspension and app termination; the app is relaunched via `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
3. **Schedule** — `BGProcessingTaskRequest` with `requiresExternalPower` and `requiresNetworkConnectivity` set.

Cost: you own retry, backoff, resumability, concurrency limiting, and the reconciliation of job state after a crash. That is precisely the engine Apple is handing you in §1.

Three scheduling constraints to weigh:

| API | Ceiling | Verdict |
|---|---|---|
| `BGAppRefreshTask` | **"up to 30 seconds"** | Nowhere near library-scale |
| `BGProcessingTask` | Runs **"only when the device is idle"**; **"the system terminates any background processing tasks running when the user starts using the device."** | Poor fit alone for thousands of assets |
| `BGContinuedProcessingTask` (iOS 26) | Runs to completion even when backgrounded — **but must be started from the foreground in response to a person's action**, and surfaces a cancellable Live Activity | Good for a "Back up now" button; not silent continuous backup |
| **`PHAssetResourceUploadJob`** | System-scheduled | **The only Apple API built for this** |

Sources: [Choosing Background Strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app), [Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)

---

## 3. Identity: matching assets to their stored copies

### 3.1 Three layers of identity — and only one of them is durable

The mapping can't be a single key. There are three distinct identities, and they have different lifetimes:

| Layer | Key | Lifetime | Role |
|---|---|---|---|
| Local asset | `PHAsset.localIdentifier` | Stable **within** a library; **changes** on device restore / migration | The only key PhotoKit gives you; your index into the library |
| Content | SHA-256 of the resource bytes | Permanent | The durable identity. Survives restore, enables dedup + integrity verification |
| Server | `fileId` / `ocId` / `ETag` (WebDAV) or a custom id | Server's lifetime | Where to find it, and how to detect drift |

**This layering is not theoretical — it is the exact bug class PhotoSync ships with.** PhotoSync keys its "already transferred" record on iOS's per-asset identifiers, and its own support documentation describes the failure: after a major iOS update or a restore from backup, identifiers change, so PhotoSync either re-uploads everything or marks *new* items as already synced. Their documented remedy is a manual `Settings → Service & Support → "Reset 'synced' selections"`. That is a real, shipped product's data-integrity bug, and it is the argument for making the content hash — not `localIdentifier` — the durable key. ([PhotoSync: new photos no longer recognized](https://www.photosync-app.com/support/basics/answers/new-photosvideos-are-no-longer-recognized-how-can-i-fix-this))

### 3.2 The proven record shape

Nextcloud's iOS client is the reference implementation (§7.1), and its `tableMetadata` is precisely this mapping record. The fields that matter here:

```
assetLocalIdentifier   // PhotoKit key
ocId  / fileId  / etag // server identity + version
checksums              // integrity
dataFingerprint        // local content fingerprint
size                   // bytes — the numerator of any rate calc
status                 // upload state
session, sessionDate, sessionTaskIdentifier, sessionError   // per-attempt bookkeeping
serverUrl, serverUrlFileName, path, fileName                // where it landed
resourceType, livePhotoFile                                 // resource + Live Photo pairing
uploadDate, date, creationDate
```

([`NCManageDatabase+Metadata.swift`](https://github.com/nextcloud/ios/blob/master/iOSClient/Data/NCManageDatabase%2BMetadata.swift))

Two design notes worth stealing: `checksums` and `dataFingerprint` are separate fields (server-reported vs locally computed), and the upload session bookkeeping is denormalised onto the asset record rather than kept in a separate log — which is what makes status UI and retry logic cheap.

### 3.3 Getting the server's identity back: `responseHeaderFields`

On the PhotoKit path you never see the HTTP response yourself — the system owns the `URLRequest`. The documented channel back is [`PHAssetResourceUploadJob.responseHeaderFields`](https://developer.apple.com/documentation/photos/phassetresourceuploadjob/responseheaderfields) (iOS 26.4+): *"The HTTP response headers received from the server upon completion of the upload."* Keys are lowercased, and Apple's own example reads `headers["x-server-resource-id"]`.

So the contract is: **your endpoint echoes what you want to remember.** A WebDAV server alone returns `ETag` (usable as the version key). To get a stable server id, front the NAS with something that adds one header — a small proxy, or the NAS's own app platform. Nextcloud's extension instead resolves ids with a follow-up `PROPFIND`; both patterns work, and the header is cheaper.

### 3.4 Rate statistics: the honest answer is that the job API has none

**Verified negative finding.** The complete inspection surface of [`PHAssetResourceUploadJob`](https://developer.apple.com/documentation/photos/phassetresourceuploadjob) is:

`type` · `Type` · `destination` · `resource` · `state` · `State` · `error` · `responseHeaderFields`

There is **no bytes-sent, no progress, no fraction-complete, no timing property.** `error` is explicitly sanitised — Apple notes it "may not be the actual error returned from `URLResponse`". The `progressHandler` story belongs to the *manual* path (`PHAssetResourceRequestOptions.progressHandler`) in §2, not to this one.

Three ways to get numbers, in increasing order of truthfulness:

| | Method | What you get | Cost |
|---|---|---|---|
| **A** | Derive from state transitions: poll `fetchJobs(action:options:)`, record `(resource, state, observedAt)`, then `Σ resource.dataSize` over jobs reaching `.succeeded` ÷ elapsed | Average throughput; per-file durations | Free, but coarse |
| **B** | Server measures actual bytes received + elapsed, returns them in `responseHeaderFields` | True per-file byte counts, durations, checksums | Needs endpoint cooperation |
| **C** | Manual path: `requestData(for:options:dataReceivedHandler:)` gives live byte counts | True instantaneous rate | Abandons the system engine — contradicts the whole premise |

**Recommend A for the UI estimate and B for the numbers you'd show a user as fact.** Note that B is also the only way to get integrity verification for free (`X-Checksum-SHA256`).

Two caveats on A that will bite silently:

- [`PHAssetResource.dataSize`](https://developer.apple.com/documentation/photos/phassetresource/datasize-5lxva) is **iOS 27.0+**, is `Int?`, and Apple says it "may be unknown … `nil` means the size is unknown, not that it is zero." A naive `reduce(0, +)` over an optional denominator under-reports without erroring. Count unknowns and label the estimate as such.
- `responseHeaderFields` is populated only on **terminal** state, so rates are quantised to job completion — there is no "currently uploading at X MB/s" for a single large video in flight.

**Worth saying plainly:** the system hides per-file progress because it schedules uploads opportunistically around device idle, charging, and network conditions (§1.3). Instantaneous "speed" is therefore a somewhat meaningless number in this architecture — it measures Apple's scheduler, not your NAS. What a user actually wants is "how much is backed up, and how fast on average when it runs," which A + B answer honestly. If you build this, showing a live MB/s dial would be **more** misleading than showing nothing.

---

## 4. Local storage when originals live in iCloud

### 4.1 On the PhotoKit path, the problem does not exist

This is the strongest argument for §1 that is easy to miss. In the `PHAssetResourceUploadJob` design, **your code never downloads the asset.** You hand the system a job naming a `PHAssetResource`; the system fetches it from iCloud (if it isn't on-device) and streams it to your endpoint. No staging file is written to your container, so there is nothing to evict, and no `Optimize Storage` interaction to manage.

The `downloadOnly` job type in §0 is a separate, deliberate feature for a destination that wants the bytes itself — not a fallback you'd need for space reasons.

*Unverified:* whether the system's own download lands in the Photos library's cache and how aggressively that is evicted under a large library — the one place a long backup run could still transiently consume phone storage. (§11.5)

### 4.2 On the fallback path, you own the download

Then the rules are specific:

- **Write to `/tmp` or `Library/Caches` — never `Documents`.** `Documents` is user-visible and is backed up to iCloud/iTunes; a multi-GB video staged there is both a storage complaint and a backup-amplification bug. Apple's [Optimizing Your App's Data for iCloud Backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup) and [Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively) name `/tmp` and `Library/Caches` as the purgeable locations.
- [`PHAssetResourceManager.writeData(for:toFile:options:completionHandler:)`](https://developer.apple.com/documentation/photos/phassetresourcemanager/writedata(for:tofile:options:completionhandler:)) writes progressively to a file **you** choose, so stream-to-disk rather than into `Data` — `requestData` accumulates in memory and will be killed on a large video.
- [`isNetworkAccessAllowed`](https://developer.apple.com/documentation/photos/phassetresourcerequestoptions/isnetworkaccessallowed) **must** be `true`, or any asset that lives only in iCloud fails outright.
- **Delete the file in the completion handler**, immediately after the upload succeeds. Apple's temp-file guidance is to delete as soon as you are done; anything else is an orphan waiting to accumulate.
- Mark it purgeable via [`URLResourceKey.isPurgeableKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/ispurgeablekey) (iOS 14+) so the filesystem may reclaim it under pressure — belt to the braces of deleting it yourself. `isExcludedFromBackup` is moot in `Caches` but is the right call if anything ever lands in `Documents`.
- **Bound concurrency to one or two in flight.** Several parallel 4K-video downloads will spike disk usage faster than you can delete.
- Call `cancelDataRequest(_:)` when the transfer fails or the app backgrounds, then delete the partial file — otherwise a cancelled request leaves a truncated file that looks resumable but isn't.
- **Sweep `/tmp` and your cache subdirectory on launch** for orphans from a previous crash. Nothing else will clean them up on a predictable schedule.

### 4.3 The seductive option that does not apply here

[`PHAssetResourceManager.exportedAssetID(for:)`](https://developer.apple.com/documentation/photos/phassetresourcemanager/exportedassetid(for:)) (iOS 27.0) returns a `CKAsset.ExportedAssetID` that "can be used to create a `CKAsset` that references the asset resource data without copying it" — a genuine server-side copy with **zero bytes through the phone**. It requires iCloud Photos (else `requestNotSupportedForAsset`) and only exists for resources CloudKit stores as its own `CKAsset` (core components, media derivatives; a `thumbnailDerivative` fails with `missingResource`).

**It is not usable with a NAS target.** "Server-side copy" here means *into a CloudKit container*, and a WebDAV endpoint on a Synology is not one. Note it, file it under "if the destination were ever a CloudKit-backed service," and move on. Worth stating because it is the first hit anyone finds when searching for this problem, and it will waste an afternoon otherwise.

---

## 5. Background operation — the operating model

**The division of labour is the whole design.** Your app does not run during the transfer. You register jobs; the system decides when to move bytes. Apple's own framing: it processes uploads "in the background even when people switch to other apps or lock their devices."

**Three entry points:**

1. [`PHPhotoLibrary.setUploadJobExtensionEnabled(_:)`](https://developer.apple.com/documentation/photos/phphotolibrary/setuploadjobextensionenabled(_:)) — the opt-in, done once from the host app.
2. Your extension's [`process()`](https://developer.apple.com/documentation/photos/phbackgroundresourceuploadextension/process/) — the system wakes it here.
3. The same `process()` can also be nudged from a foreground moment, so opening the app does something useful rather than waiting for the next system wake.

**What you still build yourself:** the delta (which assets are new, via `PHPersistentChangeToken` in an app group so the extension can read it), the durable per-asset record (§3.2), the NAS config UI, and the foreground local-network permission step that must happen *before* any background attempt (§8.1 / TN3179). Why not a background-task API instead is argued in §2.

---

## 6. Storage layout on the NAS

**Recommendation up front:** `<root>/<device>/<YYYY>/<MM>/<originalFilename>` — device-first, monthly partition, original filename preserved, written **append-only** with a HEAD-before-PUT check for idempotency, plus a separate app-side index that holds the authoritative mapping. Rationale and the alternatives, below.

### 6.1 The real constraint is not the shape — it's who creates the folders

Worth stating first, because it reframes the whole question: **Apple's model is not a filesystem.** The API takes a `URLRequest`. Apple's own example in [Uploading asset resources in the background](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background) does this:

```swift
let url = URL(string: "https://api.example.com/upload")!
var request = URLRequest(url: url)
...
request.setValue(resource.originalFilename, forHTTPHeaderField: "X-Filename")
```

A **fixed endpoint**, with the filename carried in a **header** — not encoded into the path. Apple expects your server to be an API that decides where bytes land. Nothing in the article discusses folders, collections, or paths.

Choosing WebDAV therefore means bending the API toward a filesystem model, which is legitimate (Nextcloud does exactly this) but has one consequence that will otherwise be discovered at runtime:

**RFC 4918 §9.7.1 — a plain WebDAV `PUT` will not create parent collections.** The spec is explicit that *"the server MUST NOT create those intermediate collections automatically"*; a `PUT` to `/2026/09/IMG_0001.HEIC` whose parents don't exist must fail with **409 Conflict**. In practice some servers return **403** instead — a documented interop wart with multiple bug trackers behind it. ([RFC 4918 §9.7.1 discussion](https://datatracker.ietf.org/doc/html/draft-ietf-webdav-rfc2518bis#9); [WAGON-38](https://issues.apache.org/jira/browse/WAGON-38); [IVY-1193](https://issues.apache.org/jira/browse/IVY-1193))

Nextcloud's extension dodges the whole problem with one line:

```swift
request.setValue("1", forHTTPHeaderField: "X-NC-WebDAV-Auto-Mkcol")
```

**That header is a Nextcloud server extension. A stock Synology/QNAP/Apache `mod_dav` WebDAV endpoint will ignore it** — and Nextcloud's own auto-upload path confirms the normal discipline, issuing `createFolderForAutoUpload(serverUrlFileName:)` and *aborting the sync* if it fails. ([`BackgroundUploadExtension+Destination.swift`](https://github.com/nextcloud/ios/blob/master/BackgroundUploadExtension/BackgroundUploadExtension%2BDestination.swift); [`NCAutoUpload.swift`](https://github.com/nextcloud/ios/blob/master/iOSClient/Networking/NCAutoUpload.swift))

**So: folder creation is yours, and every path level costs a `MKCOL` round trip.** That is the single strongest argument for keeping the tree shallow — the shape should be the *minimum* depth that still keeps directories under the listing-performance cliff (§6.3). Treat `405 Method Not Allowed` on `MKCOL` as "already exists", not an error; servers disagree here (RFC says 405, rclone answers **201**) and a client must accept both.

### 6.2 Two trees, not one

The filesystem **cannot** be the source of truth for the mapping. §3.1 already established why: a `PHAsset` maps to multiple resources (Live Photo = photo + motion), to edited *and* original renditions, and to a server identity that the filesystem has nowhere to put. A filename can carry one of those facts, not all of them.

So the layout is two trees:

| | Tree A — the archive | Tree B — the index |
|---|---|---|
| Purpose | Human browsing, restore, third-party tools | The app's authoritative mapping |
| Content | The media bytes | §3.2's record: asset↔server id, hash, size, status |
| Mutability | **Append-only, never renamed** | Rewritten freely |
| Read by | Finder, File Station, Synology Photos, Immich | Your app |

The governing rule for Tree A: **write once, never move or rename.** Any rename invalidates the index, breaks resumability, and confuses the NAS's own indexers (Synology Photos and Immich both maintain databases keyed on path). Sequence-number collision suffixes violate this; that's why §6.4 recommends a protocol-level fix instead.

### 6.3 Tree A — the browsable archive

```
<root>/<device>/<YYYY>/<MM>/<originalFilename>
```

e.g. `PhotoBackup/Kevin-iPhone/2026/09/IMG_0001.HEIC`

**Why device-first.** Three reasons, in order of weight:

1. **It removes most filename collisions.** Apple's default names (`IMG_0001.HEIC`) restart per device. Two devices backing into one tree collide constantly under `YYYY/MM`; separated by device, a path collision means *genuinely the same content* — which is exactly the condition you want the idempotency check (§6.4) to short-circuit on. This turns the collision problem from "needs a naming policy" into "needs a size comparison".
2. **It survives §3.1's identifier problem.** The device label is user-controlled and stable across restores and OS upgrades. `localIdentifier` is not.
3. It matches what the incumbents do by default — PhotoSync's default album rule is *device name + album name*.

**Why monthly, not daily or yearly.** Nextcloud offers exactly three granularities — yearly, monthly, daily — in [`createGranularityPath(asset:serverUrlBase:granularity:)`](https://github.com/nextcloud/ios/blob/master/iOSClient/Utility/NCUtilityFileSystem.swift), producing `2026`, `2026/09`, or `2026/09/24`. Monthly is the sweet spot: daily multiplies your `MKCOL` round trips by ~30 with no browsing benefit (nobody wants 365 folders a year per device), while yearly risks crossing the listing cliff below.

**Why partition at all — the scale numbers.** Guidance converges on **~10,000 entries per directory** as the practical ceiling, and the client matters enormously. TrueNAS's own measurements on a flash-backed ZFS SMB share, listing 100,000 files in one directory:

| Client | 100K files |
|---|---|
| Windows 11 | ~1.5 s |
| Linux (kernel CIFS) | ~3 s |
| macOS Finder (Sonoma) | **15.5 minutes** |

([TrueNAS SMB Directory List Times](https://github.com/truenas/documentation/blob/2cea8f1c97d5524e081f59cc609c126eb8f6c1ad/content/References/Performance/SMBFileTimes.md))

That macOS row is the one that matters — it's the client most likely to browse this tree. Alongside it: Alibaba Cloud's NAS guidance is to keep directories **below 10,000 files** and to move to NFSv3 `nordirplus` beyond that, explicitly *not* SMB or WebDAV; and ext4 uses a fixed inode table sized at `mkfs` time that **cannot be changed later**, so a million-file flat photo tree can exhaust inodes and fail new writes with a misleading "No space left on device" while free space remains. ([Alibaba Cloud NAS performance FAQ](https://www.alibabacloud.com/help/ja/nas/user-guide/faq-about-the-performance-of-nas-file-systems))

A 100,000-photo library is unremarkable for a phone. Monthly partitioning keeps any one device-month around a few hundred to a few thousand entries even for a heavy shooter.

*Source-quality note:* the 10,000 figure is advisory rather than normative, and the inode point comes from vendor/community writing rather than filesystem documentation read directly. The *direction* is not in doubt — flat trees degrade — but treat the constants as rules of thumb. No WebDAV-specific benchmark surfaced at all (§11.10).

**Naming.** Keep `originalFilename`. Apple's own example sends it (`X-Filename`), and it's what makes the archive browsable and re-importable — a hash-named tree is neither. Note there are two distinct properties and you want the right one:

- **`originalFilename`** — "the original filename of the asset resource from when it was created or imported" (`IMG_0001.HEIC`). Human-recognizable, **not unique**.
- **`filename`** — the system's current name for the resource; may differ (edits, conversions).

Use `originalFilename`, and sanitize it: strip `/` and `:` , reject `..`, and truncate while preserving the extension. Then be aware of a case-sensitivity trap — APFS and SMB are typically case-**insensitive**, ext4 is case-**sensitive**. `IMG_0001.HEIC` and `img_0001.heic` are the same file on one end and two files on the other, which will desynchronise your index. Normalise case for the collision check, not for the stored name.

**Date source:** use `asset.creationDate` (the recording date), never the transfer date. PhotoSync exposes both as distinct token families — `%YR/%mR/%dR` for recording date versus `%YT/%mT/%dT` for transfer date — and the transfer date is the wrong choice for a backup: it changes if you ever re-upload, so the same asset lands in a different folder on the second run. ([PhotoSync: automatically create subdirectories](https://www.photosync-app.com/support/ios/answers/how-to-automatically-create-subdirectories-on-the-target-device-service))

And pin the timezone. `creationDate` is an absolute instant; the folder is a rendering of it. Immich documents that its date variables "are rendered in the server's local timezone" — a silent cross-timezone inconsistency for an asset shot at 23:30 on the 31st. Pick one (device-local at upload time, or UTC), write it into the config, and never change it, or months will drift.

**Album folders are a trap, if you ever add them.** Immich's `{{album}}` template uses the most-recently-created album for multi-album assets, and PhotoSync's album folders **duplicate the file into every album folder it belongs to**. Album membership is many-to-many and does not belong in a path.

### 6.4 The collision problem, and the clean fix

`originalFilename` is not unique — that is the crux. Same `IMG_0001.HEIC` from two devices, from a restore-then-reimport, from screenshots, from re-exported edits. Four ways to handle it:

| | Approach | Verdict |
|---|---|---|
| 1 | Overwrite | **Never.** Silent data loss. |
| 2 | Append a sequence number | Immich's approach — *"a sequence number is appended to the filename"* ([storage template docs](https://docs.immich.app/administration/storage-template)). Works, but breaks append-only immutability and idempotency: the same asset re-uploaded gets a new number. |
| 3 | Content-hash suffix | Stable and self-deduplicating, but ugly, and requires hashing before you can name anything — which on the §4.1 path means downloading bytes the system was going to stream for you. Also breaks Live Photo pairing (§6.5). |
| 4 | **HEAD, then PUT** | **Recommended.** Works everywhere. One extra round trip per file. |
| ~~5~~ | ~~`If-None-Match: *` conditional PUT~~ | **Rejected — tested and does not hold.** See below. |

**Option 4 in practice:** `HEAD` the target path first.

- **`404`** → nothing there. `PUT` it (still sending `If-None-Match: *`, free insurance for servers that honour it).
- **`200`** → something is already at that path. Compare `Content-Length` to the asset's `dataSize`:
  - **equal** → already backed up, skip. This is the idempotency win.
  - **different** → a genuine name collision between two *different* assets. Do **not** overwrite (rule 1) and do **not** silently skip — surface it. Deterministic renaming is the eventual fix.
- **`405`** → a *collection* occupies that path, not a file. Real problem, surface it.
- **`409`/`403`** → parent folder missing — `MKCOL` and retry once (§6.1).

**Why the conditional-PUT shortcut was rejected (measured 2026-09-24).** The first version of this section recommended `If-None-Match: *` as the primary mechanism. It was then tested against rclone v1.75.1's WebDAV server:

```
PUT /dir/a.bin                          -> 201
PUT /dir/a.bin  If-None-Match: *        -> 201   ← overwrote, should have been 412
PUT /dir/a.bin  If-None-Match: * (again)-> 201
```

The header is ignored outright and the file is overwritten silently. Worse, an earlier probe on the *same* server did return `412` once, so the behaviour is not even self-consistent — which makes it worse than simply unsupported, because a test on a quiet server can pass and the mechanism still fail later under load.

That is precisely the failure rule 1 exists to prevent: a silent overwrite destroys a previously backed-up asset, and nothing in the response says so. **Do not build a backup's integrity on an optional request header.** The HEAD-first flow costs one extra request per multi-megabyte upload and is correct on every server. `If-None-Match: *` is retained in the implementation as a second line of defence — harmless where ignored, protective where honoured — but no decision may depend on it. `scripts/verify-webdav.sh` therefore checks HEAD semantics as pass/fail and reports the conditional PUT as informational only.

This gives idempotency, append-only immutability, and dedup, using only universal WebDAV. It also makes re-running a backup safe, which matters because §5's job model will re-present assets after any index loss.

### 6.5 What becomes which file — Live Photos and edits

`PHAssetResourceType` has 13 values, and Apple is explicit that **"Each `PHAssetResource` you upload requires a separate job."** So one asset can legitimately produce several files and several jobs. The full set:

| Group | Types |
|---|---|
| Originals | `photo`, `video`, `audio`, `pairedVideo` |
| Current/edited rendition | `fullSizePhoto`, `fullSizeVideo`, `fullSizePairedVideo` |
| Edit-reconstruction data | `adjustmentData`, `adjustmentBasePhoto`, `adjustmentBaseVideo`, `adjustmentBasePairedVideo` |
| Other | `alternatePhoto`, `photoProxy` |

([`PHAssetResourceType`](https://developer.apple.com/documentation/photos/phassetresourcetype))

**Recommended policy: originals + adjustment data. Skip `fullSize*` renders.** The render is derivable from the original plus the adjustment; the adjustment data is not derivable from the render. This is a real storage saving on an edited library, and it's the difference between a backup and a screenshot of a backup. It is also a policy you must state in the UI — a user who edits a photo and sees the unedited version on the NAS will consider the backup broken.

**Live Photo pairing.** A Live Photo is two resources — `photo` (HEIC) and `pairedVideo` (MOV). Nothing in the filesystem links them, so the convention is the only link: **same basename, different extension.** Nextcloud does exactly this in one line:

```swift
metadata.livePhotoFile = (metadata.fileName as NSString).deletingPathExtension + ".mov"
```

So `IMG_0001.HEIC` + `IMG_0001.MOV` sit adjacent, and an importer that understands the convention re-pairs them (Apple Photos, Synology Photos, and Immich all do). Use the *same* naming rule for original and motion resource — if you rename one, you break the pair. **This is the strongest argument against content-hash filenames** (option 3 in §6.4): a hash per resource destroys the shared basename unless you hash the *asset* and apply it to both.

### 6.6 Tree B — the index

The app owns its own store (§3.2's `tableMetadata`-style record). Two additions worth considering for a NAS target specifically:

- **A per-asset sidecar** (`.xmp`) if NAS-side tools should read metadata. XMP is the interoperable standard — Lightroom, digiKam, and Immich understand it. Note it carries *photo* metadata (dates, location, rating), not PhotoKit semantics: it cannot express `localIdentifier` or the Live Photo pairing, so it complements the index rather than replacing it. Optional, and it doubles the file count for XMP-aware indexers to walk.
- **A top-level manifest** (`<root>/.imagebackup/manifest.json` or a small sqlite file) as a disaster-recovery artefact. If the phone dies, Tree B dies with it; a manifest written to the NAS is what lets a fresh install reconcile against Tree A without re-uploading everything. **This is the one file in the tree that should be written atomically and versioned**, and it's the cheapest insurance in the design.

Keep the index store out of the browsable path — a dot-directory, excluded from your own scanning loop.

### 6.7 What will actually go wrong

- **NAS-generated clutter.** Synology writes `@eaDir/` next to media, macOS writes `.DS_Store`, Synology also creates `#recycle/`. All of these appear in directory listings and inflate the entry counts from §6.3. Exclude them from any scan you write, and consider disabling thumbnailing or the recycle bin on the backup share — both multiply the object count behind your back.
- **`MKCOL` races.** The system may run jobs concurrently, so two jobs can try to create the same month folder. Treat `405` (and rclone's `201`) as success (§6.1) and make folder creation idempotent.
- **`.HEIC` → `.jpg` conversion.** Nextcloud's `outputFileName(for:sourceFileExtension:nativeFormat:)` rewrites the extension when converting to JPEG for compatibility. If you ever do this, the extension changes while the basename must not — another reason the Live Photo pairing rule (§6.5) should be applied *after* any conversion decision.
- **`localIdentifier` is not filename-safe.** It looks like `91B1C271-C617-49CE-A074-E391BA7F843F/L0/001` — it contains `/`, so it cannot go in a path unmodified. Split at the *first* `/` rather than truncating to 32 characters (pre-10.15 macOS identifiers were not even UUID-shaped). ([PHAsset localIdentifier format](https://stackoverflow.com/questions/28887638/how-to-get-an-alasset-url-from-a-phasset))
- **Zero-byte failures.** A failed job can leave a partial or empty file at the final path, and the HEAD-first check (§6.4) will then treat that path as done forever. This is why the `200` branch compares `Content-Length` rather than just skipping: a stored size of `0`, or any value that disagrees with the asset's `dataSize`, must be surfaced instead of silently accepted. Delete-and-retry known-bad files.

---

## 7. Build vs. adopt: what already exists

### 7.1 Nextcloud iOS — the reference implementation (read this first)

| | |
|---|---|
| Repo | [`nextcloud/ios`](https://github.com/nextcloud/ios) · GPL-3.0 · 2.5k★ · pushed 2026-09-24 |
| Extension | `BackgroundUploadExtension/` — `@main final class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension` |
| Destination | `request.httpMethod = "PUT"`, `Content-Type: application/octet-stream`, Basic auth, plus `X-NC-WebDAV-Auto-Mkcol: 1`, `X-OC-CTime`, `X-OC-MTime` |
| Write-up | Apple's async `processJobs()` pump, `PHAssetResourceUploadJob.jobLimit` capped at 20, app-group Realm DB shared with the host app |
| Server gate | Refuses to run against Nextcloud server `< v33` |

This is a shipped, maintained implementation of exactly the feature we're considering, and its `+Destination.swift` is ~60 lines. **It is also the strongest evidence that the design works in production.** It is WebDAV, so it maps onto any WebDAV-capable NAS.

### 7.2 Immich — the popular self-hosted option, but wrong shape

[`immich-app/immich`](https://github.com/immich-app/immich) · AGPL-3.0 · 114.9k★ · latest `v3.2.2` (2026-09-15). The iOS side is Flutter with a native PhotoKit bridge (`mobile/ios/Runner/Sync/PHAssetExtensions.swift`, `PHAssetResourceExtensions.swift`) and uploads **to its own Immich server** over its own protocol — no SMB/WebDAV target, and no `BackgroundUploadExtension` directory. Adopting Immich means adopting a server to run, not pointing at a NAS share.

### 7.3 Protocol libraries, if the fallback path (§2) is taken

| Option | What | License | Last push | iOS/SPM | Effort |
|---|---|---|---|---|---|
| `URLSession` + WebDAV | PUT/PROPFIND/MKCOL with custom methods & headers — no library needed | — | — | yes | ~zero |
| [`AMSMB2`](https://github.com/amosavian/AMSMB2) | Swift SMB2/3 client over `libsmb2` | LGPL-2.1 | 2026-05-30 | yes | low, but **only if you avoid §1** |
| [`libsmb2`](https://github.com/sahlberg/libsmb2) | C SMB2/3 userspace client | (see repo) | 2026-09-20 | needs a C target | medium |
| [`Citadel`](https://github.com/orlandos-nl/Citadel) | Swift SSH/SFTP on SwiftNIO | MIT | 2026-06-12 | yes | low–medium |

The irony worth stating plainly: **SMB support is only needed if you *don't* use Apple's API.** Apple's API needs WebDAV, and WebDAV needs no library at all. So SMB is a *reason to prefer* the PhotoKit path, not a complication of it.

### 7.4 PhotoSync — the honest baseline

**PhotoSync** (touchbyte GmbH) backs up the photo library to **SMB, WebDAV, SFTP, FTP** and explicitly lists Synology, QNAP, TrueNAS, OpenMediaVault, ownCloud, Nextcloud and more. Free download; **Pro** removes quality limits (one-time, ~¥38 in the CN store); **Premium** adds Autotransfer (scheduled/automatic), client-side encryption, Shortcuts actions, and S3/Backblaze/Wasabi. Version ~4.9.8, updated 2026-04/05. ([App Store CN](https://apps.apple.com/cn/app/id415850124), [photosync-app.com](https://www.photosync-app.com/home))

If the goal is "my photos, on my NAS", PhotoSync already ships it for the price of a coffee, and it does SMB — which Apple's own API cannot. So the question is not "does it work" but *which of its gaps matter*:

| Feature | PhotoSync | Notes |
|---|---|---|
| **ID ↔ storage matching** | **Yes** — this is its "Incremental sync" | Keyed on iOS per-asset identifiers; **documented to break after restore** (§3.1). Tracks only its own transfers. |
| **Throughput / rate statistics** | **Not found** | Per-file progress only; no rate or history found in docs, release notes, or reviews |
| **iCloud offload without local space** | **Weaker by construction** | Must materialise iCloud-only originals to transfer them; no sign it uses the system upload-job path |
| **Background backup** | **Partial, and materially weaker** | Two iOS triggers only; ~4 min window; must stay in app switcher |

**Background backup is the decisive comparison.** PhotoSync advertises five Autotransfer triggers but **on iOS only two are available**: Location-Based and When Charging. The charging trigger gets one window per 24 hours (default 02:00) and requires the device to be charging, idle, *and* the NAS reachable at that moment or the transfer is skipped; a background task runs about 4 minutes, which iOS may extend by about 4 more. Three consequences:

- **PhotoSync must remain in the app switcher.** Its own support: *"automation on iOS is limited. For the charging transfer to be executed it is essential that you do not remove PhotoSync from the app switcher."* Swipe it away and the transfer does not run at all.
- **Large files may never finish.** A multi-GB video that cannot complete in the window stalls the backup until a manual transfer.
- **User reports are mixed** — some report the 02:00 charging trigger working well; others report it needing the app opened daily or silently skipping.

([Charging-trigger behaviour and the app-switcher requirement](https://www.photosync-app.com/support/ios/answers/how-to-use-an-ibeacon-to-autotransfer-on-ios); [Nextcloud forum thread quoting PhotoSync support](https://help.nextcloud.com/t/hochladen-geht-mit-ios-17-nicht-im-hintergrund/178499/9))

**So the build case rests on two things PhotoSync structurally cannot do**, not on better engineering:

- **System-scheduled background transfer**, not bound by the ~4-minute BGTask window. `PHAssetResourceUploadJob` makes this possible only because Apple opened the API in iOS 26.1.
- **Real throughput and integrity statistics** (§3.4), which follow from owning the endpoint.

The honest counterweight: PhotoSync's background unreliability is itself evidence that this is genuinely hard, and that users notice. If you build, §1.3's `jobLimit` instrumentation and §3.1's content-hash identity are the two places to be more careful than the incumbent.

### 7.5 Also already built, for specific hardware

**Synology's own DS file / Synology Photos apps** and QNAP's QuMagie/Qfile do photo→NAS backup for their own hardware, and Synology publishes the **File Station API** (`SYNO.FileStation.Upload`, `SYNO.API.Auth`, `SYNO.FileStation.BackgroundTask`) as an official HTTP API with a developer guide — the basis for a Synology-specific integration, though again multipart-only (§1.6).

---

## 8. Platform constraints that will bite

### 8.1 Local network privacy — the one that silently breaks background backup

From [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy):

- "Making an outgoing TCP connection" to a local network address **requires** local network access. A NAS on the LAN is exactly this.
- "The system implements these TCP and UDP checks deep in the networking stack, and thus they apply to **all** networking APIs. This includes Network framework, BSD Sockets, `URLSession`…"
- **The killer:** *"If an iOS app is in the background and performs a local network operation while its Local Network privilege is undetermined, the system denies that operation without presenting the local network alert. The system doesn't record that decision."* → **The app must touch the NAS once in the foreground to spend the prompt.** If it doesn't, every background upload fails silently and the user sees nothing. This will look exactly like a scheduler bug.
- Required keys: `NSLocalNetworkUsageDescription`, and — **on the host app's Info.plist, not the extension's** — plus `NSBonjourServices` if browsing Bonjour service types.
- "In general, app extensions share the Local Network privilege state of their container app."
- Also relevant: resolving a **`.local`** name requires local network access; resolving an ordinary DNS name with the system resolver does not. Connecting by raw LAN IP still requires it.
- **"The simulator doesn't support local network privacy. Test your local network privacy behavior on a real device."**

Design implication: onboarding must include a foreground "connect to your NAS" step that provokes the prompt, and the UI must detect and explain the denied/undetermined state rather than appearing to work.

### 8.2 ATS and plain-HTTP NAS addresses

From [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking): since iOS 17, ATS **no longer allows connections to IP addresses by default** — you must add specific IPs or CIDR ranges to `NSExceptionDomains`. `.local` and unqualified domains are allowed by default on modern OSes. A user pointing the app at `http://192.168.1.10:5005` will therefore need an ATS exception, and HTTPS with a self-signed cert on a NAS is a further trust problem to solve.

- **The key's abstract overstates it.** "Controls whether ATS allows… IP addresses" reads as though `NSAllowsLocalNetworking` alone admits an IP literal; the iOS 17 note says the remedy is `NSExceptionDomains`. A [developer forum thread](https://developer.apple.com/forums/thread/747421) has a reporter failing with *both* the key and a `192.168.0.0/24` entry set, and one entry cannot cover all IP addresses. Set both; treat the CIDR route as unverified (§11.16).
- **A runtime address needs a compile-time exception, so it must be a range.** The user types the NAS address, so no single IP can be listed at build time — hence the private ranges (`10/8`, `172.16/12`, `192.168/16`). `NSAllowsArbitraryLoads` does **not** widen it: on iOS 17+ the local-networking key tells newer OSes to *ignore* the arbitrary-loads key.

Entering the NAS by hostname (`nas.local`) avoids the question — see `app/README.md`.

### 8.3 App Review

- **2.5.4** — "Multitasking apps may only use background services for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc." Using Apple's own background-upload extension point for exactly its documented purpose is the *safest possible* position under this rule.
- **2.5.1** — "Apps may only use public APIs and must run on the currently shipping OS." Satisfied: everything above is public API.
- **5.1.2(i)** — you must obtain permission before transmitting personal data and disclose where it goes. A photo library uploaded to a user-supplied NAS is squarely in scope; the consent flow and privacy manifest must say so plainly.
- **No guideline found that restricts backup/storage-client apps** as a category. (The guidelines page fetched truncates inside §5.4 of the guidelines, so this is a negative result within the retrieved text, not a guarantee across the whole document.)

Source: [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### 8.4 Privacy manifest

`PrivacyInfo.xcprivacy` has been mandatory for submissions since 2024-05-01 and must be valid ([TN3181](https://developer.apple.com/documentation/technotes/tn3181-debugging-an-invalid-privacy-manifest)). An app touching file timestamps (a backup engine comparing mtimes) and disk-space APIs will need the corresponding **required-reason API** declarations. Reusing Apple's upload job removes most of the file-system surface, which shrinks this obligation.

### 8.5 The SDK floor

Per the companion doc, Apple's [2026-09-09 Developer News post](https://developer.apple.com/news/?id=k1mtkt1k) sets an **April 2027 iOS 27 SDK requirement** for App Store uploads. `PHBackgroundResourceUploadJobExtension` is iOS 27-only, so adopting it implies an iOS 27 deployment target and forecloses older-OS support. `PHAssetResourceUploadJob` itself is iOS 26.1, so an iOS 26.1 floor keeps the earlier protocol.

---

## 9. Consequence for the Linux-first toolchain

This is the part that connects to the companion doc, and it is a **hard blocker today**.

`PHBackgroundResourceUploadJobExtension` conforms to `ExtensionFoundation.AppExtension` — it is an **ExtensionKit** extension. Nextcloud's built product is literally `explicitFileType = "wrapper.extensionkit-extension"`, and it declares `EXAppExtensionAttributes` rather than `NSExtension`.

xtool's extension support targets **classic Foundation app extensions** (`NSExtension` / `NSExtensionPointIdentifier`, installed into `Foo.app/PlugIns/`) — see [`Documentation/xtool.docc/Appex.md`](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Appex.md). ExtensionKit extensions must be installed into **`Foo.app/Extensions/`** instead. That difference is [issue #138 "Support ExtensionKit"](https://github.com/xtool-org/xtool/issues/138), **open since 2025-07-21** with a single comment and no further activity. The maintainer's comment notes the remaining unknown is whether the extension *point* can be declared without an Xcode-shipped tool.

**Therefore:**

- On a pure-Linux xtool workflow, the §1 architecture is **not buildable today**. The §2 fallback (host-app-only, background `URLSession`) is — verified 2026-09-24: that MVP compiles and links into an arm64 `.app` with `xtool dev build` ([`ios-toolchain-linux.md`](./ios-toolchain-linux.md)).
- A plausible unverified workaround: build the extension as a normal target and post-process the `.app` to move the `.appex` from `PlugIns/` to `Extensions/`, with `EXAppExtensionAttributes` in its Info.plist. That is a guess, not a supported path, and it is the first thing to prototype if pure-Linux is a hard requirement.
- §2 needs no extension at all, so if pure-Linux matters more than elegance, §2 is the lower-risk choice despite being more code.

---

## 10. Recommendation

**Architecture, if the PhotoKit path survives §11.1:** host app (PhotoKit auth, NAS config UI, foreground "connect" step to spend the Local Network prompt, `setUploadJobExtensionEnabled`) + a `PHBackgroundResourceUploadJobExtension` that diffs with `PHPersistentChangeToken` stored in an app group and creates **WebDAV `PUT`** jobs, with the NAS's own WebDAV service as the endpoint. Storage follows §6: `<device>/<YYYY>/<MM>/<originalFilename>`, append-only, HEAD before PUT.

**Sequence I'd suggest:**

1. **One afternoon, on a physical iPhone, before writing anything else:** build the smallest possible extension that points a job at a WebDAV endpoint and confirm (a) the system actually uploads, (b) whether a user-supplied host passes `BackgroundUploadURLBase` validation. That single experiment decides between §1 and §2 and is worth more than any further reading.
2. If (1) passes → implement §1, reading Nextcloud's extension as the template.
3. If (1) fails on host validation → implement §2, and weigh §7.4 honestly: if neither background quality nor statistics matters to you, buying PhotoSync is the right answer.
4. Decide the NAS protocol story up front: **WebDAV is required** for §1. If the target NAS is SMB-only and cannot run WebDAV or a container, §1 is off the table regardless of §11.1.

Step 1 is cheaper than it sounds because the transport is no longer a question. The MVP in `app/` already exercises the layout, the MKCOL walk, the HEAD-before-PUT rule and the Keychain/ATS/local-network plumbing against a real server — what remains untested is only whether the *system's* uploader can be aimed at an arbitrary user-supplied host.

---

## 11. Uncertain / unverified

### Decides the architecture

1. **`BackgroundUploadURLBase` validation semantics — the critical unknown.** Apple documents the key and says the system "requires this key for network access validation", but publishes no rule for *what* is validated. If destinations must be under the declared base, a "user types any NAS address" product cannot use this API as-is. **Not documented anywhere I could find; must be tested on-device.** This is the single highest-risk assumption in this document.
2. **Whether the background extension can issue `MKCOL` at all.** Nextcloud creates folders app-side, *before* job creation, which implies the extension may not be expected to. If it cannot, folder pre-creation must happen for the whole upcoming month during a foreground moment, and jobs must not be created for months whose folder doesn't exist yet. Resolve with the same on-device experiment as (1).

### API details

3. **`jobLimit`'s actual value** is not published; Nextcloud caps at 20 defensively. Read it at runtime rather than hardcoding.
4. **`responseHeaderFields` size limits** are unpublished. If you return per-file statistics this way, keep headers small and treat a dropped header as "unknown" rather than zero.
5. **Whether the system's iCloud download transiently occupies phone storage** — how it interacts with `Optimize Storage`, and how aggressively the Photos cache is evicted under a large library. Untested.
6. **Whether `process()` callable from the host app measurably accelerates the next run** is read from the symbol's abstract ("Request to initiate processing background upload jobs"); the effect is untested.
7. **Resumability fallback.** That a `501` response to the `OPTIONS` preflight cleanly degrades to a plain non-resumable upload is inferred from the doc's wording, not stated. Test against a real WebDAV server.
8. **`MKCOL` via `URLSession`** rests on `URLRequest.httpMethod` being a free-form `String`; no example of it in the wild surfaced. Very likely fine, and the MVP's local run confirms it against rclone — unconfirmed against other servers.
9. **Not investigated at all:** Live Photos as paired resources (two jobs per asset?), `PHAssetResource` selection for ProRAW/DNG and edited-vs-original, and `photoProxy` semantics.

### Evidence gaps in the surrounding research

10. **No WebDAV directory-listing benchmark was found** — §6.3's constants come from SMB and general NAS guidance. The WebDAV client in Apple's upload path may be slower or faster; unmeasured.
11. **No guidance found from Apple on filenames or folders** for this API — §6.3/§6.4 are conventions assembled from Nextcloud, PhotoSync, and Immich, not from documentation. The one first-party signal (`X-Filename` in the article's example) points at an API endpoint rather than a tree.
12. **Whether the nextcloud/ios implementation is App-Store-approved.** The repo is the upstream GPL project; I did not verify a shipping App Store build contains this extension. If App Review acceptance of `com.apple.photos.background-upload` matters to the decision, confirm separately.
13. **The Synology File Station API guide is dated 2023** (the copy retrieved carried a 2023 Synology copyright). Endpoint shapes may have moved; check against current DSM.
14. **QNAP/TrueNAS WebDAV specifics** rest on vendor-adjacent and secondary pages, not on QNAP/iXsystems documentation read directly.
15. **Immich's rejection of `PHAssetResourceUploadJob`** is inferred from the absence of a background-upload extension in its iOS tree; I did not read a maintainer statement.
16. **Whether `NSExceptionDomains` CIDR entries actually admit a private-range IP on iOS 17+.** Documented as supported, and the mechanism §8.2 recommends, but the single practitioner report found had both ATS keys set and still failed. Test `http://192.168.x.x` on a device before trusting it; a hostname sidesteps the question entirely. An ATS block surfaces as -1200, not as §8.1's local-network denial.

### PhotoSync claims

17. **PhotoSync may have an undocumented statistics screen.** §7.4's rate finding is a documentation negative, not a proof of absence.
18. **Whether PhotoSync uses any PhotoKit background API.** Its background model is described only in support terms (charging, app switcher). §7.4's "weaker by construction" is inference from its age and its described constraints.
19. **PhotoSync's iCloud-offload behaviour** is inferred, not documented — I did not find a support article describing how it handles `Optimize Storage` originals.

---

## 12. Source index

**Apple — the upload-job API**
- Uploading asset resources in the background — https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background
- `PHAssetResourceUploadJob` — https://developer.apple.com/documentation/photos/phassetresourceuploadjob
- `PHAssetResourceUploadJobChangeRequest` — https://developer.apple.com/documentation/photos/phassetresourceuploadjobchangerequest · `creationRequestForJob(destination:resource:)` — https://developer.apple.com/documentation/photos/phassetresourceuploadjobchangerequest/creationrequestforjob(destination:resource:)
- `jobLimit` — https://developer.apple.com/documentation/photos/phassetresourceuploadjob/joblimit
- `PHAssetResourceUploadJob.Type` (`upload` / `downloadOnly`) — https://developer.apple.com/documentation/photos/phassetresourceuploadjob/type-swift.enum
- `responseHeaderFields` (iOS 26.4+) — https://developer.apple.com/documentation/photos/phassetresourceuploadjob/responseheaderfields
- `PHBackgroundResourceUploadExtension` (iOS 26.1, deprecated 27) — https://developer.apple.com/documentation/photos/phbackgroundresourceuploadextension · `process()` — https://developer.apple.com/documentation/photos/phbackgroundresourceuploadextension/process/
- `PHBackgroundResourceUploadProcessingResult` — https://developer.apple.com/documentation/photos/phbackgroundresourceuploadprocessingresult
- `PHAssetResourceUploadJobOptions` — https://developer.apple.com/documentation/photos/phassetresourceuploadjoboptions
- `PHPhotoLibrary.setUploadJobExtensionEnabled(_:)` — https://developer.apple.com/documentation/photos/phphotolibrary/setuploadjobextensionenabled(_:)
- `PHPhotosError.limitExceeded` — https://developer.apple.com/documentation/photos/phphotoserror-swift.struct/limitexceeded

**Apple — photos, changes, resources**
- `fetchPersistentChanges(since:)` — https://developer.apple.com/documentation/photos/phphotolibrary/fetchpersistentchanges(since:) · `PHPersistentChange` / `PHPersistentObjectChangeDetails` — https://developer.apple.com/documentation/photos/phpersistentchange
- `PHPhotoLibraryPersistentChangesObserver` (iOS 27) — https://developer.apple.com/documentation/photos/phphotolibrarypersistentchangesobserver
- `PHAssetResourceManager` — https://developer.apple.com/documentation/photos/phassetresourcemanager · `writeData(for:toFile:options:completionHandler:)` — https://developer.apple.com/documentation/photos/phassetresourcemanager/writedata(for:tofile:options:completionhandler:) · `exportedAssetID(for:)` (iOS 27; CloudKit-only) — https://developer.apple.com/documentation/photos/phassetresourcemanager/exportedassetid(for:)
- `PHAssetResourceRequestOptions.isNetworkAccessAllowed` — https://developer.apple.com/documentation/photos/phassetresourcerequestoptions/isnetworkaccessallowed · `progressHandler` — https://developer.apple.com/documentation/photos/phassetresourcerequestoptions/progresshandler
- `PHAssetResourceType` (all 13 cases) — https://developer.apple.com/documentation/photos/phassetresourcetype
- `PHAssetResource.originalFilename` — https://developer.apple.com/documentation/photos/phassetresource/originalfilename · `filename` — https://developer.apple.com/documentation/photos/phassetresource/filename · `dataSize` (iOS 27.0+, `Int?`, may be unknown) — https://developer.apple.com/documentation/photos/phassetresource/datasize-5lxva
- `PHAsset.localIdentifier` format `<UUID>/L0/001`, not filename-safe — https://stackoverflow.com/questions/28887638/how-to-get-an-alasset-url-from-a-phasset · https://developer.apple.com/forums/thread/124105

**Apple — background, storage, privacy, review**
- Choosing Background Strategies — https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app · Performing long-running tasks on iOS and iPadOS — https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados
- Optimizing Your App's Data for iCloud Backup — https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup · Using the file system effectively — https://developer.apple.com/documentation/foundation/using-the-file-system-effectively · `URLResourceKey.isPurgeableKey` — https://developer.apple.com/documentation/foundation/urlresourcekey/ispurgeablekey
- TN3179 Understanding local network privacy — https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy · TN3181 Debugging an invalid privacy manifest — https://developer.apple.com/documentation/technotes/tn3181-debugging-an-invalid-privacy-manifest
- `NSLocalNetworkUsageDescription` — https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription · `NSAllowsLocalNetworking` — https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
- Providing access to directories — https://developer.apple.com/documentation/uikit/providing-access-to-directories
- iOS 27 release notes — https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes · Developer News, iOS 27 SDK floor — https://developer.apple.com/news/?id=k1mtkt1k
- App Store Review Guidelines — https://developer.apple.com/app-store/review/guidelines/

**Reference implementations**
- nextcloud/ios — https://github.com/nextcloud/ios · `BackgroundUploadExtension/` — https://github.com/nextcloud/ios/tree/master/BackgroundUploadExtension
- `BackgroundUploadExtension+Destination.swift` (`X-NC-WebDAV-Auto-Mkcol`, `X-OC-CTime`/`X-OC-MTime`) — https://github.com/nextcloud/ios/blob/master/BackgroundUploadExtension/BackgroundUploadExtension%2BDestination.swift
- `NCManageDatabase+Metadata.swift` (the `tableMetadata` mapping record) — https://github.com/nextcloud/ios/blob/master/iOSClient/Data/NCManageDatabase%2BMetadata.swift
- `NCUtilityFileSystem.swift` (`createGranularityPath`: yearly/monthly/daily) — https://github.com/nextcloud/ios/blob/master/iOSClient/Utility/NCUtilityFileSystem.swift
- `NCAutoUpload.swift` (folder pre-creation, Live Photo `.mov` pairing) — https://github.com/nextcloud/ios/blob/master/iOSClient/Networking/NCAutoUpload.swift
- immich-app/immich — https://github.com/immich-app/immich · storage template (default `Year/Year-Month-Day/Filename.Extension`, sequence-number collisions, server-local timezone) — https://docs.immich.app/administration/storage-template
- xtool issue #138 (ExtensionKit) — https://github.com/xtool-org/xtool/issues/138 · Appex docs — https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Appex.md
- AMSMB2 — https://github.com/amosavian/AMSMB2 · libsmb2 — https://github.com/sahlberg/libsmb2 · Citadel — https://github.com/orlandos-nl/Citadel

**PhotoSync**
- photosync-app.com — https://www.photosync-app.com/home · App Store listing — https://apps.apple.com/cn/app/id415850124
- iOS Pro/Premium feature comparison — https://www.photosync-app.com/support/ios/answers/what-is-the-difference-between-photosync-pro-and-premium
- Autotransfer triggers / iBeacon (app-switcher requirement) — https://www.photosync-app.com/support/ios/answers/how-to-use-an-ibeacon-to-autotransfer-on-ios
- Custom subdirectories / date tokens (`%YR`/`%mR`/`%dR` vs `%YT`/`%mT`/`%dT`; album duplicate caveat) — https://www.photosync-app.com/support/ios/answers/how-to-automatically-create-subdirectories-on-the-target-device-service
- Identifiers change after restore — https://www.photosync-app.com/support/basics/answers/new-photosvideos-are-no-longer-recognized-how-can-i-fix-this
- Nextcloud forum thread quoting PhotoSync support on background limits — https://help.nextcloud.com/t/hochladen-geht-mit-ios-17-nicht-im-hintergrund/178499/9

**NAS / protocol**
- RFC 4918 §9.7.1 — `PUT` must not create intermediate collections (409) — https://datatracker.ietf.org/doc/html/draft-ietf-webdav-rfc2518bis#9 · RFC 2518 §8.7.1 — https://datatracker.ietf.org/doc/html/rfc2518
- Apache WAGON-38 / IVY-1193 (real-world `PUT`-without-`MKCOL` failures; 403-instead-of-409 wart) — https://issues.apache.org/jira/browse/WAGON-38 · https://issues.apache.org/jira/browse/IVY-1193
- Synology File Station API Guide — https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf · WebDAV Server KB — https://kb.synology.com/en-global/DSM/help/WebDAVServer/webdav_server

**Scale**
- TrueNAS SMB directory list times (100K/1M files by client; macOS Finder 15.5 min) — https://github.com/truenas/documentation/blob/2cea8f1c97d5524e081f59cc609c126eb8f6c1ad/content/References/Performance/SMBFileTimes.md
- Alibaba Cloud NAS performance FAQ (keep directories under 10,000 files) — https://www.alibabacloud.com/help/ja/nas/user-guide/faq-about-the-performance-of-nas-file-systems
- ext4 inode exhaustion under high file counts — https://shop.zimaspace.com/blogs/tech-ai-hub/high-file-count-exhausts-home-nas-inodes-first

**Developer Forums (secondary but Apple-hosted)**
- SMB in Files app / bookmark behaviour — https://developer.apple.com/forums/thread/773970 · https://developer.apple.com/forums/thread/131644 · https://developer.apple.com/forums/thread/774114
- Open Radar FB23870865 (payload transform request) — http://ileyf.cn.openradar.appspot.com/FB23870865

---

*Compiled 2026-09-24. Every non-obvious claim is linked at the point of use. §11 lists where the evidence is weaker than the surrounding text implies — items 1 and 2 in particular are assumptions that should be settled by experiment before any further code is written.*
