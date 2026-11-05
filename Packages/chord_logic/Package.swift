// swift-tools-version:6.2
import PackageDescription

// Logic that does not need AppKit or WebKit lives here, so `swift test` covers
// it without building or launching the application.
let package = Package(
    name: "chord_logic",
    platforms: [.macOS(.v26)],
    products: [.library(name: "chord_logic", targets: ["chord_logic"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0")
    ],
    targets: [
        .target(name: "chord_logic", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "chord_logicTests", dependencies: ["chord_logic"])
    ]
)
