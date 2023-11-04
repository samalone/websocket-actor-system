//
//  ActorChannelMap.swift
//
//
//  Created by Stuart A. Malone on 11/3/23.
//

import Foundation
import NIO

internal struct ActorChannelMap {
    var map = Dictionary<ActorIdentity, Channel>()
    
    subscript(actorID: ActorIdentity) -> Channel? {
        get {
            map[actorID]
        }
        set {
            map[actorID] = newValue
        }
    }
    
    mutating func forget(channel: Channel) {
        map = map.filter { $1 !== channel }
    }
    
    mutating func forget(id: ActorIdentity) {
        map.removeValue(forKey: id)
    }
}
