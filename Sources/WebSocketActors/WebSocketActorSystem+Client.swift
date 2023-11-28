/*
 See LICENSE folder for this sample’s licensing information.

 Abstract:
 Client side implementation of the WebSocket Actor System.
 */

import Distributed
import Foundation
import NIO
import NIOAsyncWebSockets
import NIOFoundationCompat
import NIOHTTP1
import NIOWebSocket

#if canImport(Network)
    import NIOTransportServices
    typealias PlatformBootstrap = NIOTSConnectionBootstrap
#else
    import NIOPosix
    typealias PlatformBootstrap = ClientBootstrap
#endif

extension HTTPHeaders {
    static let nodeIdKey = "ActorSystemNodeID"

    var nodeID: NodeIdentity? {
        get {
            guard let id = self[HTTPHeaders.nodeIdKey].first else { return nil }
            return NodeIdentity(id: id)
        }
        set {
            if let newValue {
                replaceOrAdd(name: HTTPHeaders.nodeIdKey, value: newValue.id)
            }
            else {
                remove(name: HTTPHeaders.nodeIdKey)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Client-side networking stack

extension WebSocketActorSystem {
    private actor ClientManager: Manager {
        enum UpgradeResult {
            case websocket(ServerConnection)
            case notUpgraded
        }

        private let system: WebSocketActorSystem
        private var task: ResilientTask?
        private var remoteNode: RemoteNode?
        private var waitingForRemoteNode: [CheckedContinuation<RemoteNode, Never>] = []
        private var pinger: TimedPing?

        #if canImport(Network)
            static let group = NIOTSEventLoopGroup.singleton
        #else
            static let group = MultiThreadedEventLoopGroup.singleton
        #endif

        struct ServerConnection {
            var channel: WebSocketAgentChannel
            var nodeID: NodeIdentity
        }

        init(system: WebSocketActorSystem) {
            self.system = system
        }

        func localPort() async throws -> Int {
            remoteNode?.channel.channel.localAddress?.port ?? 0
        }

        func updateConnectionStatus(_ status: ResilientTask.Status) {
            // We _must_ call the monitor in a separate task, or there will be
            // deadlock of the monitor tries to make a distributed actor call.
            Task {
                await system.monitor?(status)
            }
        }

        func connect(host: String, port: Int) {
            cancel()
            task = ResilientTask(monitor: updateConnectionStatus(_:)) { initialized in
                try await TaskPath.with(name: "client connection") {
                    let serverConnection = try await self.openClientChannel(host: host, port: port)
                    self.system.logger
                        .trace("got serverConnection to node \(serverConnection.nodeID) on \(TaskPath.current)")
                    await initialized()
                    try await self.system.dispatchIncomingFrames(channel: serverConnection.channel,
                                                                 remoteNodeID: serverConnection.nodeID)
                }
            }
        }

        func opened(remote: RemoteNode) async {
            remoteNode = remote
            for continuation in waitingForRemoteNode {
                continuation.resume(returning: remote)
            }
            waitingForRemoteNode = []
            let ping = TimedPing(node: remote, frequency: 10)
            ping.start()
            pinger = ping
        }

        func closing(remote _: RemoteNode) async {
            pinger?.stop()
            pinger = nil
            remoteNode = nil
        }

        func remoteNode(for _: ActorIdentity) async throws -> RemoteNode {
            if let remoteNode {
                remoteNode
            }
            else {
                await withCheckedContinuation { continuation in
                    Task {
                        waitingForRemoteNode.append(continuation)
                    }
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }

        private func openClientChannel(host: String, port: Int) async throws -> ServerConnection {
            let bootstrap = PlatformBootstrap(group: ClientManager.group)
            let upgradeResult = try await bootstrap.connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOAsyncWebSockets
                        .NIOTypedWebSocketClientUpgrader<UpgradeResult> { channel, responseHead in
                            self.system.logger.trace("upgrading client channel to server on \(TaskPath.current)")
                            self.system.logger.trace("responseHead = \(responseHead)")
                            return channel.eventLoop.makeCompletedFuture {
                                let asyncChannel = try WebSocketAgentChannel(wrappingChannelSynchronously: channel)
                                guard let serverNodeID = responseHead.headers.nodeID else {
                                    return UpgradeResult.notUpgraded
                                }
                                return UpgradeResult.websocket(ServerConnection(channel: asyncChannel,
                                                                                nodeID: serverNodeID))
                            }
                        }

                    var headers = HTTPHeaders()
                    headers.nodeID = self.system.nodeID
                    headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
                    headers.add(name: "Content-Length", value: "0")

                    let requestHead = HTTPRequestHead(version: .http1_1,
                                                      method: .GET,
                                                      uri: "/",
                                                      headers: headers)

                    let clientUpgradeConfiguration =
                        NIOTypedHTTPClientUpgradeConfiguration(upgradeRequestHead: requestHead,
                                                               upgraders: [upgrader],
                                                               notUpgradingCompletionHandler: { channel in
                                                                   channel.eventLoop
                                                                       .makeCompletedFuture {
                                                                           UpgradeResult
                                                                               .notUpgraded
                                                                       }
                                                               })

                    let negotiationResultFuture = try channel.pipeline.syncOperations
                        .configureUpgradableHTTPClientPipeline(
                            configuration: .init(upgradeConfiguration: clientUpgradeConfiguration))

                    return negotiationResultFuture
                }
            }

            switch try await upgradeResult.get() {
            case .websocket(let serverConnection):
                return serverConnection
            case .notUpgraded:
                throw WebSocketActorSystemError.failedToUpgrade
            }
        }
    }

    func createClientManager(to address: ServerAddress) async -> Manager {
        let manager = ClientManager(system: self)
        await manager.connect(host: address.host, port: address.port)
        return manager
    }
}
