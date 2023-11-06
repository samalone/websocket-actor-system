//
//  File.swift
//  
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation
import NIO

public struct RemoteNodeRegistry {
    var byNodeID: Dictionary<NodeID, RemoteNodeConnection> = [:]
    
    public mutating func register(id: NodeID, address: NodeAddress) {
        assert(!id.isUnknown)
        if let rnc = byNodeID[id] {
            // We don't allow re-registration of a node at a different address,
            // so just confirm that the address has not changed.
            assert(rnc.address == address)
        }
        else {
            byNodeID[id] = RemoteNodeConnection(id: id, address: address)
        }
    }
    
    public mutating func register(id: NodeID, channel: Channel) {
        assert(!id.isUnknown)
        if let rnc = byNodeID[id] {
            rnc.channel = channel
        }
        else {
            byNodeID[id] = RemoteNodeConnection(id: id, channel: channel)
        }
    }
    
    public mutating func channelClosed(channel: Channel) {
        for rnc in byNodeID.values {
            if rnc.channel === channel {
                rnc.channel = nil
            }
        }
    }
    
    public func channel(for nodeID: NodeID) -> Channel? {
        assert(!nodeID.isUnknown)
        guard let rnc = byNodeID[nodeID] else { return nil }
        return rnc.channel
    }
    
    public func address(for nodeID: NodeID) -> NodeAddress? {
        assert(!nodeID.isUnknown)
        guard let rnc = byNodeID[nodeID] else { return nil }
        return rnc.address
    }
    
    public func nodeID(for channel: Channel) -> NodeID? {
        for rnc in byNodeID.values {
            if rnc.channel === channel {
                return rnc.id
            }
        }
        return nil
    }
    
}
