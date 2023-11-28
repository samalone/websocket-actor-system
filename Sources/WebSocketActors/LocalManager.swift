//
//  File.swift
//
//
//  Created by Stuart A. Malone on 11/28/23.
//

import Foundation

actor LocalManager: Manager {
    func localPort() throws -> Int {
        0
    }
    
    func remoteNode(for nodeID: ActorIdentity) throws -> RemoteNode {
        throw WebSocketActorSystemError.noRemoteNode
    }
    
    func cancel() {}
    
    func opened(remote: RemoteNode) {}
    
    func closing(remote: RemoteNode) {}
}
