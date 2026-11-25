// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "FlutterGeneratedPluginSwiftPackage", type: .static, targets: ["FlutterGeneratedPluginSwiftPackage"])
    ],
    dependencies: [
        .package(name: "connectivity_plus", path: "../.packages/connectivity_plus-7.2.0"),
        .package(name: "file_picker_darwin", path: "../.packages/file_picker_darwin-2.5.2"),
        .package(name: "image_picker_ios", path: "../.packages/image_picker_ios-0.8.13+16"),
        .package(name: "mobile_scanner", path: "../.packages/mobile_scanner-7.5.0"),
        .package(name: "package_info_plus", path: "../.packages/package_info_plus-10.2.2"),
        .package(name: "shared_preferences_foundation", path: "../.packages/shared_preferences_foundation-2.5.7"),
        .package(name: "sqflite_darwin", path: "../.packages/sqflite_darwin-2.4.6"),
        .package(name: "url_launcher_ios", path: "../.packages/url_launcher_ios-6.4.2"),
        .package(name: "FlutterFramework", path: "../.packages/FlutterFramework")
    ],
    targets: [
        .target(
            name: "FlutterGeneratedPluginSwiftPackage",
            dependencies: [
                .product(name: "connectivity-plus", package: "connectivity_plus"),
                .product(name: "file-picker-darwin", package: "file_picker_darwin"),
                .product(name: "image-picker-ios", package: "image_picker_ios"),
                .product(name: "mobile-scanner", package: "mobile_scanner"),
                .product(name: "package-info-plus", package: "package_info_plus"),
                .product(name: "shared-preferences-foundation", package: "shared_preferences_foundation"),
                .product(name: "sqflite-darwin", package: "sqflite_darwin"),
                .product(name: "url-launcher-ios", package: "url_launcher_ios"),
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
