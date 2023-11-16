/*
 See LICENSE folder for this sample’s licensing information.
 
 Abstract:
 Server side implementation of the WebSocket Actor System.
 */

import Distributed
import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Server-side networking stack


let websocketResponse = """
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Swift NIO WebSocket Test Page</title>
    <script>
        var wsconnection = new WebSocket("ws://localhost:8888/websocket");
        wsconnection.onmessage = function (msg) {
            var element = document.createElement("p");
            element.innerHTML = msg.data;

            var textDiv = document.getElementById("websocket-stream");
            textDiv.insertBefore(element, null);
        };
    </script>
  </head>
  <body>
    <h1>WebSocket Stream</h1>
    <div id="websocket-stream"></div>
  </body>
</html>
"""

/// A `Manager` is an actor protocol that provides the `WebSocketActorSystem`
/// with a uniform interface to clients and servers, so that certain universal
/// operations can be performed without caring which mode the actor system is in.
protocol Manager {
    
    /// Return the local port number. For the server, this is the port it is listening on.
    /// For a client, this is the (less important) local port number it is connecting from.
    ///
    /// - Note: Even for a server, the`localPort()` is only needed
    /// when the server was created on port 0, which uses a system-assigned port.
    /// This is normally the case only when writing tests. In production, the server
    /// is usually created on a fixed port number and calls to `localPort()` are not needed.
    func localPort() async throws -> Int
    
    /// The `Manager` should associate the given `nodeID` with the given `channel`.
    /// Only servers need to implement this, since a client only has a single connection.
    func associate(nodeID: NodeIdentity, with channel: WebSocketAgentChannel) async
    
    /// Select a channel to the given `actorID`. This function is only called for remote actors.
    /// Clients can simply return their current channel, while servers need to look up the
    /// channel associated with the actor's node ID.
    func selectChannel(for actorID: ActorIdentity) async throws -> WebSocketAgentChannel
    
    /// Close all channels and stop re-opening them. This is called when the actor system
    /// wants to shut down.
    func cancel() async
}

/// The channel type the server uses to listen for new client connections.
typealias ServerMasterChannel = NIOAsyncChannel<EventLoopFuture<WebSocketActorSystem.ServerUpgradeResult>, Never>

extension WebSocketActorSystem {
    private static let responseBody = ByteBuffer(string: websocketResponse)
    
    enum ServerUpgradeResult {
        case websocket(WebSocketAgentChannel)
        case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }
    
