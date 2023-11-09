/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Client side implementation of the WebSocket Actor System.
*/

import Distributed
import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
import NIOFoundationCompat

#if canImport(Network)
    import NIOTransportServices
    typealias PlatformBootstrap = NIOTSConnectionBootstrap
#else
    import NIOPosix
    typealias PlatformBootstrap = ClientBootstrap
#endif

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Client-side networking stack

@available(iOS 16.0, *)
extension WebSocketActorSystem {
    
    enum UpgradeResult {
        case websocket(Channel)
        case notUpgraded
    }
    
    func startClient(host: String, port: Int) async throws -> Channel {
        let bootstrap = PlatformBootstrap(group: group)
        let upgradeResult = try await bootstrap.connect(host: host, port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult> { channel, responseHead in
                    channel.pipeline.addHandlers(
                        WebSocketMessageOutboundHandler(actorSystem: self),
                        WebSocketActorMessageInboundHandler(actorSystem: self)
                        // WebSocketActorReplyHandler(actorSystem: self)
                    ).map {
                        UpgradeResult.websocket(channel)
                    }
                }
                
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
                headers.add(name: "Content-Length", value: "0")
                
                let requestHead = HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/",
                    headers: headers
                )
                
                let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: requestHead,
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            return UpgradeResult.notUpgraded
                        }
                    }
                )
                
                let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
                )
                
                return negotiationResultFuture
            }
        }
        
        switch try await upgradeResult.get() {
        case .websocket(let channel):
            return channel
        case .notUpgraded:
            throw WebSocketActorSystemError.failedToUpgrade
        }
    }
}
