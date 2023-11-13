//
//  File.swift
//  
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation
import NIO
import NIOWebSocket

/// The ``RemoteNodeRegistry`` maintains a three-way association between a
/// ``NodeIdentity``, a ``NodeAddress``, and a ``Channel``. This allows us to
/// find the channel we need to communicate with an actor, and reconnect to a server
/// if the original connection is broken.
///
/// > Important: This structure is intentionally not thread-safe because it is used
/// from synchronous code in the ``WebSocketActorSystem``. That code uses
/// a manual lock to ensure safe access to this structure. All uses of this structure
/// must be protected by that lock.
struct RemoteNodeRegistry {
    var byNodeID: Dictionary<NodeIdentity, RemoteNodeConnection> = [:]
    
    mutating func register(id: NodeIdentity, address: NodeAddress) {
        if let rnc = byNodeID[id] {
            // We don't allow re-registration of a node at a different address,
            // so just confirm that the address has not changed.
            assert(rnc.address == address)
        }
        else {
            byNodeID[id] = RemoteNodeConnection(id: id, address: address)
        }
    }
    
    mutating func register(id: NodeIdentity, channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        if let rnc = byNodeID[id] {
            rnc.channel = channel
        }
        else {
            byNodeID[id] = RemoteNodeConnection(id: id, channel: channel)
        }
    }
    
    mutating func channelClosed(channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        for rnc in byNodeID.values {
            if rnc.channel?.channel === channel.channel {
                rnc.channel = nil
            }
        }
    }
    
    func channel(for nodeID: NodeIdentity) -> NIOAsyncChannel<WebSocketFrame, WebSocketFrame>? {
        guard let rnc = byNodeID[nodeID] else { return nil }
        return rnc.channel
    }
    
    func address(for nodeID: NodeIdentity) -> NodeAddress? {
        guard let rnc = byNodeID[nodeID] else { return nil }
        return rnc.address
    }
    
    func nodeID(for channel: WebSocketAgentChannel) -> NodeIdentity? {
        for rnc in byNodeID.values {
            if rnc.channel?.channel === channel.channel {
                return rnc.id
            }
        }
        return nil
    }
    
}
