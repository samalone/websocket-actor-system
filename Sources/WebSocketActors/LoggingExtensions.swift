/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Wrappers around Logging package to add metadata automatically.
*/

import Foundation
import Logging

/// Internal utilities for adding metadata to loggers.
extension Logger {
    func with(_ actorID: ActorIdentity) -> Logger {
        var logger = self
        logger[metadataKey: "actorID"] = .stringConvertible(actorID)
        return logger
    }
    
    func with(_ system: WebSocketActorSystem) -> Logger {
        var logger = self
        logger[metadataKey: "system"] = .string("\(system.mode)")
        return logger
    }
    
    func with(_ mode: WebSocketActorSystemMode) -> Logger {
        var logger = self
        logger[metadataKey: "system"] = .string("\(mode)")
        return logger
    }
    
    func with(_ callID: CallID) -> Logger {
        var logger = self
        logger[metadataKey: "callID"] = .stringConvertible(callID)
        return logger
    }
    
    func with(op: String) -> Logger {
        var logger = self
        logger[metadataKey: "op"] = .string(op)
        return logger
    }
    
    func withOp(_ op: String = #function) -> Logger {
        var logger = self
        logger[metadataKey: "op"] = .string(op)
        return logger
    }
}
