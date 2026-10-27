// swift-tools-version: 6.0
// Vendored from https://github.com/Rajaniraiyn/CefSwift at 59cad64e124b8efdb6b2ee811963097bb6e689e8
// (CEF 154), trimmed to the libraries Tako links. Tako's changes are listed in TAKO-PATCHES.md.
import PackageDescription

let package = Package(
    name: "CefSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CefKit", targets: ["CefKit"]),
        .library(name: "CefSwiftUI", targets: ["CefSwiftUI"]),
    ],
    targets: [
        // Vendored CEF C API headers + runtime dlopen/dlsym loader.
        .target(
            name: "CCef",
            exclude: [
                "LICENSE.CEF.txt",
                "include/include/base/internal/cef_color_id_macros.inc",
                "include/include/base/internal/README-TRANSFER.txt",
            ],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        // NSApplication subclass conforming to CEF's CrAppControlProtocol.
        .target(
            name: "CCefAppKit",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Core Swift wrapper over the CEF C API.
        .target(
            name: "CefKit",
            dependencies: ["CCef", "CCefAppKit"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // First-class SwiftUI integration.
        .target(
            name: "CefSwiftUI",
            dependencies: ["CefKit"]
        ),
    ],
    cLanguageStandard: .c11
)
