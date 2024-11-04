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
public protocol Manager: Sendable {

    /// Close all channels and stop re-opening them. This is called when the actor system
    /// wants to shut down.
    func cancel() async
}
