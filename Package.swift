// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nebula",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nebula",
            path: "Sources/Nebula",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
