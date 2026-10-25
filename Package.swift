// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RunAnyways",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RunAnyways", targets: ["RunAnywaysApp"]),
        .executable(name: "RunAnywaysHelper", targets: ["RunAnywaysHelper"])
    ],
    targets: [
        .target(name: "RunAnywaysCore"),
        .target(name: "RunAnywaysIPC", dependencies: ["RunAnywaysCore"]),
        .executableTarget(name: "RunAnywaysApp", dependencies: ["RunAnywaysCore", "RunAnywaysIPC"]),
        .executableTarget(name: "RunAnywaysHelper", dependencies: ["RunAnywaysCore", "RunAnywaysIPC"]),
        .testTarget(name: "RunAnywaysCoreTests", dependencies: ["RunAnywaysCore"]),
        .testTarget(name: "RunAnywaysHelperTests", dependencies: ["RunAnywaysCore", "RunAnywaysIPC", "RunAnywaysHelper"])
    ]
)
