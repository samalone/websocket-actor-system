//
//  ServerManager.swift
//  
//
//  Created by Stuart A. Malone on 11/28/23.
//

import Distributed
import Foundation
import NIO
import NIOAsyncWebSockets
import NIOHTTP1
import NIOWebSocket

public final actor ServerManager: Manager {
    private let system: WebSocketActorSystem
    private let originalAddress: ServerAddress
    private var _task: ResilientTask?
    private var _channel: ServerListeningChannel?
    private var waitingForChannel: [Continuation<ServerListeningChannel, Never>] = []

    enum Status {
        case current(RemoteNode)
        case future([Continuation<RemoteNode, Never>])
    }

    init(system: WebSocketActorSystem, on address: ServerAddress) {
        self.system = system
        self.originalAddress = address
    }
    
    /// Return the local port number. For the server, this is the port it is listening on.
    /// For a client, this is the (less important) local port number it is connecting from.
    ///
    /// - Note: Even for a server, the`localPort()` is only needed
    /// when the server was created on port 0, which uses a system-assigned port.
    /// This is normally the case only when writing tests. In production, the server
    /// is usually created on a fixed port number and calls to `localPort()` are not needed.
    public func localPort() async throws -> Int {
        let chan = try await requireChannel()
        return chan.channel.localAddress?.port ?? 0
    }
    
    public func address() async throws -> ServerAddress {
        try await originalAddress.with(port: localPort())
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
            await withContinuation { continuation in
                waitingForChannel.append(continuation)
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

                let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
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