    private actor ServerManager: Manager {
        private let system: WebSocketActorSystem
        private var _task: ResilientTask?
        private var _channel: ServerMasterChannel?
        private var nodeRegistry = RemoteNodeRegistry()
        private var waitingForChannel: [CheckedContinuation<ServerMasterChannel, Error>] = []
        
        init(system: WebSocketActorSystem) {
            self.system = system
        }
        
        func localPort() async throws -> Int {
            let chan = try await requireChannel()
            return chan.channel.localAddress?.port ?? 0
        }
        
        func associate(nodeID: NodeIdentity, with channel: WebSocketAgentChannel) {
            system.logger.notice("associating \(nodeID) with channel")
            nodeRegistry.register(id: nodeID, channel: channel)
        }
        
        func selectChannel(for actorID: ActorIdentity) async throws -> WebSocketAgentChannel {
            guard let nodeID = actorID.node else {
                system.logger.error("The nodeID for remote actor \(actorID) is missing.")
                throw WebSocketActorSystemError.missingNodeID(id: actorID)
            }
            guard let channel = nodeRegistry.channel(for: nodeID) else {
                system.logger.error("There is not currently a channel for nodeID \(nodeID)")
                throw WebSocketActorSystemError.noChannelToNode(id: nodeID)
            }
            return channel
        }
        
        private func setChannel(_ channel: ServerMasterChannel) async {
            _channel = channel
            for waiter in waitingForChannel {
                waiter.resume(returning: channel)
            }
            waitingForChannel.removeAll()
        }
        
        internal func resolveChannel(continuation: CheckedContinuation<ServerMasterChannel, Error>) {
            if let channel = _channel {
                continuation.resume(returning: channel)
            } else {
                waitingForChannel.append(continuation)
            }
        }
        
        internal func requireChannel() async throws  -> ServerMasterChannel {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    resolveChannel(continuation: continuation)
                }
            }
        }
        
        public func cancel() {
            _channel = nil
            _task?.cancel()
            _task = nil
        }
        
        func connect(host: String, port: Int) {
            cancel()
            _task = ResilientTask() { initialized in
                let channel = try await Self.openServerChannel(host: host, port: port)
                await self.setChannel(channel)
                
                await initialized()
                
                // We are handling each incoming connection in a separate child task. It is important
                // to use a discarding task group here which automatically discards finished child tasks.
                // A normal task group retains all child tasks and their outputs in memory until they are
                // consumed by iterating the group or by exiting the group. Since, we are never consuming
                // the results of the group we need the group to automatically discard them; otherwise, this
                // would result in a memory leak over time.
                if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await upgradeResult in channel.inbound {
                            group.addTask {
                                await self.system.handleUpgradeResult(upgradeResult)
                            }
                        }
                    }
                } else {
                    // Fallback on earlier versions
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for try await upgradeResult in channel.inbound {
                            group.addTask {
                                await self.system.handleUpgradeResult(upgradeResult)
                            }
                        }
                    }
                }
            }
        }
        
        static func openServerChannel(host: String, port: Int) async throws -> ServerMasterChannel {
            try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(
                    host: host,
                    port: port
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let upgrader = NIOTypedWebSocketServerUpgrader<ServerUpgradeResult>(
                            shouldUpgrade: { (channel, head) in
                                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                            },
                            upgradePipelineHandler: { (channel, _) in
                                channel.eventLoop.makeCompletedFuture {
                                    let asyncChannel = try WebSocketAgentChannel(synchronouslyWrapping: channel)
                                    return ServerUpgradeResult.websocket(asyncChannel)
                                }
                            }
                        )

                        let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
                            upgraders: [upgrader],
                            notUpgradingCompletionHandler: { channel in
                                channel.eventLoop.makeCompletedFuture {
                                    try channel.pipeline.syncOperations.addHandler(HTTPByteBufferResponsePartHandler())
                                    let asyncChannel = try NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>(synchronouslyWrapping: channel)
                                    return ServerUpgradeResult.notUpgraded(asyncChannel)
                                }
                            }
                        )

                        let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                            configuration: .init(upgradeConfiguration: serverUpgradeConfiguration)
                        )

                        return negotiationResultFuture
                    }
                }
        }
    }
    
    internal func createServerManager(at address: ServerAddress) async -> Manager {
        let server = ServerManager(system: self)
        await server.connect(host: address.host, port: address.port)
        return server
    }
    
    /// This method handles a single connection by echoing back all inbound data.
    internal func handleUpgradeResult(_ upgradeResult: EventLoopFuture<ServerUpgradeResult>) async {
        // Note that this method is non-throwing and we are catching any error.
        // We do this since we don't want to tear down the whole server when a single connection
        // encounters an error.
        do {
            switch try await upgradeResult.get() {
            case .websocket(let websocketChannel):
                logger.trace("Handling websocket connection")
                try await self.handleWebsocketChannel(websocketChannel)
                logger.trace("Done handling websocket connection")
            case .notUpgraded(let httpChannel):
                logger.trace("Handling HTTP connection")
                try await Self.handleHTTPChannel(httpChannel)
                logger.trace("Done handling HTTP connection")
            }
        } catch {
            logger.error("Hit error: \(error)")
        }
    }

    
    private func handleWebsocketChannel(_ channel: WebSocketAgentChannel) async throws {
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.dispatchIncomingFrames(channel: channel)
            }

            try await group.next()
            group.cancelAll()
        }
    }
    
    internal func closeOnError(channel: WebSocketAgentChannel) async {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection.
        var data = channel.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        
        do {
            try? await channel.channel.writeAndFlush(NIOAny(WebSocketWireEnvelope.connectionClose))
            try await channel.channel.close(mode: .output)
        }
        catch {
            logger.error("Error closing channel after error: \(error)")
        }

//        awaitingClose = true
    }

    private static func handleHTTPChannel(_ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>) async throws {
        for try await requestPart in channel.inbound {
            // We're not interested in request bodies here: we're just serving up GET responses
            // to get the client to initiate a websocket request.
            guard case .head(let head) = requestPart else {
                return
            }

            // GETs only.
            guard case .GET = head.method else {
                try await Self.respond405(writer: channel.outbound)
                return
            }

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/html")
            headers.add(name: "Content-Length", value: String(Self.responseBody.readableBytes))
            headers.add(name: "Connection", value: "close")
            let responseHead = HTTPResponseHead(
                version: .init(major: 1, minor: 1),
                status: .ok,
                headers: headers
            )

            try await channel.outbound.write(
                contentsOf: [
                    .head(responseHead),
                    .body(Self.responseBody),
                    .end(nil)
                ]
            )
        }
    }

    private static func respond405(writer: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .methodNotAllowed,
            headers: headers
        )

        try await writer.write(
            contentsOf: [
                .head(head),
                .end(nil)
            ]
        )
    }
}

final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = self.unwrapOutboundIn(data)
        switch part {
        case .head(let head):
            context.write(self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
