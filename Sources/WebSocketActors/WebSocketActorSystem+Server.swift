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
typealias ServerListeningChannel = NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never>

extension WebSocketAgentChannel {
    var remoteDescription: String {
        "\(channel.remoteAddress?.description ?? "unknown")"
    }
}

enum ServerUpgradeResult {
    case websocket(WebSocketAgentChannel, NodeIdentity)
    case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}

extension WebSocketActorSystem {
    private static let responseBody = ByteBuffer(string: websocketResponse)

    func createServerManager(at address: ServerAddress) async -> ServerManager {
        let server = ServerManager(system: self, on: address)
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
            // Only log the error if it's not a CancellationError, which occurs
            // normally when the server is shutting down.
            if error as? CancellationError == nil {
                logger.error("Error handling server connection: \(error)")
            }
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
