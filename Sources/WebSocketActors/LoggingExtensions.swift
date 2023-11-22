/*
 See LICENSE folder for this sample’s licensing information.

 Abstract:
 Wrappers around Logging package to add metadata automatically.
 */

import Distributed
import Foundation
import Logging

/// Internal utilities for adding metadata to loggers. These functions ensure
/// that we use consistent metadata keys when logging.
///
/// Because we log so much metadata, applications may want to select
/// a [logging backend](https://github.com/apple/swift-log#selecting-a-logging-backend-implementation-applications-only)
/// that provides more structure than the default `StreamLogHandler`.
extension Logger {
    func with(_ actorID: ActorIdentity) -> Logger {
        var logger = self
        logger[metadataKey: "actorID"] = .stringConvertible(actorID)
        return logger
    }
    
    func with(_ callID: CallID) -> Logger {
        var logger = self
        logger[metadataKey: "callID"] = .stringConvertible(callID)
        return logger
    }
    
    func with(_ channel: WebSocketAgentChannel) -> Logger {
        var logger = self
        logger[metadataKey: "channel"] = .string(channel.remoteDescription)
        return logger
    }
    
    func with(target: String) -> Logger {
        with(RemoteCallTarget(target))
    }
    
    func with(_ target: RemoteCallTarget) -> Logger {
        var logger = self
        logger[metadataKey: "target"] = .stringConvertible(target)
        return logger
    }
    
    func with(sender: ActorIdentity?) -> Logger {
        guard let sender else { return self }
        var logger = self
        logger[metadataKey: "sender"] = .stringConvertible(sender)
        return logger
    }
    
    func withOp(_ op: String = #function) -> Logger {
        var logger = self
        logger[metadataKey: "op"] = .string(op)
        return logger
    }
    
    func with(_ envelope: RemoteWebSocketCallEnvelope) -> Logger {
        // Don't log envelope.args unless explicitly requested,
        // because they may contain private data.
        with(target: envelope.invocationTarget)
            .with(envelope.recipient)
            .with(envelope.callID)
    }
    
    func with(_ args: [Data]) -> Logger {
        var logger = self
        logger[metadataKey: "args"] = .string("(" + args.map { String(data: $0, encoding: .utf8) ?? "???" }.joined(separator: ", ") + ")")
        return logger
    }
}
