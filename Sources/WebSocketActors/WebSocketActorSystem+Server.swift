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

protocol Manager {
    var localPort: Int { get async }
    func associate(nodeID: NodeIdentity, with channel: WebSocketAgentChannel) async
    func selectChannel(for actorID: ActorIdentity) async throws -> WebSocketAgentChannel
    func cancel() async
}

struct StubManager: Manager {
    var localPort: Int = 0
    
    func associate(nodeID: NodeIdentity, with channel: WebSocketAgentChannel) async {
    }
    
    func selectChannel(for actorID: ActorIdentity) async throws -> WebSocketAgentChannel {
        throw WebSocketActorSystemError.noChannelToNode(id: actorID.node ?? NodeIdentity(id: "unknown"))
    }
    
    func cancel() async {
    }
}

extension WebSocketActorSystem {
    private static let responseBody = ByteBuffer(string: websocketResponse)
    
    enum ServerUpgradeResult {
        case websocket(WebSocketAgentChannel)
        case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }
    
    func openServerChannel(host: String, port: Int) async throws -> NIOAsyncChannel<EventLoopFuture<WebSocketActorSystem.ServerUpgradeResult>, Never> {
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
    
    public actor ServerManager: Manager {
        private var _task: ResilientTask?
        private var _channel: NIOAsyncChannel<EventLoopFuture<WebSocketActorSystem.ServerUpgradeResult>, Never>?
        private var nodeRegistry = RemoteNodeRegistry()
        private let channelReady = DispatchSemaphore(value: 0)
        
        
        public var localPort: Int {
            get {
//                channelReady.wait()
                return _channel?.channel.localAddress?.port ?? 0
            }
        }
        
        func associate(nodeID: NodeIdentity, with channel: WebSocketAgentChannel) {
            nodeRegistry.register(id: nodeID, channel: channel)
        }
        
        func selectChannel(for actorID: ActorIdentity) async throws -> WebSocketAgentChannel {
            guard let nodeID = actorID.node else {
//                logger.error("The nodeID for remote actor \(actorID) is missing.")
                throw WebSocketActorSystemError.missingNodeID(id: actorID)
            }
            guard let channel = nodeRegistry.channel(for: nodeID) else {
//                logger.error("There is not currently a channel for nodeID \(nodeID)")
                throw WebSocketActorSystemError.noChannelToNode(id: nodeID)
            }
            return channel
        }
        
        internal func setTask(_ task: ResilientTask) {
            self._task = task
        }
        
        internal func setChannelInternal(_ channel: NIOAsyncChannel<EventLoopFuture<WebSocketActorSystem.ServerUpgradeResult>, Never>) {
            _channel = channel
        }
        
        nonisolated
        internal func setChannel(_ channel: NIOAsyncChannel<EventLoopFuture<WebSocketActorSystem.ServerUpgradeResult>, Never>) async {
            await self.setChannelInternal(channel)
            channelReady.signal()
        }
        
        public func cancel() {
            _channel = nil
            _task?.cancel()
        }
    }
    
    internal func createServerManager(host: String, port: Int) async -> ServerManager {
        let server = ServerManager()
        await server.setTask(ResilientTask() { initialized in
            let channel = try await self.openServerChannel(host: host, port: port)
            await server.setChannel(channel)
            
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
        })
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
                print("Handling websocket connection")
                try await self.handleWebsocketChannel(websocketChannel)
                print("Done handling websocket connection")
            case .notUpgraded(let httpChannel):
                print("Handling HTTP connection")
                try await self.handleHTTPChannel(httpChannel)
                print("Done handling HTTP connection")
            }
        } catch {
            print("Hit error: \(error)")
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


    private func handleHTTPChannel(_ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>) async throws {
        for try await requestPart in channel.inbound {
            // We're not interested in request bodies here: we're just serving up GET responses
            // to get the client to initiate a websocket request.
            guard case .head(let head) = requestPart else {
                return
            }

            // GETs only.
            guard case .GET = head.method else {
                try await self.respond405(writer: channel.outbound)
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

    private func respond405(writer: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>) async throws {
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
