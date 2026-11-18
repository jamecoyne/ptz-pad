// swift-tools-version:5.9
import PackageDescription
import Foundation

// Syphon is not part of macOS. TouchDesigner, OBS and Resolume each ship a universal
// build of it; compile and link against whichever is installed. make-app.sh and
// release.sh copy the same framework into the app bundle, which is found first through
// the @executable_path rpath; the second rpath only matters for `swift run`.
// SYPHON_FRAMEWORK_DIR (set by release.sh, and by CI to a copy built by
// scripts/build-syphon.sh) is searched first.
let syphonCandidates = [ProcessInfo.processInfo.environment["SYPHON_FRAMEWORK_DIR"]].compactMap { $0 } + [
    "/Applications/TouchDesigner.app/Contents/Frameworks",
    "/Applications/OBS.app/Contents/Frameworks",
    "/Library/Frameworks",
]
let syphonDir = syphonCandidates.first {
    FileManager.default.fileExists(atPath: "\($0)/Syphon.framework")
} ?? "/Library/Frameworks"

let package = Package(
    name: "PTZPad",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CBridge",
            path: "Sources/CBridge",
            cSettings: [.unsafeFlags(["-F", syphonDir, "-Wno-incomplete-umbrella"])]
        ),
        .executableTarget(
            name: "PTZPad",
            dependencies: ["CBridge"],
            path: "Sources/PTZPad",
            swiftSettings: [.unsafeFlags(["-F", syphonDir, "-Xcc", "-Wno-incomplete-umbrella"])],
            linkerSettings: [
                .linkedFramework("GameController"),
                .linkedFramework("Network"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .unsafeFlags([
                    "-F", syphonDir, "-framework", "Syphon",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", syphonDir,
                ]),
            ]
        ),
    ]
)
