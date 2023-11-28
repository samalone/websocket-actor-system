//
//  Manager.swift
//
//
//  Created by Stuart A. Malone on 11/28/23.
//

import Foundation

/// A `Manager` is an actor protocol that provides the `WebSocketActorSystem`
/// with a uniform interface to clients and servers, so that certain universal
/// operations can be performed without caring which mode the actor system is in.
protocol Manager {
    /// Return the local port number. For the server, this is the port it is listening on.
    /// For a client, this is the (less important) local port number it is connecting from.
    ///
    /// - Note: Even for a server, the`localPort()` is only needed
    /// when the server was created on port 0, which uses a system-assigned port.
    /// This is normally the case only when writing tests. In production, the server
    /// is usually created on a fixed port number and calls to `localPort()` are not needed.
    func localPort() async throws -> Int

    /// Select a channel to the given `actorID`. This function is only called for remote actors.
    /// Clients can simply return their current channel, while servers need to look up the
    /// channel associated with the actor's node ID.
    func remoteNode(for nodeID: ActorIdentity) async throws -> RemoteNode

    /// Close all channels and stop re-opening them. This is called when the actor system
    /// wants to shut down.
    func cancel() async

    func opened(remote: RemoteNode) async
    func closing(remote: RemoteNode) async
}
