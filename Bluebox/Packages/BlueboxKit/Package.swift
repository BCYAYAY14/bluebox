// swift-tools-version: 6.0
import PackageDescription

// One local package, several focused targets. The dependency graph is:
//
//   Domain  <-  Metadata, MediaSources, Subtitles, Persistence, Playback
//   Sync (Supabase auth + library sync) depends on Metadata (HTTPClient) and Persistence.
//   DesignSystem (UI tokens/components, depends on Domain for image loading types)
//   Features (all screens) depends on everything above.
//   TestingSupport provides fixtures + mocks for tests (never linked into the apps).
let package = Package(
    name: "BlueboxKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BlueboxKit", targets: ["Features"]),
        .library(name: "Domain", targets: ["Domain"]),
        // The Live Activity's attributes and look, shared with the iOS widget extension.
        .library(name: "DownloadsActivity", targets: ["DownloadsActivity"]),
        // The Mac updater's signature check, linked by Apps/macOSUpdater alone.
        .library(name: "UpdateVerification", targets: ["UpdateVerification"]),
    ],
    dependencies: [
        // VLC plays the containers AVFoundation can't (MKV, AVI, WebM…), which is most torrent releases.
        .package(url: "https://github.com/harflabs/SwiftVLC.git", revision: "f0da22b7944deddf855882e1cbb627f8f486f683"),
    ],
    targets: [
        .target(name: "Domain"),
        // No dependencies, so the widget extension stays small.
        .target(name: "DownloadsActivity"),
        // Foundation and Security only: the unsandboxed updater links nothing else.
        .target(name: "UpdateVerification"),
        // libtorrent 2.1 + Bluebox's Objective-C++ wrapper (BBTorrent), built from
        // source by scripts/build-libtorrent.sh for iOS, the iOS simulator and macOS.
        .binaryTarget(name: "LibTorrentEngine", path: "LibTorrent/LibTorrentEngine.xcframework"),
        .target(
            name: "TorrentStreaming",
            dependencies: [
                "Domain",
                "LibTorrentEngine",
            ],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("SystemConfiguration")]
        ),
        .target(name: "Addons", dependencies: ["Domain", "TorrentStreaming"]),
        .target(
            name: "VLCPlayback",
            dependencies: ["Domain", "Playback", "Subtitles", "VLCVariables", .product(name: "SwiftVLC", package: "SwiftVLC")]
        ),
        // libvlccore's variable API (in SwiftVLC's static libVLC): live subtitle looks.
        .target(name: "VLCVariables"),
        .target(name: "DesignSystem", dependencies: ["Domain"]),
        .target(name: "Metadata", dependencies: ["Domain"]),
        // Skip Intro/Recap/Credits: chapter titles, Jellyfin segments, TheIntroDB and IntroDB.
        .target(name: "SkipSegments", dependencies: ["Metadata"]),
        .target(name: "Torrent", dependencies: ["Domain"]),
        .target(name: "Downloads", dependencies: ["Domain"]),
        .target(name: "MediaSources", dependencies: ["Domain", "Metadata", "Torrent"]),
        // Fonts: Atkinson Hyperlegible and Inter (SIL OFL), for subtitles that look the same on every device.
        .target(name: "Subtitles", dependencies: ["Domain"], resources: [.copy("Fonts")]),
        .target(name: "Persistence", dependencies: ["Domain"]),
        .target(name: "Playback", dependencies: ["Domain", "Subtitles"]),
        .target(name: "Sync", dependencies: ["Domain", "Metadata", "Persistence"]),
        .target(
            name: "TestingSupport",
            dependencies: ["Domain", "Metadata", "MediaSources"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "Features",
            dependencies: [
                "Domain", "DesignSystem", "Metadata", "MediaSources",
                "Subtitles", "Persistence", "Playback", "Sync", "Torrent", "Downloads",
                "TorrentStreaming", "VLCPlayback", "Addons", "SkipSegments", "DownloadsActivity",
                "UpdateVerification",
            ]
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain", "TestingSupport"]),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata", "TestingSupport"]),
        .testTarget(name: "MediaSourcesTests", dependencies: ["MediaSources", "Torrent", "TestingSupport"]),
        .testTarget(name: "SubtitlesTests", dependencies: ["Subtitles"]),
        .testTarget(name: "SkipSegmentsTests", dependencies: ["SkipSegments", "Metadata"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "TestingSupport"]),
        .testTarget(name: "PlaybackTests", dependencies: ["Playback", "TestingSupport"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "Domain", "Persistence", "SkipSegments", "TestingSupport",
                                                         "DownloadsActivity", "Downloads", "Sync",
                                                         .product(name: "SwiftVLC", package: "SwiftVLC")]),
        .testTarget(name: "DownloadsTests", dependencies: ["Downloads", "TestingSupport"]),
        .testTarget(name: "TorrentTests", dependencies: ["Torrent", "TestingSupport"]),
        .testTarget(name: "AddonsTests", dependencies: ["Addons"]),
        .testTarget(name: "TorrentStreamingTests", dependencies: ["TorrentStreaming"]),
        .testTarget(name: "UpdateVerificationTests", dependencies: ["UpdateVerification"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "Persistence", "TestingSupport"]),
    ]
)
