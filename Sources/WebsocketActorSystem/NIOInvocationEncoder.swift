/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Invocation decoder from a NIO byte buffer.
*/

import Distributed
import Foundation
import NIO
import NIOConcurrencyHelpers
#if os(iOS) || os(macOS)
import NIOTransportServices
#endif
import NIOCore
import NIOHTTP1
import NIOWebSocket
import NIOFoundationCompat

@available(iOS 16.0, *)
public class NIOInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = any Codable

    let decoder: JSONDecoder
    let envelope: RemoteWebSocketCallEnvelope
    var argumentsIterator: Array<Data>.Iterator

    public init(system: WebSocketActorSystem, envelope: RemoteWebSocketCallEnvelope) {
        self.envelope = envelope
        self.argumentsIterator = envelope.args.makeIterator()

        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = system
        self.decoder = decoder
    }

    public func decodeGenericSubstitutions() throws -> [Any.Type] {
        return envelope.genericSubs.compactMap { name in
            return _typeByName(name)
        }
    }

    public func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard let data = argumentsIterator.next() else {
            log("decode-argument", "none left")
            throw WebSocketActorSystemError.notEnoughArgumentsInEnvelope(expected: Argument.self)
        }

        do {
            let value = try decoder.decode(Argument.self, from: data)
            log("decode-argument", "decoded: \(value)")
            return value
        } catch {
            log("decode-argument", "error: \(error)")
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
