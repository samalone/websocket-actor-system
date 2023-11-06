# WebSocketActorSystem

[![macOS tests](https://github.com/samalone/websocket-actor-system/actions/workflows/test-macos.yml/badge.svg)](https://github.com/samalone/websocket-actor-system/actions/workflows/test-macos.yml) [![Ubuntu tests](https://github.com/samalone/websocket-actor-system/actions/workflows/test-ubuntu.yml/badge.svg)](https://github.com/samalone/websocket-actor-system/actions/workflows/test-ubuntu.yml)

This is an implementation of Swift's
[distributed actor system](https://developer.apple.com/documentation/distributed)
designed to allow multiple clients to communicate with a single server over
WebSockets. It is based on Apple's
[TicTacFish](https://developer.apple.com/documentation/swift/tictacfish_implementing_a_game_using_distributed_actors)
sample code.

- [API documentation](https://samalone.github.io/websocket-actor-system/documentation/websocketactors/)

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
