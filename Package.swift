// swift-tools-version: 6.4
import PackageDescription

// The second way to build this app. Xcode builds ImageBackup.xcodeproj; xtool builds this package
// into a .app/.ipa on Linux. Both compile the sources in app/.
//
// swift-tools-version 6.4 and iOS 27 are the floors: `.iOS(.v27)` does not exist before
// PackageDescription 6.4, and the app calls PHAssetResource.dataSize and .filename (both iOS 27).
let package = Package(
    name: "ImageBackup",
    platforms: [.iOS(.v27)],
    products: [
        // xtool requires exactly one library product: the app itself.
        .library(name: "ImageBackup", targets: ["ImageBackup"])
    ],
    targets: [
        .target(
            name: "ImageBackup",
            path: "app",
            // xtool.yml supplies its own plist and copies the privacy manifest.
            exclude: ["README.md", "Info.plist", "PrivacyInfo.xcprivacy"]
        )
    ]
)
