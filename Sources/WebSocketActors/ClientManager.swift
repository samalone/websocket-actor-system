//
//  ClientManager.swift
//
//
//  Created by Stuart A. Malone on 11/28/23.
//

import NIOAsyncWebSockets
import NIOHTTP1

#if canImport(Network)
    import NIOTransportServices
    typealias PlatformBootstrap = NIOTSConnectionBootstrap
#else
    import NIOPosix
    typealias PlatformBootstrap = ClientBootstrap
#endif

public final actor ClientManager: Manager {
    enum UpgradeResult {
        case websocket(ServerConnection)
        case notUpgraded
    }

    private let system: WebSocketActorSystem
    private var task: ResilientTask?
    private var pinger: TimedPing?

    private var remoteNodeID: NodeIdentity?
    private var remoteNodeIDContinuations: [Continuation<NodeIdentity, Never>] = []

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

    public func cancel() {
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
            setRemoteNodeID(serverConnection.nodeID)
            return serverConnection
        case .notUpgraded:
            throw WebSocketActorSystemError.failedToUpgrade
        }
    }

    func setRemoteNodeID(_ remoteNodeID: NodeIdentity) {
        self.remoteNodeID = remoteNodeID
        for continuation in remoteNodeIDContinuations {
            continuation.resume(returning: remoteNodeID)
        }
        remoteNodeIDContinuations.removeAll()
    }

    public func getRemoteNodeID() async throws -> NodeIdentity {
        if let remoteNodeID = remoteNodeID {
            return remoteNodeID
        }
        return await withContinuation { continuation in
            remoteNodeIDContinuations.append(continuation)
        }
    }
}
