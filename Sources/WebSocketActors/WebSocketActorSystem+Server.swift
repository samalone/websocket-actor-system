/*
 See LICENSE folder for this sample’s licensing information.

 Abstract:
 Server side implementation of the WebSocket Actor System.
 */

import Distributed
import Foundation
import NIO
import NIOAsyncWebSockets
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

/// The channel type the server uses to listen for new client connections.
typealias ServerListeningChannel = NIOAsyncChannel<EventLoopFuture<WebSocketActorSystem.ServerUpgradeResult>, Never>

extension WebSocketAgentChannel {
    var remoteDescription: String {
        "\(channel.remoteAddress?.description ?? "unknown")"
    }
}

enum FakeUpgradeError: Error {
    case cantReallyUpgrade
}

extension WebSocketActorSystem {
    private static let responseBody = ByteBuffer(string: websocketResponse)

    enum ServerUpgradeResult {
        case websocket(WebSocketAgentChannel, NodeIdentity)
        case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }

    final class MyUpgrader<UpgradeResult: Sendable>: NIOTypedHTTPServerProtocolUpgrader, Sendable {
        let supportedProtocol: String = "websocket"

        let requiredUpgradeHeaders: [String] = []

        func buildUpgradeResponse(channel: NIOCore.Channel, upgradeRequest: NIOHTTP1.HTTPRequestHead, initialResponseHeaders: NIOHTTP1.HTTPHeaders) -> NIOCore.EventLoopFuture<NIOHTTP1.HTTPHeaders> {
            print("build upgrade response")
            return channel.eventLoop.makeFailedFuture(FakeUpgradeError.cantReallyUpgrade)
        }

        func upgrade(channel: NIOCore.Channel, upgradeRequest: NIOHTTP1.HTTPRequestHead) -> NIOCore.EventLoopFuture<UpgradeResult> {
            print("upgrade")
            return channel.eventLoop.makeFailedFuture(FakeUpgradeError.cantReallyUpgrade)
        }
    }

