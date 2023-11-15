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

extension WebSocketActorSystem {
    
    private actor ClientManager: Manager {
        
        enum UpgradeResult {
            case websocket(WebSocketAgentChannel)
            case notUpgraded
        }
        
        private let system: WebSocketActorSystem
        private var task: ResilientTask?
        private var channel: WebSocketAgentChannel?
        private var waitingForChannel: [CheckedContinuation<WebSocketAgentChannel, Error>] = []
        
#if canImport(Network)
        static let group = NIOTSEventLoopGroup.singleton
#else
        static let group = MultiThreadedEventLoopGroup.singleton
#endif
        
        init(system: WebSocketActorSystem) {
            self.system = system
        }
        
        func localPort() async throws -> Int {
            channel?.channel.localAddress?.port ?? 0
        }
        
        func associate(nodeID: NodeIdentity, with channel: WebSocketAgentChannel) {
            // We don't have to do anything, because we only support one remote channel.
        }
        
        func selectChannel(for actorID: ActorIdentity) async throws -> WebSocketAgentChannel {
            // Use a continuation to wait for the channel to be set.
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    resolveChannel(continuation: continuation)
                }
            }
        }
        
        func setChannel(_ channel: WebSocketAgentChannel) {
            self.channel = channel
            for waiter in waitingForChannel {
                waiter.resume(returning: channel)
            }
            waitingForChannel.removeAll()
        }
        
        private func resolveChannel(continuation: CheckedContinuation<WebSocketAgentChannel, Error>) {
            if let channel {
                continuation.resume(returning: channel)
            } else {
                waitingForChannel.append(continuation)
            }
        }
        
        func connect(host: String, port: Int) {
            cancel()
            task = ResilientTask() { initialized in
                let channel = try await Self.openClientChannel(host: host, port: port)
                self.setChannel(channel)
                await initialized()
                try await self.system.dispatchIncomingFrames(channel: channel)
            }
        }
        
        func cancel() {
            task?.cancel()
            task = nil
        }
        
        private static func openClientChannel(host: String, port: Int) async throws -> WebSocketAgentChannel {
            let bootstrap = PlatformBootstrap(group: ClientManager.group)
            let upgradeResult = try await bootstrap.connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult> { channel, responseHead in
                        return channel.eventLoop.makeCompletedFuture {
                            let asyncChannel = try WebSocketAgentChannel(synchronouslyWrapping: channel)
                            return UpgradeResult.websocket(asyncChannel)
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
    
    internal func createClientManager(host: String, port: Int) async -> Manager {
        let manager = ClientManager(system: self)
        await manager.connect(host: host, port: port)
        return manager
    }
}
