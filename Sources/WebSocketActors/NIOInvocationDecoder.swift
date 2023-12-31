/*
 See LICENSE folder for this sample’s licensing information.

 Abstract:
 Invocation decoder from a NIO byte buffer.
 */

import Distributed
import Foundation
import Logging
import NIO
import NIOWebSocket

public class NIOInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = any Codable

    let decoder: JSONDecoder
    let envelope: RemoteWebSocketCallEnvelope
    let logger: Logger
    var argumentsIterator: Array<Data>.Iterator

    init(system: WebSocketActorSystem, envelope: RemoteWebSocketCallEnvelope) {
        self.envelope = envelope
        logger = system.logger
        argumentsIterator = envelope.args.makeIterator()

        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = system
        self.decoder = decoder
    }

    public func decodeGenericSubstitutions() throws -> [Any.Type] {
        envelope.genericSubs.compactMap { name in
            _typeByName(name)
        }
    }

    public func decodeNextArgument<Argument: Codable>() throws -> Argument {
        let taggedLogger = logger.withOp()

        guard let data = argumentsIterator.next() else {
            taggedLogger.trace("none left")
            throw WebSocketActorSystemError.notEnoughArgumentsInEnvelope(expected: Argument.self)
        }

        do {
            let value = try decoder.decode(Argument.self, from: data)
            taggedLogger.trace("decoded: \(value)")
            return value
        }
        catch {
            taggedLogger.trace("error: \(error)")
            throw error
        }
    }

    public func decodeErrorType() throws -> Any.Type? {
        nil // not encoded, ok
    }

    public func decodeReturnType() throws -> Any.Type? {
        nil // not encoded, ok
    }
}
