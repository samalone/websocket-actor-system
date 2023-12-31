//
//  NodeIdentity.swift
//
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation
import NIOHTTP1

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
        id = value
    }
}

extension NodeIdentity: CustomStringConvertible {
    public var description: String {
        id.description
    }
}

// In order to pass the NodeIdentity between the client and the server,
// we put it in the request and response headers. This extension makes
// that header easy to access.
extension HTTPHeaders {
    static let nodeIdKey = "ActorSystemNodeID"

    var nodeID: NodeIdentity? {
        get {
            guard let id = self[HTTPHeaders.nodeIdKey].first else { return nil }
            return NodeIdentity(id: id)
        }
        set {
            if let newValue {
                replaceOrAdd(name: HTTPHeaders.nodeIdKey, value: newValue.id)
            }
            else {
                remove(name: HTTPHeaders.nodeIdKey)
            }
        }
    }
}
