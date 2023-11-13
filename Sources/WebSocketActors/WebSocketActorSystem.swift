/*
See LICENSE folder for this sample’s licensing information.

Abstract:
WebSocket based client/server style actor system implementation.
*/


import Distributed
import Foundation
import NIO
import NIOWebSocket
import Logging

#if canImport(Network)
    import NIOTransportServices
#else
    import NIOPosix
#endif

internal enum WebSocketWireEnvelope: Sendable, Codable {
    case call(RemoteWebSocketCallEnvelope)
    case reply(WebSocketReplyEnvelope)
    case connectionClose
}

internal struct WebSocketReplyEnvelope: Sendable, Codable {
    let callID: WebSocketActorSystem.CallID
    let sender: WebSocketActorSystem.ActorID?
    let value: Data
}

internal struct RemoteWebSocketCallEnvelope: Sendable, Codable {
    let callID: WebSocketActorSystem.CallID
    let recipient: ActorIdentity
    let invocationTarget: String
    let genericSubs: [String]
    let args: [Data]
}

public enum WebSocketActorSystemMode {
    case clientFor(server: NodeAddress)
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

public final class WebSocketActorSystem: DistributedActorSystem,
    @unchecked /* state protected with locks */ Sendable {

    public typealias ActorID = ActorIdentity
    public typealias ResultHandler = WebSocketActorSystemResultHandler
    public typealias InvocationEncoder = NIOInvocationEncoder
    public typealias InvocationDecoder = NIOInvocationDecoder
    public typealias SerializationRequirement = any Codable
    
    public static let defaultLogger = Logger(label: "WebSocketActors")

    private let lock = NSLock()
    
    /// A mapping from ActorID to actor for the local actors only.
    /// Remote actors are not part of this dictionary.
    private var managedActors: [ActorID: any DistributedActor] = [:]
    public let nodeID: NodeIdentity
    public let logger: Logger

    // === Handle replies
    public typealias CallID = UUID
    private let replyLock = NSLock()
    private var inFlightCalls: [CallID: CheckedContinuation<Data, Error>] = [:]
    
    private var pendingReplies = PendingReplies()

    // ==== Channels
    let group: EventLoopGroup
    private var serverChannel: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never>?
    private var channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>?
    private var nodeRegistry = RemoteNodeRegistry()

    // === On-Demand resolve handler

    typealias OnDemandResolveHandler = (ActorID) -> (any DistributedActor)?
    private var resolveOnDemandHandler: OnDemandResolveHandler? = nil

    // === Configuration
    public let mode: WebSocketActorSystemMode
    
    /// The local port number, or -1 if there is no channel open
    public var localPort: Int {
        switch mode {
        case .serverOnly:
            return serverChannel?.channel.localAddress?.port ?? -1
        case .clientFor:
            return  channel?.channel.localAddress?.port ?? -1
        }
       
    }

    public init(mode: WebSocketActorSystemMode, id: NodeIdentity = .random(), logger: Logger = defaultLogger) async throws {
        self.nodeID = id
        self.mode = mode
        self.logger = logger.with(mode)
        
        // Start networking
        switch mode {
        case .clientFor(let serverAddress):
#if canImport(Network)
            self.group = NIOTSEventLoopGroup()
#else
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
#endif
            self.channel = try await startClient(host: serverAddress.host, port: serverAddress.port)
        case .serverOnly(let host, let port):
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.serverChannel = try await startServer(host: host, port: port)
            logger.info("server listening on port \(localPort)")
        }
        
        logger.info("\(Self.self) initialized in mode: \(mode)")
    }
    
    func runServer() async throws {
        guard let channel = serverChannel else {
            logger.critical("Attempt to run server loop on client!")
            return
        }
        
        // We are handling each incoming connection in a separate child task. It is important
        // to use a discarding task group here which automatically discards finished child tasks.
        // A normal task group retains all child tasks and their outputs in memory until they are
        // consumed by iterating the group or by exiting the group. Since, we are never consuming
        // the results of the group we need the group to automatically discard them; otherwise, this
        // would result in a memory leak over time.
        if #available(macOS 14.0, *) {
            try await withThrowingDiscardingTaskGroup { group in
                for try await upgradeResult in channel.inbound {
                    group.addTask {
                        await self.handleUpgradeResult(upgradeResult)
                    }
                }
            }
        } else {
            // Fallback on earlier versions
            try await withThrowingTaskGroup(of: Void.self) { group in
                for try await upgradeResult in channel.inbound {
                    group.addTask {
                        await self.handleUpgradeResult(upgradeResult)
                    }
                }
            }
        }
    }
    
    
    
