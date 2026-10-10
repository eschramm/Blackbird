// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Blackbird",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .watchOS(.v8),
        .tvOS(.v15)
    ],
    products: [
        .library(
            name: "Blackbird",
            targets: ["Blackbird"]
        )
    ],
    dependencies: [],
    targets: [
        // Apple platforms ship a `SQLite3` module; elsewhere, link the system's libsqlite3.
        .systemLibrary(
            name: "CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "Blackbird",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux]))
            ]
        ),
        .testTarget(
            name: "BlackbirdTests",
            dependencies: ["Blackbird"]
        )
    ],
    swiftLanguageModes: [.v6]
)
