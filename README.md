# WebSocketActors

[![Swift Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsamalone%2Fwebsocket-actor-system%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/samalone/websocket-actor-system)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsamalone%2Fwebsocket-actor-system%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/samalone/websocket-actor-system)

[![macOS tests](https://github.com/samalone/websocket-actor-system/actions/workflows/test-macos.yml/badge.svg)](https://github.com/samalone/websocket-actor-system/actions/workflows/test-macos.yml)
[![Ubuntu tests](https://github.com/samalone/websocket-actor-system/actions/workflows/test-ubuntu.yml/badge.svg)](https://github.com/samalone/websocket-actor-system/actions/workflows/test-ubuntu.yml)

WebSocketActors is a client/server communications library that allows an iOS,
macOS, tvOS, or watchOS app to communicate with a server on the internet using
Swift's
[distributed actor system](https://developer.apple.com/documentation/distributed).
It's a streamlined alternative to writing a server using Swagger/OpenAPI and
then implementing your client app on top of that API. With WebSocketActors, you
can make Swift function calls directly between your client and server.

This library is based on Apple's
[TicTacFish](https://developer.apple.com/documentation/swift/tictacfish_implementing_a_game_using_distributed_actors)
sample code, but adds features like:

- Simultaneous connections to multiple servers & clients
- Automatic reconnection after network failures
- Server calls to client actors (server push)
- Logging with [SwiftLog](https://github.com/apple/swift-log)

## Installation

Add the package `https://github.com/samalone/websocket-actor-system` to your
Xcode project, or add:

```swift
   .package(url: "https://github.com/samalone/websocket-actor-system.git", from: "1.0"),
```

to your package dependencies in your `Package.swift` file. Then add:

```swift
   .product(name: "WebSocketActors", package: "websocket-actor-system"),
```

to the target dependencies of your package target.

## Quick start

In your shared library, import `WebSocketActors` and define your distributed
actors.

```swift
import Distributed
import WebSocketActors

extension NodeIdentity {
   public static let server = NodeIdentity(id: "server")
}

extension ActorIdentity {
   public static let greeter = ActorIdentity(id: "greeter", node: .server)
}

public distributed Actor Greeter {
   public typealias ActorSystem = WebSocketActorSystem

   public distributed func greet(name: String) -> String {
      return "Hello, \(name)!"
   }
}
```

In your server code, start the server in the background and make sure the server
keeps running.

```swift
func main() async throws {
   let address = ServerAddress(scheme: .insecure, host: "localhost", port: 8888)
   let system = WebSocketActorSystem()
   try await system.runServer(at: address)

   _ = system.makeLocalActor(id: .greeter) {
      Greeter(actorSystem: system)
   }

   while true {
      try await Task.sleep(for: .seconds(1_000_000))
   }
}
```

On the client, connect to the server and call the remote actor.

```swift
func receiveGreeting() async throws {
   let address = ServerAddress(scheme: .insecure, host: "localhost", port: 8888)
   let system = WebSocketActorSystem()
   try await system.connectClient(to: address)

   let greeter = try Greeter.resolve(id: .greeter, using: system)
   let greeting = try await greeter.greet(name: "Alice")
   print(greeting)
}
```

## Documentation

The documentation for WebSocketActors includes both API documentation and
getting-started articles:

- [WebSocketActors documentation](https://samalone.github.io/websocket-actor-system/documentation/websocketactors/)

## Sample Code

For a basic example of writing a client/server app using WebSocketActors, see my
[Monotonic](https://github.com/samalone/monotonic) project. It implements a
simple iOS app that displays a counter above an "Increment" button. Clicking the
increment button bumps the counters on _all_ client apps connected to the server
in real time.

## Additional reading

- [Introducing Swift Distributed Actors](https://www.swift.org/blog/distributed-actors/) from the Swift Blog.
- [Introducing Distributed Actors](https://swiftpackageindex.com/apple/swift-distributed-actors/main/documentation/distributedcluster/introduction) from Apple's [DistributedCluster](https://github.com/apple/swift-distributed-actors/) documentation
- [Meet distributed actors in Swift](https://developer.apple.com/videos/play/wwdc2022/110356/) from WWDC 2022
- Apple's documentation on the [Distributed](https://developer.apple.com/documentation/distributed) module.
- Apple's [TicTacFish](https://developer.apple.com/documentation/swift/tictacfish_implementing_a_game_using_distributed_actors) sample code
