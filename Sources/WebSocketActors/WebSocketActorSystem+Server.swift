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


@available(macOS 14, *)
extension WebSocketActorSystem {
    private static let responseBody = ByteBuffer(string: websocketResponse)
    
    enum ServerUpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }
    
    func startServer(host: String, port: Int) async throws -> NIOAsyncChannel<EventLoopFuture<WebSocketActorSystem.ServerUpgradeResult>, Never> {
        
        let channel: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never> = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
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
                                let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(synchronouslyWrapping: channel)
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
        
        // We are handling each incoming connection in a separate child task. It is important
        // to use a discarding task group here which automatically discards finished child tasks.
        // A normal task group retains all child tasks and their outputs in memory until they are
        // consumed by iterating the group or by exiting the group. Since, we are never consuming
        // the results of the group we need the group to automatically discard them; otherwise, this
        // would result in a memory leak over time.
//        try await withThrowingDiscardingTaskGroup { group in
//            for try await upgradeResult in channel.inbound {
//                group.addTask {
//                    await self.handleUpgradeResult(upgradeResult)
//                }
//            }
//        }
        
        // Upgrader performs upgrade from HTTP to WS connection
//        let upgrader = NIOWebSocketServerUpgrader(
//            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
//                // Always upgrade; this is where we could do some auth checks
//                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
//            },
//            upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
//                channel.pipeline.addHandlers(
//                    WebSocketMessageOutboundHandler(actorSystem: self),
//                    WebSocketActorMessageInboundHandler(actorSystem: self)
//                )
//            }
//        )
        
        return channel
        
//        let bootstrap = ServerBootstrap(group: group)
//        // Specify backlog and enable SO_REUSEADDR for the server itself
//            .serverChannelOption(ChannelOptions.backlog, value: 256)
//            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
//        
//        // Enable SO_REUSEADDR for the accepted Channels
//            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
//        
//        let channel = try await bootstrap.bind(host: host, port: port) { channel in
//            let httpHandler = HTTPHandler(logger: self.logger)
//            let config: NIOHTTPServerUpgradeConfiguration = (
//                upgraders: [upgrader],
//                completionHandler: { _ in
//                    channel.pipeline.removeHandler(httpHandler, promise: nil)
//                }
//            )
//            return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
//                channel.pipeline.addHandler(httpHandler)
//            }.map {
//                return channel
//            }
//        }
//        
//        guard channel.channel.localAddress != nil else {
//            fatalError("Address was unable to bind. Please check that the socket was not closed or that the address family was understood.")
//        }
//        
//        return channel
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

    
    private func handleWebsocketChannel(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async throws {
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.dispatchIncomingFrames(channel: channel)
                
//                for try await frame in channel.inbound {
//                    switch frame.opcode {
//                    case .connectionClose:
//                        // Close the connection.
//                        //
//                        // We might also want to inform the actor system that this connection
//                        // went away, so it can terminate any tasks or actors working to
//                        // inform the remote receptionist on the now-gone system about our
//                        // actors.
//                        return
//                    case .text:
//                        var data = frame.unmaskedData
//                        let text = data.getString(at: 0, length: data.readableBytes) ?? ""
//                        self.logger.withOp().trace("Received: \(text), from: \(String(describing: channel.channel.remoteAddress))")
//                        
//                        await self.decodeAndDeliver(data: &data, from: channel.channel.remoteAddress,
//                                               on: channel)
//                        
//                    case .binary, .continuation, .pong, .ping:
//                        // We ignore these frames.
//                        break
//                    default:
//                        // Unknown frames are errors.
//                        await self.closeOnError(channel: channel)
//                    }
//                }
//                
//                for try await frame in channel.inbound {
//                    switch frame.opcode {
//                    case .ping:
//                        print("Received ping")
//                        var frameData = frame.data
//                        let maskingKey = frame.maskKey
//
//                        if let maskingKey = maskingKey {
//                            frameData.webSocketUnmask(maskingKey)
//                        }
//
//                        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
//                        try await channel.outbound.write(responseFrame)
//
//                    case .connectionClose:
//                        // This is an unsolicited close. We're going to send a response frame and
//                        // then, when we've sent it, close up shop. We should send back the close code the remote
//                        // peer sent us, unless they didn't send one at all.
//                        print("Received close")
//                        var data = frame.unmaskedData
//                        let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
//                        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
//                        try await channel.outbound.write(closeFrame)
//                        return
//                    case .binary, .continuation, .pong:
//                        // We ignore these frames.
//                        break
//                    default:
//                        // Unknown frames are errors.
//                        return
//                    }
//                }
            }

//            group.addTask {
//                // This is our main business logic where we are just sending the current time
//                // every second.
//                while true {
//                    // We can't really check for error here, but it's also not the purpose of the
//                    // example so let's not worry about it.
//                    let theTime = ContinuousClock().now
//                    var buffer = channel.channel.allocator.buffer(capacity: 12)
//                    buffer.writeString("\(theTime)")
//
//                    let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
//
//                    print("Sending time")
//                    try await channel.outbound.write(frame)
//                    try await Task.sleep(for: .seconds(1))
//                }
//            }

            try await group.next()
            group.cancelAll()
        }
    }
    
    internal func closeOnError(channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async {
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
