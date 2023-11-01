/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Client side implementation of the WebSocket Actor System.
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

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Client-side networking stack

@available(iOS 16.0, *)
extension WebSocketActorSystem {
    func startClient(host: String, port: Int) throws -> Channel {
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            // Enable SO_REUSEADDR.
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in

                    let httpHandler = HTTPInitialRequestHandler(target: .init(host: host, port: port))

                    let websocketUpgrader = NIOWebSocketClientUpgrader(
                        requestKey: "OfS0wDaT5NoxF2gqm7Zj2YtetzM=",
                        upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                            channel.pipeline.addHandlers(
                                WebSocketMessageOutboundHandler(actorSystem: self),
                                WebSocketActorMessageInboundHandler(actorSystem: self)
                                // WebSocketActorReplyHandler(actorSystem: self)
                            )
                        })

                    let config: NIOHTTPClientUpgradeConfiguration = (
                        upgraders: [websocketUpgrader],
                        completionHandler: { _ in
                            channel.pipeline.removeHandler(httpHandler, promise: nil)
                        })

                    return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
                }

        let channel = try bootstrap.connect(host: host, port: port).wait()

        return channel
    }
}
