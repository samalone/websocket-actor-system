# WebSocketActors

[![macOS tests](https://github.com/samalone/websocket-actor-system/actions/workflows/test-macos.yml/badge.svg)](https://github.com/samalone/websocket-actor-system/actions/workflows/test-macos.yml) [![Ubuntu tests](https://github.com/samalone/websocket-actor-system/actions/workflows/test-ubuntu.yml/badge.svg)](https://github.com/samalone/websocket-actor-system/actions/workflows/test-ubuntu.yml)

This is an implementation of Swift's
[distributed actor system](https://developer.apple.com/documentation/distributed)
designed to allow multiple clients to communicate with a single server over
WebSockets. It is based on Apple's
[TicTacFish](https://developer.apple.com/documentation/swift/tictacfish_implementing_a_game_using_distributed_actors)
sample code.

- [API documentation](https://samalone.github.io/websocket-actor-system/documentation/websocketactors/)

## Installation

Add the package `https://github.com/samalone/websocket-actor-system` to your Xcode project, or add:

```swift
   .package(url: "https://github.com/samalone/websocket-actor-system.git", branch: "main"),
```

to your package dependencies in your `Package.swift` file. Then add:

```swift
   .product(name: "WebSocketActors", package: "websocket-actor-system"),
```

to the target dependencies of your package target.

## Getting started

To use the `WebSocketActorSystem` you will need to create a server, a client, and a library that they share.

### Library

The library contains all of the distributed actors that will be shared between the clients and the server.

The server will usually contain at least one actor with a fixed ID that acts as a "receptionist", giving clients access to other actors on the server.

```swift
extension ActorIdentity {
    // Since there is only one receptionist, declare its fixed id
    // so clients know how to refer to it.
    public static let receptionist: ActorIdentity = "receptionist"
}

public distributed actor Receptionist {
    typealias ActorSystem = WebSocketActorSystem

    init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }
}
```

### Server

```swift
@main
struct Server {
    static func main() async throws {
        let serverAddress = ServerAddress(scheme: .insecure, host: "localhost", port: 8888)
        let server = try await WebSocketActorSystem(mode: .server(at: serverAddress), id: "server")

        let receptionist = server.makeLocalActor(id: .receptionist) {
            Receptionist(actorSystem: server)
        }
        
        try await Task.sleep(for: .seconds(100_000))
    }
}
```

### Client

```swift
@main
struct Client {
    static func main() async throws {
        // The public address of the server. If the server is behind
        // a proxy or inside a Docker container, this may be different
        // from the internal server address. 
        let serverAddress = ServerAddress(scheme: .insecure, host: "localhost", port: 8888)

        // It is important to NOT specify a fixed client ID, so that each
        // client will be assigned a unique random ID.
        let client = try await WebSocketActorSystem(mode: .client(of: serverAddress))

        let receptionist = Receptionist.resolve(id: .receptionist, using: client)
        
        try await Task.sleep(for: .seconds(100_000))
    }

}
```

Once created, the server runs automatically in the background. Perform other actions or sleep the main thread to prevent the server from exiting.

## Target use case

This actor system is designed to be used in an iOS app that needs real-time
collaboration between users. The app uses distributed actors that communicate
over a websocket to a Linux server in a Docker container on the internet, which
maintains the state of the application and broadcasts changes to the client
applications. Both the iOS application and the server are written in Swift.

## Motivation

The usual way of writing a client/server app like this is to write an OpenAPI
specification for the interface between the clients and the server, but this has
a few problems for our use case:

1. OpenAPI requires creating a YAML file for the interface that largely repeats
   the client and server APIs in a different language. This makes sense for a
   public API, but is unnecessary work for a private API with a single client.

2. A real-time collaborative app benefits from the efficiency of websockets, but
   OpenAPI is based on REST.

By using distributed actors instead of OpenAPI, we can write the client and
server entirely in Swift and avoid the boilerplate code to convert to and from
web REST calls.

## Design goals

- The client should run on iOS and macOS.
- The server should run on macOS and Linux.
- The server should be capable of running inside a Docker container behind an
  Nginx proxy that handles TLS.

This system does _not_ support direct communication between clients, or
automated forwarding of messages from client to client through the server.