    // Listen for replies and incoming calls from the server.
    func runClient() {
        guard let channel = channel else {
            logger.critical("Attempt to run client loop on server!")
            return
        }
        
        Task {
            try await dispatchIncomingFrames(channel: channel)
        }
    }
    
    func dispatchIncomingFrames(channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async throws {
        for try await frame in channel.inbound {
            switch frame.opcode {
            case .connectionClose:
                // Close the connection.
                //
                // We might also want to inform the actor system that this connection
                // went away, so it can terminate any tasks or actors working to
                // inform the remote receptionist on the now-gone system about our
                // actors.
                
                // This is an unsolicited close. We're going to send a response frame and
                // then, when we've sent it, close up shop. We should send back the close code the remote
                // peer sent us, unless they didn't send one at all.
                print("Received close")
                var data = frame.unmaskedData
                let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
                let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
                try await channel.outbound.write(closeFrame)
                
            case .text:
                var data = frame.unmaskedData
                let text = data.getString(at: 0, length: data.readableBytes) ?? ""
                self.logger.withOp().trace("Received: \(text), from: \(String(describing: channel.channel.remoteAddress))")
                
                await self.decodeAndDeliver(data: &data, from: channel.channel.remoteAddress,
                                            on: channel)
            
            case .ping:
                print("Received ping")
                var frameData = frame.data
                let maskingKey = frame.maskKey
                
                if let maskingKey = maskingKey {
                    frameData.webSocketUnmask(maskingKey)
                }
                
                let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
                try await channel.outbound.write(responseFrame)
                
            case .binary, .continuation, .pong:
                // We ignore these frames.
                break
            default:
                // Unknown frames are errors.
                await self.closeOnError(channel: channel)
            }
        }
    }
    
    func associate(nodeID: NodeIdentity, with channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        nodeRegistry.register(id: nodeID, channel: channel)
    }
    
    public func shutdownGracefully() async throws {
        try await group.shutdownGracefully()
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

    /// Register the actor as a local actor.
    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
//        log("actorReady[\(self.mode)]", "resign ID: \(actor.id)")
        logger.info("actorReady", metadata: ["actorID": .stringConvertible(actor.id)])

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

    /// Unregister the actors as a local actor.
    public func resignID(_ id: ActorID) {
//        log("resignID[\(self.mode)]", "resign ID: \(id)")
        logger.info("resignID", metadata: ["actorID": .stringConvertible(id)])
        lock.lock()
        defer {
            lock.unlock()
        }

        self.managedActors.removeValue(forKey: id)
    }

    // Trick to allow resolve() re-entrancy while still holding the `lock`
    @TaskLocal private static var alreadyLocked: Bool = false
    
    /// Attempt to resolve the `id` to a local actor.
    /// Returns `nil` if the id cannot be resolved locally, which implies the id
    /// represents a remote actor.
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
        
        let taggedLogger = logger.with(id).withOp()
        
        guard let found = managedActors[id] else {
            taggedLogger.debug("not found locally")
            if let resolveOnDemand = self.resolveOnDemandHandler {
                taggedLogger.debug("resolve on demand")
                
                let resolvedOnDemandActor = Self.$alreadyLocked.withValue(true) {
                    resolveOnDemand(id)
                }
                if let resolvedOnDemandActor = resolvedOnDemandActor {
                    taggedLogger.debug("attempt to resolve on-demand as \(resolvedOnDemandActor)")
                    if let wellTyped = resolvedOnDemandActor as? Act {
                        taggedLogger.debug("resolved on-demand as \(Act.self)")
                        return wellTyped
                    } else {
                        taggedLogger.error("resolved on demand, but wrong type: \(type(of: resolvedOnDemandActor))")
                        throw WebSocketActorSystemError.resolveFailed(id: id)
                    }
                } else {
                    taggedLogger.notice("resolve on demand")
                }
            }
            
            taggedLogger.info("resolved as remote")
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
        
        let taggedLogger = logger.with(id).withOp()

        guard let resolved = managedActors[id] else {
            taggedLogger.debug("here")
            if let resolveOnDemand = self.resolveOnDemandHandler {
                taggedLogger.debug("got handler")
                return Self.$alreadyLocked.withValue(true) {
                    if let resolvedOnDemandActor = resolveOnDemand(id) {
                        taggedLogger.debug("Resolved ON DEMAND as \(resolvedOnDemandActor)")
                        return resolvedOnDemandActor
                    } else {
                        taggedLogger.debug("not resolved")
                        return nil
                    }
                }
            } else {
                taggedLogger.debug("no resolveOnDemandHandler")
            }

            taggedLogger.debug("definitely remote")
            return nil // definitely remote, we don't know about this ActorID
        }

        taggedLogger.info("resolved as \(resolved)")
        return resolved
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        .init()
    }
}

extension WebSocketActorSystem {

    public func registerOnDemandResolveHandler(resolveOnDemand: @escaping (ActorID) -> (any DistributedActor)?) {
        lock.lock()
        defer {
            self.lock.unlock()
        }

        self.resolveOnDemandHandler = resolveOnDemand
    }

    @TaskLocal
    static var actorIDHint: ActorID?

    /// Create a local actor with the specified id.
    public func makeActor<Act>(id: ActorID, _ factory: () -> Act) -> Act
    where Act: DistributedActor, Act.ActorSystem == WebSocketActorSystem {
        Self.$actorIDHint.withValue(id.with(nodeID)) {
            factory()
        }
    }
    
    /// Create a local actor with a random id prefixed with the actor's type.
    public func makeActor<Act>(_ factory: () -> Act) -> Act
        where Act: DistributedActor, Act.ActorSystem == WebSocketActorSystem {
            Self.$actorIDHint.withValue(.random(for: Act.self, node: nodeID)) {
            factory()
        }
    }
}

extension WebSocketActorSystem {
    func decodeAndDeliver(data: inout ByteBuffer, from address: SocketAddress?,
                          on channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async {
        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = self
        
        let taggedLogger = logger.withOp()

        do {
            let wireEnvelope = try data.readJSONDecodable(WebSocketWireEnvelope.self, length: data.readableBytes)

            switch wireEnvelope {
            case .call(let remoteCallEnvelope):
                // log("receive-decode-deliver", "Decode remoteCall...")
                self.receiveInboundCall(envelope: remoteCallEnvelope, on: channel)
            case .reply(let replyEnvelope):
                try await self.receiveInboundReply(envelope: replyEnvelope, on: channel)
            case .none, .connectionClose:
                taggedLogger.error("Failed decoding: \(data); decoded empty")
            }
        } catch {
            taggedLogger.error("Failed decoding: \(data), error: \(error)")
        }
        taggedLogger.trace("done")
    }

    func receiveInboundCall(envelope: RemoteWebSocketCallEnvelope, on channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        let taggedLogger = logger.withOp()
        taggedLogger.trace("Envelope: \(envelope)")
        Task {
            taggedLogger.trace("Calling resolveAny(id: \(envelope.recipient))")
            guard let anyRecipient = resolveAny(id: envelope.recipient, resolveReceptionist: true) else {
                taggedLogger.warning("failed to resolve \(envelope.recipient)")
                return
            }
            taggedLogger.debug("Recipient: \(anyRecipient)")
            let target = RemoteCallTarget(envelope.invocationTarget)
            taggedLogger.debug("Target: \(target)")
            taggedLogger.debug("Target.identifier: \(target.identifier)")
            let handler = ResultHandler(actorSystem: self, callID: envelope.callID, system: self, channel: channel)
            taggedLogger.debug("Handler: \(anyRecipient)")

            do {
                var decoder = Self.InvocationDecoder(system: self, envelope: envelope, channel: channel)
                func doExecuteDistributedTarget<Act: DistributedActor>(recipient: Act) async throws {
                    taggedLogger.trace("executeDistributedTarget")
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
                taggedLogger.error("failed to executeDistributedTarget [\(target)] on [\(anyRecipient)], error: \(error)")
                try! await handler.onThrow(error: error)
            }
        }
    }

    func receiveInboundReply(envelope: WebSocketReplyEnvelope, on channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async throws {
        let taggedLogger = logger.withOp()
        taggedLogger.trace("Reply envelope: \(envelope)")
        try await pendingReplies.receivedReply(callID: envelope.callID, data: envelope.value)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: RemoteCall implementations

extension WebSocketActorSystem {
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        let taggedLogger = logger.withOp().with(actor.id)
        taggedLogger.trace("Call to: \(actor.id), target: \(target), target.identifier: \(target.identifier)")

        let channel = try self.selectChannel(for: actor.id)
        taggedLogger.debug("channel: \(channel)")

        taggedLogger.trace("Prepare [\(target)] call...")
        
        let localInvocation = invocation
        
        let replyData = try await pendingReplies.sendMessage { callID in
            let callEnvelope = RemoteWebSocketCallEnvelope(
                callID: callID,
                recipient: actor.id,
                invocationTarget: target.identifier,
                genericSubs: localInvocation.genericSubs,
                args: localInvocation.argumentData
            )
            let wireEnvelope = WebSocketWireEnvelope.call(callEnvelope)

            taggedLogger.debug("Write envelope: \(wireEnvelope)")
            
//            let frame = WebSocketFrame(opcode: .text, data: try JSONEncoder().encode(wireEnvelope))
            
            try await self.write(channel: channel, envelope: wireEnvelope)
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
        let taggedLogger = logger.withOp().with(actor.id)
        taggedLogger.trace("Call to: \(actor.id), target: \(target), target.identifier: \(target.identifier)")
        
        let channel = try selectChannel(for: actor.id)
//        taggedLogger.debug("channel: \(channel)")
        
        let localInvocation = invocation
        
        taggedLogger.trace("Prepare [\(target)] call...")
        _ = try await pendingReplies.sendMessage { callID in
            let callEnvelope = RemoteWebSocketCallEnvelope(
                callID: callID,
                recipient: actor.id,
                invocationTarget: target.identifier,
                genericSubs: localInvocation.genericSubs,
                args: localInvocation.argumentData
            )
            let wireEnvelope = WebSocketWireEnvelope.call(callEnvelope)
            
            taggedLogger.debug("Write envelope: \(wireEnvelope)")
            
            try await self.write(channel: channel, envelope: wireEnvelope)
        }
        
        taggedLogger.trace("COMPLETED CALL: \(target)")
    }
    
    
    
    func write(channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, 
               envelope: WebSocketWireEnvelope) async throws {
        let taggedLogger = logger.withOp()
        taggedLogger.trace("unwrap WebSocketWireEnvelope")

        switch envelope {
        case .connectionClose:
            var data = channel.channel.allocator.buffer(capacity: 2)
            data.write(webSocketErrorCode: .protocolError)
            let frame = WebSocketFrame(fin: true,
                opcode: .connectionClose,
                data: data)
            try await channel.outbound.write(frame)
            try await channel.channel.close()
        case .reply, .call:
            let encoder = JSONEncoder()
            encoder.userInfo[.actorSystemKey] = self
            encoder.userInfo[.channelKey] = channel

            do {
                var data = ByteBuffer()
                try data.writeJSONEncodable(envelope, encoder: encoder)
                taggedLogger.trace("Write: \(envelope)")

                let frame = WebSocketFrame(fin: true, opcode: .text, data: data)
                try await channel.outbound.write(frame)
            } catch {
                taggedLogger.error("Failed to serialize call [\(envelope)], error: \(error)")
            }
        }
    }

    /// Return the Channel we should use to communicate with the given actor..
    /// Throws an exception if the actor is not reachable.
    func selectChannel(for actorID: ActorID) throws -> NIOAsyncChannel<WebSocketFrame, WebSocketFrame> {
        switch mode {
        case .clientFor:
            // On the client, any actor without a known NodeID is assumed to be on the server.
            self.lock.lock()
            defer { self.lock.unlock() }
            return channel!
            
        case .serverOnly:
            // On the server, we can only know where to send the message if the actor
            // has a NodeID and we have a mapping from the NodeID to the Channel.
            guard let nodeID = actorID.node else {
                logger.error("The nodeID for remote actor \(actorID) is missing.")
                throw WebSocketActorSystemError.missingNodeID(id: actorID)
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let channel = nodeRegistry.channel(for: nodeID) else {
                logger.error("There is not currently a channel for nodeID \(nodeID)")
                throw WebSocketActorSystemError.noChannelToNode(id: nodeID)
            }
            return channel
        }
    }

    private func withCallIDContinuation<Act>(recipient: Act, body: (CallID) -> Void) async throws -> Data
    where Act: DistributedActor {
        let taggedLogger = logger.withOp()
        let data = try await withCheckedThrowingContinuation { continuation in
            let callID = UUID()
            
            self.replyLock.lock()
            self.inFlightCalls[callID] = continuation
            self.replyLock.unlock()
            
            taggedLogger.trace("Stored callID:[\(callID)], waiting for reply...")
            body(callID)
        }
        
        taggedLogger.trace("Resumed call, data: \(String(data: data, encoding: .utf8)!)")
        return data
    }
}

public struct WebSocketActorSystemResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = any Codable

    let actorSystem: WebSocketActorSystem
    let callID: WebSocketActorSystem.CallID
    let system: WebSocketActorSystem
    let channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>

    public func onReturn<Success: Codable>(value: Success) async throws {
        system.logger.withOp().trace("Write to channel: \(channel)")
        let encoder = JSONEncoder()
        encoder.userInfo[.actorSystemKey] = actorSystem
        let returnValue = try encoder.encode(value)
        let envelope = WebSocketReplyEnvelope(callID: self.callID, sender: nil, value: returnValue)
        try await actorSystem.write(channel: channel, envelope: WebSocketWireEnvelope.reply(envelope))
//        try await channel.channel.writeAndFlush(WebSocketWireEnvelope.reply(envelope))
    }

    public func onReturnVoid() async throws {
        system.logger.withOp().trace("Write to channel: \(channel)")
        let envelope = WebSocketReplyEnvelope(callID: self.callID, sender: nil, value: "".data(using: .utf8)!)
        try await actorSystem.write(channel: channel, envelope: WebSocketWireEnvelope.reply(envelope))
//        try await channel.channel.writeAndFlush(WebSocketWireEnvelope.reply(envelope))
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        system.logger.withOp().trace("onThrow: \(error)")
        // Naive best-effort carrying the error name back to the caller;
        // Always be careful when exposing error information -- especially do not ship back the entire description
        // or error of a thrown value as it may contain information which should never leave the node.
        let envelope = WebSocketReplyEnvelope(callID: self.callID, sender: nil, value: "".data(using: .utf8)!)
        try await actorSystem.write(channel: channel, envelope: WebSocketWireEnvelope.reply(envelope))
//        try await channel.channel.writeAndFlush(WebSocketWireEnvelope.reply(envelope))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Reply handling

extension WebSocketActorSystem {
    func sendReply(_ envelope: WebSocketReplyEnvelope, on channel: Channel) throws {
        lock.lock()
        defer {
            self.lock.unlock()
        }

        // let encoder = JSONEncoder()
        // let data = try encoder.encode(envelope)

        logger.withOp().trace("Sending reply to [\(envelope.callID)]: envelope: \(envelope), on channel: \(channel)")
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
    
    /// We are trying to send a message to a remote actor, but that actor does not
    /// have a NodeIdentity. This probably means that the remote node passed us an actor
    /// that was not constructed using the `WebSocketActorSystem.makeActor(id:_:)`,
    /// as it should have been.
    case missingNodeID(id: WebSocketActorSystem.ActorID)
    
    /// We are trying to send a message to a remote actor, but we do not currently
    /// have an open `Channel` to the remote node. This is currently an error.
    /// Future versions of this library may attempt to reconnect to the remote node
    /// instead of throwing this error.
    case noChannelToNode(id: NodeIdentity)
    
    case failedToUpgrade
    
    case missingReplyContinuation(callID: UUID)
}
