/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Used as `ActorID` by all distributed actors in this sample app. It is used to uniquely identify any given actor within its actor system.
*/

import Foundation
import Distributed

/// An `ActorIdentity` can be any string that is unique within the ``WebSocketActorSystem``,
/// but there is special support for identities of the form "Type/UUID".
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
    func hasPrefix<Act>(for actorType: Act.Type) -> Bool
    where Act: DistributedActor, Act.ID == ActorIdentity
    {
        id.hasPrefix("\(Act.self)/")
    }
    
    public var description: String {
        id
    }
    
    public var debugDescription: String {
        "\(Self.self)(\(self.description))"
    }
}
