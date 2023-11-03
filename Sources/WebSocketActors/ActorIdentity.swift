/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Used as `ActorID` by all distributed actors in this sample app. It is used to uniquely identify any given actor within its actor system.
*/

import Foundation
import Distributed

/// An `ActorIdentity` is a string that uniquely identifies a distributed object
/// across all of the clients and servers in a ``WebSocketActorSystem``.
///
///  A UUID is a common way of generating a unique `ActorIdentity`,
///  and the ``random()`` function will create that. Alternatively, you can
///  use the ``random(for:)`` function to generate a UUID that is prefixed
///  with the type of the actor, which can be useful for generating actors
///  on-demand, or simply for easier debugging.
///
///  A distributed actor system also typically needs one or more actors
///  with fixed identities as a starting point for communications. You can
///  use ``init(id:)`` or ``init(stringLiteral:)`` with a constant
///  string to create these.
public struct ActorIdentity: Hashable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    
    public init(id: String) {
        self.id = id
    }
    
    /// Create a random ActorIdentity
    public static func random() -> Self {
        .init(id: "\(UUID().uuidString)")
    }
    
    /// Create a random ActorIdentity with the provided prefix
    public static func random(prefix: String) -> Self {
        .init(id: "\(prefix)/\(UUID().uuidString)")
    }
    
    /// Create a random ActorIdentity with a prefix based on the provided type.
    public static func random<Act>(for actorType: Act.Type) -> Self
    where Act: DistributedActor, Act.ID == ActorIdentity
    {
        .random(prefix: "\(Act.self)")
    }
    
    /// Does this id have the proper prefix for the provided type?
    public func hasPrefix<Act>(for actorType: Act.Type) -> Bool
    where Act: DistributedActor, Act.ID == ActorIdentity
    {
        id.hasPrefix("\(Act.self)/")
    }
    
    /// Returns the portion of the id before the first slash, or `nil`
    /// if the id does not contain a slash.
    ///
    /// You can use this prefix to construct actors on-demand
    /// according to their type.
    public var prefix: String? {
        if let firstSlash = id.firstIndex(of: "/") {
            return String(id[id.startIndex ..< firstSlash])
        }
        return nil
    }
    
    public var description: String {
        id
    }
    
    public var debugDescription: String {
        "\(Self.self)(\(self.description))"
    }
}

extension ActorIdentity: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.id = value
    }
}
