// swift-tools-version:5.9
// Tests for the platform-independent part of the app (Sources/Core): `swift test`.
// The app itself is built from project.yml (XcodeGen), which compiles the same files.
import PackageDescription

let package = Package(
    name: "KinotekaCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(name: "KinotekaCore", path: "Sources/Core"),
        .testTarget(name: "KinotekaCoreTests", dependencies: ["KinotekaCore"], path: "Tests/KinotekaCoreTests")
    ]
)
