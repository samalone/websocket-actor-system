//
//  NodeAddress.swift
//  
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation

public struct NodeAddress: Hashable, Sendable, Codable, Equatable {
    /// Either "ws" for an unencrypted connection, or "wss" for an ecnrypted connection.
    public let scheme: String
    
    /// The IP address or hostname of the remote node.
    public let host: String
    
    /// The port number of the node. For a server, this can be 0 to assign a port number automatically.
    public let port: Int
}
