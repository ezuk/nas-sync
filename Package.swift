// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NASSync",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .executable(name: "nas-sync", targets: ["nas-sync"]),
    ],
    targets: [
        .target(
            name: "SyncCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("NetFS"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(name: "nas-sync", dependencies: ["SyncCore"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"]),
    ]
)
