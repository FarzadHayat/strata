// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Strata",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "strata", targets: ["Strata"]),
    ],
    targets: [
        // Pure logic: key tables, config parser/CST, compiler, layer engine. No IOKit.
        .target(name: "StrataCore"),
        // IOKit device seizing, Karabiner virtual HID client, caps lock.
        .target(name: "StrataHID", dependencies: ["StrataCore"]),
        // Daemon <-> GUI protocol (JSON lines over a Unix socket).
        .target(name: "StrataIPC", dependencies: ["StrataCore"]),
        // Single executable: daemon / GUI / CLI roles selected by argv.
        .executableTarget(
            name: "Strata",
            dependencies: ["StrataCore", "StrataHID", "StrataIPC"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .testTarget(name: "StrataCoreTests", dependencies: ["StrataCore"]),
    ],
    swiftLanguageModes: [.v6]
)
