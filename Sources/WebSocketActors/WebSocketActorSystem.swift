/*
See LICENSE folder for this sample’s licensing information.

Abstract:
WebSocket based client/server style actor system implementation.
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
public enum WebSocketWireEnvelope: Sendable, Codable {
    case call(RemoteWebSocketCallEnvelope)
    case reply(WebSocketReplyEnvelope)
    case connectionClose
}

@available(iOS 16.0, *)
public struct RemoteWebSocketCallEnvelope: Sendable, Codable {
    let callID: WebSocketActorSystem.CallID
    let recipient: ActorIdentity
    let invocationTarget: String
    let genericSubs: [String]
    let args: [Data]
}

public enum WebSocketActorSystemMode {
    case clientFor(host: String, port: Int)
    case serverOnly(host: String, port: Int)

    var isClient: Bool {
        switch self {
        case .clientFor:
            return true
        default:
            return false
        }
    }

    var isServer: Bool {
        switch self {
        case .serverOnly:
            return true
        default:
            return false
        }
    }
}

@available(iOS 16.0, *)
public final class WebSocketActorSystem: DistributedActorSystem,
    @unchecked /* state protected with locks */ Sendable {

    public typealias ActorID = ActorIdentity
    public typealias ResultHandler = WebSocketActorSystemResultHandler
    public typealias InvocationEncoder = NIOInvocationEncoder
    public typealias InvocationDecoder = NIOInvocationDecoder
    public typealias SerializationRequirement = any Codable

    private let lock = NSLock()
    private var managedActors: [ActorID: any DistributedActor] = [:]

    // === Handle replies
    public typealias CallID = UUID
    private let replyLock = NSLock()
    private var inFlightCalls: [CallID: CheckedContinuation<Data, Error>] = [:]

    // ==== Channels
    let group: EventLoopGroup
    private var serverChannel: Channel?
    private var clientChannel: Channel?

    // === On-Demand resolve handler

    typealias OnDemandResolveHandler = (ActorID) -> (any DistributedActor)?
    private var resolveOnDemandHandler: OnDemandResolveHandler? = nil

    // === Configuration
    public let mode: WebSocketActorSystemMode
    public var host: String {
        switch mode {
        case .clientFor(let host, _):
            return host
        case .serverOnly(let host, _):
            return host
        }
    }
    public var port: Int {
        switch mode {
        case .clientFor(_, let port):
            return port
        case .serverOnly(_, let port):
            return port
        }
    }

    public init(mode: WebSocketActorSystemMode) throws {
        self.mode = mode

        // Note: this sample system implementation assumes that clients are iOS devices,
        // and as such will be always using NetworkFramework (via NIOTransportServices),
        // for the client-side. This does not have to always be the case, but generalizing/making
        // it configurable is left as an exercise for interested developers.
        self.group = { () -> EventLoopGroup in
            switch mode {
            case .clientFor:
                return NIOTSEventLoopGroup()
            case .serverOnly:
                return MultiThreadedEventLoopGroup(numberOfThreads: 1)
            }
        }()

        // Start networking
        switch mode {
        case .clientFor(let host, let port):
            self.clientChannel = try startClient(host: host, port: port)
        case .serverOnly(let host, let port):
            self.serverChannel = try startServer(host: host, port: port)
        }

        log("websocket", "\(Self.self) initialized in mode: \(mode)")
    }

    public func syncShutdownGracefully() {
        try! group.syncShutdownGracefully()
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID where Act: DistributedActor, Act.ID == ActorID {
        // Implements `id` hinting via a task-local.
        // IDs must never be reused, so if this were to happen this causes a crash here.
        if let hintedID = Self.actorIDHint {
            if !Self.alreadyLocked {
                lock.lock()
            }
            defer {
                if !Self.alreadyLocked {
                    lock.unlock()
                }
            }

            if let existingActor = self.managedActors[hintedID] {
                preconditionFailure("""
                                    Illegal re-use of ActorID (\(hintedID))!
                                    Already used by: \(existingActor), yet attempted to assign to \(actorType)!
                                    """)
            }

            return hintedID
        }

        let uuid = UUID().uuidString
        let typeFullName = "\(Act.self)"
        guard typeFullName.split(separator: ".").last != nil else {
            return .init(id: uuid)
        }

        return .init(id: "\(uuid)")
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        log("actorReady[\(self.mode)]", "resign ID: \(actor.id)")

        if !Self.alreadyLocked {
            lock.lock()
        }
        defer {
            if !Self.alreadyLocked {
                self.lock.unlock()
            }
        }

        self.managedActors[actor.id] = actor
    }

    public func resignID(_ id: ActorID) {
        log("resignID[\(self.mode)]", "resign ID: \(id)")
        lock.lock()
        defer {
            lock.unlock()
        }

        self.managedActors.removeValue(forKey: id)
    }

    // Trick to allow resolve() re-entrancy while still holding the `lock`
    @TaskLocal private static var alreadyLocked: Bool = false
    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor, Act.ID == ActorID {
        if !Self.alreadyLocked {
            lock.lock()
        }
        defer {
            if !Self.alreadyLocked {
                lock.unlock()
            }
        }

        guard let found = managedActors[id] else {
            log("resolve[\(self.mode)]", "Not found locally, ID: \(id)")
            if let resolveOnDemand = self.resolveOnDemandHandler {
                log("resolve\(self.mode)", "Resolve on demand, ID: \(id)")

                let resolvedOnDemandActor = Self.$alreadyLocked.withValue(true) {
                    resolveOnDemand(id)
                }
                if let resolvedOnDemandActor = resolvedOnDemandActor {
                    log("resolve", "Attempt to resolve on-demand. ID: \(id) as \(resolvedOnDemandActor)")
                    if let wellTyped = resolvedOnDemandActor as? Act {
                        log("resolve", "Resolved on-demand, as: \(Act.self)")
                        return wellTyped
                    } else {
                        log("resolve", "Resolved on demand, but wrong type: \(type(of: resolvedOnDemandActor))")
                        throw WebSocketActorSystemError.resolveFailed(id: id)
                    }
                } else {
                    log("resolve", "Resolve on demand: \(id)")
                }
            }

            log("resolve", "Resolved as remote. ID: \(id)")
            return nil // definitely remote, we don't know about this ActorID
        }

        guard let wellTyped = found as? Act else {
            throw WebSocketActorSystemError.resolveFailedToMatchActorType(found: type(of: found), expected: Act.self)
        }

        print("RESOLVED LOCAL: \(wellTyped)")
        return wellTyped
    }

    func resolveAny(id: ActorID, resolveReceptionist: Bool = false) -> (any DistributedActor)? {
        lock.lock()
        defer { lock.unlock() }

        guard id.protocol == "ws" else {
            return nil
        }
        guard id.host == self.host else {
            return nil
        }
        guard id.port == self.port else {
            return nil
        }

        guard let resolved = managedActors[id] else {
            log("resolve", "here")
            if let resolveOnDemand = self.resolveOnDemandHandler {
                log("resolve", "got handler")
                return Self.$alreadyLocked.withValue(true) {
                    if let resolvedOnDemandActor = resolveOnDemand(id) {
                        log("resolve", "Resolved ON DEMAND: \(id) as \(resolvedOnDemandActor)")
                        return resolvedOnDemandActor
                    } else {
                        log("resolve", "not resolved")
                        return nil
                    }
                }
            } else {
                log("resolve", "here")
            }

            log("resolve", "RESOLVED REMOTE: \(id)")
            return nil // definitely remote, we don't know about this ActorID
        }

        log("resolve", "here: \(resolved)")
        return resolved
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        .init()
    }
}

extension WebSocketActorSystem {

    /// We make up an ID for the remote bot; We know they are resolved and created on-demand
    public func opponentBotID<Act>(for player: Act) -> ActorIdentity
    where Act: Identifiable, Act.ID == ActorIdentity {
        .init(protocol: "ws", host: host, port: port, id: "bot-\(player.id)")
    }
    
    public func isBotID(_ id: ActorID) -> Bool {
        return true
    }

    public func registerOnDemandResolveHandler(resolveOnDemand: @escaping (ActorID) -> (any DistributedActor)?) {
        lock.lock()
        defer {
            self.lock.unlock()
        }

        self.resolveOnDemandHandler = resolveOnDemand
    }

    @TaskLocal
    static var actorIDHint: ActorID?

    public func makeActorWithID<Act>(_ id: ActorID, _ factory: () -> Act) -> Act
        where Act: DistributedActor, Act.ActorSystem == WebSocketActorSystem {
        Self.$actorIDHint.withValue(id) {
            factory()
        }
    }
}

@available(iOS 16.0, *)
extension WebSocketActorSystem {
    func decodeAndDeliver(data: inout ByteBuffer, from address: SocketAddress?,
                          on channel: Channel) {
        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = self

        do {
            let wireEnvelope = try data.readJSONDecodable(WebSocketWireEnvelope.self, length: data.readableBytes)

            switch wireEnvelope {
            case .call(let remoteCallEnvelope):
                // log("receive-decode-deliver", "Decode remoteCall...")
                self.receiveInboundCall(envelope: remoteCallEnvelope, on: channel)
            case .reply(let replyEnvelope):
                self.receiveInboundReply(envelope: replyEnvelope, on: channel)
            case .none, .connectionClose:
                log("receive-decode-deliver", "[error] Failed decoding: \(data); decoded empty")
            }
        } catch {
            log("receive-decode-deliver", "[error] Failed decoding: \(data), error: \(error)")
        }
        log("decode-deliver", "here...")
    }

    func receiveInboundCall(envelope: RemoteWebSocketCallEnvelope, on channel: Channel) {
        log("receive-inbound", "Envelope: \(envelope)")
        Task {
            log("receive-inbound", "Resolve any: \(envelope.recipient)")
            guard let anyRecipient = resolveAny(id: envelope.recipient, resolveReceptionist: true) else {
                log("deadLetter", "[warn] \(#function) failed to resolve \(envelope.recipient)")
                return
            }
            log("receive-inbound", "Recipient: \(anyRecipient)")
            let target = RemoteCallTarget(envelope.invocationTarget)
            log("receive-inbound", "Target: \(target)")
            log("receive-inbound", "Target.identifier: \(target.identifier)")
            let handler = ResultHandler(actorSystem: self, callID: envelope.callID, system: self, channel: channel)
            log("receive-inbound", "Handler: \(anyRecipient)")

            do {
                var decoder = Self.InvocationDecoder(system: self, envelope: envelope)
                func doExecuteDistributedTarget<Act: DistributedActor>(recipient: Act) async throws {
                    log("receive-inbound", "executeDistributedTarget")
                    try await executeDistributedTarget(
                        on: recipient,
                        target: target,
                        invocationDecoder: &decoder,
                        handler: handler)
                }

                // As implicit opening of existential becomes part of the language,
                // this underscored feature is no longer necessary. Please refer to
                // SE-352 Implicitly Opened Existentials:
                // https://github.com/apple/swift-evolution/blob/main/proposals/0352-implicit-open-existentials.md
                try await _openExistential(anyRecipient, do: doExecuteDistributedTarget)
            } catch {
                log("inbound", "[error] failed to executeDistributedTarget [\(target)] on [\(anyRecipient)], error: \(error)")
                try! await handler.onThrow(error: error)
            }
        }
    }

    func receiveInboundReply(envelope: WebSocketReplyEnvelope, on channel: Channel) {
        log("receive-reply", "Reply envelope: \(envelope)")
        self.replyLock.lock()
        log("receive-reply", "Reply envelope delivering...: \(envelope)")

        guard let callContinuation = self.inFlightCalls.removeValue(forKey: envelope.callID) else {
            log("receive-reply", "Missing continuation for call \(envelope.callID); Envelope: \(envelope)")
            self.replyLock.unlock()
            return
        }

        self.replyLock.unlock()
        log("receive-reply", "Reply envelope delivering... RESUME: \(envelope)")
        callContinuation.resume(returning: envelope.value)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: RemoteCall implementations

@available(iOS 16.0, *)
extension WebSocketActorSystem {
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        log("remote-call", "Call to: \(actor.id), target: \(target), target.identifier: \(target.identifier)")

        let channel = self.selectChannel(for: actor.id)
        log("remote-call", "channel: \(channel)")

        log("remote-call-void", "Prepare [\(target)] call...")
        let replyData = try await withCallIDContinuation(recipient: actor) { callID in
            let callEnvelope = RemoteWebSocketCallEnvelope(
                callID: callID,
                recipient: actor.id,
                invocationTarget: target.identifier,
                genericSubs: invocation.genericSubs,
                args: invocation.argumentData
            )
            let wireEnvelope = WebSocketWireEnvelope.call(callEnvelope)

            log("remote-call", "Write envelope: \(wireEnvelope)")
            channel.writeAndFlush(wireEnvelope, promise: nil)
        }

        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.actorSystemKey] = self

            return try decoder.decode(Res.self, from: replyData)
        } catch {
            throw WebSocketActorSystemError.decodingError(error: error)
        }
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        log("remote-call-void", "Call to: \(actor.id), target: \(target), target.identifier: \(target.identifier)")
        
        let channel = selectChannel(for: actor.id)
        log("remote-call-void", "channel: \(channel)")
        
        log("remote-call-void", "Prepare [\(target)] call...")
        _ = try await withCallIDContinuation(recipient: actor) { callID in
            let callEnvelope = RemoteWebSocketCallEnvelope(
                callID: callID,
                recipient: actor.id,
                invocationTarget: target.identifier,
                genericSubs: invocation.genericSubs,
                args: invocation.argumentData
            )
            let wireEnvelope = WebSocketWireEnvelope.call(callEnvelope)

            log("remote-call-void", "Write envelope: \(wireEnvelope)")
            channel.writeAndFlush(wireEnvelope, promise: nil)
        }
        
        log("remote-call-void", "COMPLETED CALL: \(target)")
    }

    func selectChannel(for actorID: ActorID) -> Channel {
        guard actorID.protocol == "ws" else {
            fatalError("Unexpected protocol in WS actor system assigned actor identity! Was: \(actorID)")
        }
        guard let host = actorID.host else {
            fatalError("No port in WS actor system assigned actor identity! Was: \(actorID)")
        }
        guard let port = actorID.port else {
            fatalError("No port in WS actor system assigned actor identity! Was: \(actorID)")
        }

        // We implemented a pretty naive actor system; that only handles ONE connection to a backend.
        // In general, a websocket transport could open new connections as it notices identities to hosts.
        if mode.isClient && host == self.host && port == self.port {
            self.lock.lock()
            defer { self.lock.unlock() }
            return clientChannel!
        } else if mode.isServer && host != self.host && port == self.port {
            fatalError("Server selecting specific connections to send messages to is not implemented;" +
                       "This would allow the server to *initiate* request/reply exchanges, rather than only perform replies.")
        } else {
            fatalError("Not supported: \(self.mode) & \(actorID)")
        }
    }

    private func withCallIDContinuation<Act>(recipient: Act, body: (CallID) -> Void) async throws -> Data
        where Act: DistributedActor {
        let data = try await withCheckedThrowingContinuation { continuation in
            let callID = UUID()
            
            self.replyLock.lock()
            self.inFlightCalls[callID] = continuation
            self.replyLock.unlock()
            
            log("remote-call-withCC", "Stored callID:[\(callID)], waiting for reply...")
            body(callID)
        }
            
        log("remote-call-withCC", "Resumed call, data: \(String(data: data, encoding: .utf8)!)")
        return data
    }
}

