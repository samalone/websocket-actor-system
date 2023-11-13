/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Used as `ActorID` by all distributed actors in this sample app. It is used to uniquely identify any given actor within its actor system.
*/

import Foundation
import Distributed
import NIO
import NIOWebSocket

/// An `ActorIdentity` is a string that uniquely identifies a distributed object
/// across all of the clients and servers in a ``WebSocketActorSystem``.
///
/// Only the `id` field is used to determine equality of two actor identities.
/// The `node` and `type` fields are used to store optional additional information
/// about the actor.
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
public struct ActorIdentity: Sendable, Encodable, CustomStringConvertible, CustomDebugStringConvertible {
    public let node: NodeIdentity?
    public let id: String
    public let type: String?
    
    public init(id: String, type: String? = nil, node: NodeIdentity? = nil) {
        self.id = id
        self.type = type
        self.node = node
    }
    
    enum CodingKeys: String, CodingKey {
        case node
        case id
        case type
    }
    
    /// Create a random ActorIdentity
    public static func random(type: String? = nil, node: NodeIdentity? = nil) -> Self {
        .init(id: "\(UUID().uuidString)", type: type, node: node)
    }
    
    /// Create a random ActorIdentity with a prefix based on the provided type.
    public static func random<Act>(for actorType: Act.Type, node: NodeIdentity? = nil) -> Self
    where Act: DistributedActor, Act.ID == ActorIdentity
    {
        .random(type: "\(Act.self)", node: node)
    }
    
    internal func with(_ nodeID: NodeIdentity) -> ActorIdentity {
        ActorIdentity(id: id, type: type, node: nodeID)
    }
    
    /// Does this id have the proper prefix for the provided type?
    public func hasType<Act>(for actorType: Act.Type) -> Bool
    where Act: DistributedActor, Act.ID == ActorIdentity
    {
        type == "\(Act.self)"
    }
    
    public var description: String {
        guard let type else { return id }
        return "\(id) \(type)"
    }
    
    public var debugDescription: String {
        "\(Self.self)(\(self.description))"
    }
}

extension ActorIdentity: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.id = value
        self.type = nil
        self.node = nil
    }
}

extension ActorIdentity: Hashable, Equatable {
    public func hash(into hasher: inout Hasher) {
        id.hash(into: &hasher)
    }
    
    public static func ==(lhs: ActorIdentity, rhs: ActorIdentity) -> Bool {
        lhs.id == rhs.id
    }
}

extension ActorIdentity: Decodable {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.node = try values.decodeIfPresent(NodeIdentity.self, forKey: .node)
        self.type = try values.decodeIfPresent(String.self, forKey: .type)
        
        // When decoding, if we see a NodeID that does not match the local WebSocketActorSystem,
        // tell the system to associate that node with the current Channel we are decoding.
        // This allows us to send messages to the remote actor later.
        if let system = decoder.userInfo[.actorSystemKey] as? WebSocketActorSystem,
           let nodeID = self.node,
           nodeID != system.nodeID {
            
            guard let channel = decoder.userInfo[.channelKey] as? NIOAsyncChannel<WebSocketFrame, WebSocketFrame> else {
                fatalError("Unable to associate NodeID \(nodeID) with Channel, because .channelKey was not set on the Decoder.userInfo")
            }
            
            system.associate(nodeID: nodeID, with: channel)
        }
    }
}
