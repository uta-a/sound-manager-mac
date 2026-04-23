// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "audio-probe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "audio-probe",
            path: "Sources/audio-probe"
        )
    ]
)
