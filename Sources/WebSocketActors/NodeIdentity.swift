//
//  NodeIdentity.swift
//  
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation

/// A `NodeID` identifies a particular client or server in the WebSocketActorSystem.
/// It is intended to be unique and constant for the lifetime of the actors in that node,
/// even if connections to that node are lost and restarted.
///
/// It can be any string, so the `NodeID` of the server can simply be "server",
/// but if there can be multiple clients, you should use ``random()`` to generate
/// unique IDs for each client.
public struct NodeIdentity: Hashable, Sendable, Equatable {
    public let id: String
    
    public init(id: String) {
        self.id = id
    }
    
    public static func random() -> Self {
        .init(id: "\(UUID().uuidString)")
    }
}

extension NodeIdentity: Codable {
    public func encode(to encoder: Encoder) throws {
        try id.encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        id = try String(from: decoder)
    }
}

extension NodeIdentity: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.id = value
    }
}

extension NodeIdentity: CustomStringConvertible {
    public var description: String {
        id.description
    }
}

extension CodingUserInfoKey {
    static let remoteNodeKey = CodingUserInfoKey(rawValue: "remoteNode")!
}
