# Structuring a distributed actor project

How to organize your code for an easy development experience

## Project structure

The client and server in a distributed actor system are tightly coupled. You can
take advantage of this by organizing your project to include the client, server,
and shared library code in a single Xcode workspace where they can all be
developed and tested together.

For a sample project that uses this structure, see
[https://github.com/samalone/monotonic](https://github.com/samalone/monotonic).

### Create the shared library

To get started, create a Swift Package Manager project for the shared library.
The name of this folder is usually lower case, and it will become the repository
name. The name of the package is usually capitalized, and it will become the
module name. For example:

```bash
> mkdir sunny-weather
> cd sunny-weather
> swift package init --type library --name SunnyWeather
```

### Add shared library dependencies

Edit the `Package.swift` file to add dependencies on the distributed actor
system and any other libraries you need.

```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SunnyWeather",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "SunnyWeather",
            targets: ["SunnyWeather"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/samalone/websocket-actor-system.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "SunnyWeather",
            dependencies: [
                .product(name: "WebSocketActors", package: "websocket-actor-system"),
            ]
        ),
        .testTarget(
            name: "SunnyWeatherTests",
            dependencies: ["SunnyWeather"]),
    ]
)
```

### Add a server executable

This creates a server that will run on macOS during development, and on Linux in
production.

```swift
let package = Package(
    name: "SunnyWeather",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "SunnyWeather",
            targets: ["SunnyWeather"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/samalone/websocket-actor-system.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "SunnyWeather",
            dependencies: [
                .product(name: "WebSocketActors", package: "websocket-actor-system"),
            ]
        ),
        .executableTarget(
            name: "Server",
            dependencies: [
                "SunnyWeather",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SunnyWeatherTests",
            dependencies: ["SunnyWeather"]),
    ]
)
```

### Create an iOS client project

Use Xcode to create an iOS client project inside your package folder. Give this
Xcode project a different name than the package so you will be able to
distinguish them easily in Xcode.

The Xcode client project needs a reference to the shared library. I do this by
publishing the package folder as a GitHub repository, and then adding it as a
dependency in the Xcode project. You can use a private repository as long as
Xcode knows your GitHub credentials. If you absolutely must keep everything
local, see Steven Burns article on
[Using Local Swift Packages in Xcode, Without Making Them Git repos](https://medium.com/swlh/using-local-swift-packages-in-xcode-without-making-them-git-repos-3aa046cc222c).

Note that the next step will override this dependency, so you can use the latest
version of your shared library without pushing it to your repository.

### Create an Xcode workspace

Create an empty Xcode workspace in the package folder, and add both the Xcode
project and the package folder to it. This workspace is where you will do most
of your development work, since it will allow you to build and test the client
and server together.

Another advantage of doing development in a workspace is that the package folder
in the workspace overrides the package dependency in the Xcode client project,
allowing the client project to use the latest code from the package folder.