@available(iOS 16.0, *)
public struct WebSocketActorSystemResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = any Codable

    let actorSystem: WebSocketActorSystem
    let callID: WebSocketActorSystem.CallID
    let system: WebSocketActorSystem
    let channel: Channel

    public func onReturn<Success: Codable>(value: Success) async throws {
        log("handler-onReturn", "Write to channel: \(channel)")
        let encoder = JSONEncoder()
        encoder.userInfo[.actorSystemKey] = actorSystem
        let returnValue = try encoder.encode(value)
        let envelope = WebSocketReplyEnvelope(callID: self.callID, sender: nil, value: returnValue)
        channel.write(WebSocketWireEnvelope.reply(envelope), promise: nil)
    }

    public func onReturnVoid() async throws {
        log("handler-onReturnVoid", "Write to channel: \(channel)")
        let envelope = WebSocketReplyEnvelope(callID: self.callID, sender: nil, value: "".data(using: .utf8)!)
        channel.write(WebSocketWireEnvelope.reply(envelope), promise: nil)
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        log("handler", "onThrow: \(error)")
        // Naive best-effort carrying the error name back to the caller;
        // Always be careful when exposing error information -- especially do not ship back the entire description
        // or error of a thrown value as it may contain information which should never leave the node.
        let envelope = WebSocketReplyEnvelope(callID: self.callID, sender: nil, value: "".data(using: .utf8)!)
        channel.write(WebSocketWireEnvelope.reply(envelope), promise: nil)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Reply handling

@available(iOS 16.0, *)
extension WebSocketActorSystem {
    func sendReply(_ envelope: WebSocketReplyEnvelope, on channel: Channel) throws {
        lock.lock()
        defer {
            self.lock.unlock()
        }

        // let encoder = JSONEncoder()
        // let data = try encoder.encode(envelope)

        debug("reply", "Sending reply to [\(envelope.callID)]: envelope: \(envelope), on channel: \(channel)")
        _ = channel.writeAndFlush(envelope)
    }
}

public enum WebSocketActorSystemError: Error, DistributedActorSystemError {
    case resolveFailedToMatchActorType(found: Any.Type, expected: Any.Type)
    case noPeers
    case notEnoughArgumentsInEnvelope(expected: Any.Type)
    case failedDecodingResponse(data: Data, error: Error)
    case decodingError(error: Error)
    case resolveFailed(id: WebSocketActorSystem.ActorID)
}