    private actor ServerManager: Manager {
        private let system: WebSocketActorSystem
        private var _task: ResilientTask?
        private var _channel: ServerListeningChannel?
        private var waitingForChannel: [CheckedContinuation<ServerListeningChannel, Never>] = []
        private var remoteNodes: [NodeIdentity: Status] = [:]

        enum Status {
            case current(RemoteNode)
            case future([CheckedContinuation<RemoteNode, Never>])
        }

        init(system: WebSocketActorSystem) {
            self.system = system
        }

        func localPort() async throws -> Int {
            let chan = try await requireChannel()
            return chan.channel.localAddress?.port ?? 0
        }

        func remoteNode(for actorID: ActorIdentity) async throws -> RemoteNode {
            guard let nodeID = actorID.node else {
                system.logger.critical("Cannot get RemoteNode without nodeID for actor \(actorID)")
                throw WebSocketActorSystemError.missingNodeID(id: actorID)
            }
            return await requireRemoteNode(nodeID: nodeID)
        }

        private func setChannel(_ channel: ServerListeningChannel) {
            _channel = channel
            for waiter in waitingForChannel {
                waiter.resume(returning: channel)
            }
            waitingForChannel.removeAll()
        }

        func requireChannel() async throws -> ServerListeningChannel {
            if let channel = _channel {
                channel
            }
            else {
                await withCheckedContinuation { continuation in
                    waitingForChannel.append(continuation)
                }
            }
        }

        func requireRemoteNode(nodeID: NodeIdentity) async -> RemoteNode {
            if let status = remoteNodes[nodeID] {
                switch status {
                case .current(let node):
                    node
                case .future(let continuations):
                    await withCheckedContinuation { continuation in
                        Task {
                            remoteNodes[nodeID] = .future(continuations + [continuation])
                        }
                    }
                }
            }
            else {
                await withCheckedContinuation { continuation in
                    Task {
                        remoteNodes[nodeID] = .future([continuation])
                    }
                }
            }
        }

        func opened(remote: RemoteNode) {
            let nodeID = remote.nodeID
            if let status = remoteNodes[nodeID], case .future(let continuations) = status {
                remoteNodes[nodeID] = .current(remote)
                for continuation in continuations {
                    continuation.resume(returning: remote)
                }
            }
            else {
                remoteNodes[nodeID] = .current(remote)
            }
        }

        func closing(remote: RemoteNode) {
            remoteNodes.removeValue(forKey: remote.nodeID)
        }

        public func cancel() {
            _channel = nil
            _task?.cancel()
            _task = nil
        }

        func connect(host: String, port: Int) {
            cancel()
            _task = ResilientTask { initialized in

                try await TaskPath.with(name: "server connection") {
                    let channel = try await self.openServerChannel(host: host, port: port)
                    self.setChannel(channel)

                    await initialized()

                    // We are handling each incoming connection in a separate child task. It is important
                    // to use a discarding task group here which automatically discards finished child tasks.
                    // A normal task group retains all child tasks and their outputs in memory until they are
                    // consumed by iterating the group or by exiting the group. Since, we are never consuming
                    // the results of the group we need the group to automatically discard them; otherwise, this
                    // would result in a memory leak over time.
                    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
                        try await withThrowingDiscardingTaskGroup { group in
                            try await channel.executeThenClose { inbound, _ in
                                for try await upgradeResult in inbound {
                                    group.addTask {
                                        await self.system.handleUpgradeResult(upgradeResult)
                                    }
                                }
                            }
                        }
                    }
                    else {
                        // Fallback on earlier versions
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            try await channel.executeThenClose { inbound, _ in
                                for try await upgradeResult in inbound {
                                    group.addTask {
                                        await self.system.handleUpgradeResult(upgradeResult)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        func openServerChannel(host: String, port: Int) async throws -> ServerListeningChannel {
            try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: host,
                      port: port)
            { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOAsyncWebSockets
                        .NIOTypedWebSocketServerUpgrader<ServerUpgradeResult>(
                            shouldUpgrade: { channel, _ in
                                // Any headers we set here will be passed back to the client
                                // in the response.
                                var headers = HTTPHeaders()
                                headers.nodeID = self.system.nodeID
                                return channel
                                    .eventLoop
                                    .makeSucceededFuture(headers)
                            },
                            upgradePipelineHandler: { channel, requestHead in
                                channel
                                    .eventLoop
                                    .makeCompletedFuture {
                                        let remoteNodeID = requestHead.headers.nodeID!
                                        let asyncChannel =
                                            try WebSocketAgentChannel(wrappingChannelSynchronously: channel)
                                        return ServerUpgradeResult.websocket(asyncChannel, remoteNodeID)
                                    }
                            })

                    let preUpgrade = MyUpgrader<ServerUpgradeResult>()

                    let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [preUpgrade, upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop
                                .makeCompletedFuture {
                                    try channel.pipeline.syncOperations.addHandler(HTTPByteBufferResponsePartHandler())
                                    let asyncChannel =
                                        try NIOAsyncChannel<HTTPServerRequestPart,
                                            HTTPPart<HTTPResponseHead,
                                                ByteBuffer>>(wrappingChannelSynchronously: channel)
                                    return ServerUpgradeResult
                                        .notUpgraded(asyncChannel)
                                }
                        })

                    let negotiationResultFuture = try channel.pipeline.syncOperations
                        .configureUpgradableHTTPServerPipeline(
                            configuration: .init(upgradeConfiguration: serverUpgradeConfiguration))

                    return negotiationResultFuture
                }
            }
        }
    }

    func createServerManager(at address: ServerAddress) async -> Manager {
        let server = ServerManager(system: self)
        await server.connect(host: address.host, port: address.port)
        return server
    }

    /// This method handles a single connection by echoing back all inbound data.
    func handleUpgradeResult(_ upgradeResult: EventLoopFuture<ServerUpgradeResult>) async {
        // Note that this method is non-throwing and we are catching any error.
        // We do this since we don't want to tear down the whole server when a single connection
        // encounters an error.
        do {
            switch try await upgradeResult.get() {
            case .websocket(let websocketChannel, let remoteNodeID):
                logger.trace("Handling websocket connection")
                try await handleWebsocketChannel(websocketChannel, remoteNodeID: remoteNodeID)
                logger.trace("Done handling websocket connection")
            case .notUpgraded(let httpChannel):
                logger.trace("Handling HTTP connection")
                try await handleHTTPChannel(httpChannel)
                logger.trace("Done handling HTTP connection")
            }
        }
        catch {
            logger.error("Hit error: \(error)")
        }
    }

    private func handleWebsocketChannel(_ channel: WebSocketAgentChannel, remoteNodeID: NodeIdentity) async throws {
        let taggedLogger = logger.withOp().with(channel)
        taggedLogger.info("new client connection")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.dispatchIncomingFrames(channel: channel, remoteNodeID: remoteNodeID)
            }

            try await group.next()
            group.cancelAll()
        }

        taggedLogger.info("client connection closed")
    }

    func closeOnError(channel: WebSocketAgentChannel) async {
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

    private func handleHTTPChannel(_ channel: NIOAsyncChannel<HTTPServerRequestPart,
        HTTPPart<HTTPResponseHead, ByteBuffer>>) async throws
    {
        try await channel.executeThenClose { inbound, outbound in
            for try await requestPart in inbound {
                // We're not interested in request bodies here: we're just serving up GET responses
                // to get the client to initiate a websocket request.
                guard case .head(let head) = requestPart else {
                    return
                }

                // GETs only.
                guard case .GET = head.method else {
                    try await Self.respond405(writer: outbound)
                    return
                }

                guard head.headers.nodeID != nil else {
                    try await Self.respond405(writer: outbound)
                    return
                }

                var headers = HTTPHeaders()
                headers.nodeID = nodeID
                headers.add(name: "Content-Type", value: "text/html")
                headers.add(name: "Content-Length", value: String(Self.responseBody.readableBytes))
                headers.add(name: "Connection", value: "close")
                let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1),
                                                    status: .ok,
                                                    headers: headers)

                try await outbound.write(contentsOf: [
                    .head(responseHead),
                    .body(Self.responseBody),
                    .end(nil),
                ])
            }
        }
    }

    private static func respond405(writer: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead,
        ByteBuffer>>) async throws
    {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .http1_1,
                                    status: .methodNotAllowed,
                                    headers: headers)

        try await writer.write(contentsOf: [
            .head(head),
            .end(nil),
        ])
    }
}

final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)
        switch part {
        case .head(let head):
            context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
