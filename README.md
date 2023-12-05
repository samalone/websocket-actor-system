# WebSocketActors

[![macOS tests](https://github.com/samalone/websocket-actor-system/actions/workflows/test-macos.yml/badge.svg)](https://github.com/samalone/websocket-actor-system/actions/workflows/test-macos.yml) [![Ubuntu tests](https://github.com/samalone/websocket-actor-system/actions/workflows/test-ubuntu.yml/badge.svg)](https://github.com/samalone/websocket-actor-system/actions/workflows/test-ubuntu.yml)

WebSocketActors is a client/server communications library that allows an iOS, macOS, tvOS, or watchOS app to communicate with a server on the internet using Swift's [distributed actor system](https://developer.apple.com/documentation/distributed). It's a streamlined alternative to writing a server using Swagger/OpenAPI and then implementing your client app on top of that API. With WebSocketActors, you can make Swift function calls directly between your client and server.

This library is based on Apple's
[TicTacFish](https://developer.apple.com/documentation/swift/tictacfish_implementing_a_game_using_distributed_actors)
sample code, but adds features like:

- Simultaneous connections to multiple servers & clients
- Automatic reconnection after network failures
- Server calls to client actors (server push)
- Logging with [SwiftLog](https://github.com/apple/swift-log)

## Installation

Add the package `https://github.com/samalone/websocket-actor-system` to your Xcode project, or add:

```swift
   .package(url: "https://github.com/samalone/websocket-actor-system.git", from: "1.0"),
```

to your package dependencies in your `Package.swift` file. Then add:

```swift
   .product(name: "WebSocketActors", package: "websocket-actor-system"),
```

to the target dependencies of your package target.

## Documentation

The documentation for WebSocketActors includes both API documentation and getting-started articles:

- [WebSocketActors documentation](https://samalone.github.io/websocket-actor-system/documentation/websocketactors/)

## Sample Code

For a basic example of writing a client/server app using WebSocketActors, see my [Monotonic](https://github.com/samalone/monotonic) project. It implements a simple iOS app that displays a counter above an "Increment" button. Clicking the increment button bumps the counters on _all_ client apps connected to the server in real time.