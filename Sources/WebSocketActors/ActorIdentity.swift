/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Used as `ActorID` by all distributed actors in this sample app. It is used to uniquely identify any given actor within its actor system.
*/

import Foundation

public struct ActorIdentity: Hashable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    
    public init(id: String) {
        self.id = id
    }
    
    public init(protocol: String, host: String, port: Int, id: String) {
        self.id = id
    }
    
    public static var random: Self {
        .init(id: "\(UUID().uuidString)")
    }
    
    public var description: String {
        id
    }
    
    public var debugDescription: String {
        "\(Self.self)(\(self.description))"
    }
}
