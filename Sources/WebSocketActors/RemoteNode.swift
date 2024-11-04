//
//  RemoteNode.swift
//
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation
import NIO
import NIOAsyncWebSockets
import NIOWebSocket

final actor RemoteNode {
    let nodeID: NodeIdentity
    let channel: WebSocketAgentChannel
    let inbound: NIOAsyncChannelInboundStream<WebSocketFrame>
    let outbound: WebSocketOutbound
    var userInfo: [ActorSystemUserInfoKey: any Sendable] = [:]

    @TaskLocal static var current: RemoteNode?

    static func withRemoteNode(nodeID: NodeIdentity, channel: WebSocketAgentChannel,
                               block: (RemoteNode) async throws -> Void) async throws
    {
        try await channel.executeThenClose { inbound, outbound in
            let remote = RemoteNode(nodeID: nodeID, channel: channel, inbound: inbound, outbound: outbound)
            try await $current.withValue(remote) {
                try await block(remote)
            }
        }
    }

    private init(nodeID: NodeIdentity,
                 channel: WebSocketAgentChannel,
                 inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
                 outbound: WebSocketOutbound)
    {
        self.nodeID = nodeID
        self.channel = channel
        self.inbound = inbound
        self.outbound = outbound
    }

    func write(actorSystem: WebSocketActorSystem, envelope: WebSocketWireEnvelope) async throws {
        switch envelope {
        case .connectionClose:
            var data = channel.channel.allocator.buffer(capacity: 2)
            data.write(webSocketErrorCode: .protocolError)
            let frame = WebSocketFrame(fin: true,
                                       opcode: .connectionClose,
                                       data: data)
            try await outbound.write(frame)
        case .reply, .call:
            let encoder = JSONEncoder()
            encoder.userInfo[.actorSystemKey] = actorSystem

            var data = ByteBuffer()
            try data.writeJSONEncodable(envelope, encoder: encoder)

            let frame = WebSocketFrame(fin: true, opcode: .text, data: data)
            try await outbound.write(frame)
        }
    }

    func ping() async throws {
        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: channel.channel.allocator.buffer(capacity: 0))
        try await outbound.write(pingFrame)
    }

    func getUserInfo(key: ActorSystemUserInfoKey) -> (any Sendable)? {
        userInfo[key]
    }

    func setUserInfo(key: ActorSystemUserInfoKey, value: any Sendable) {
        userInfo[key] = value
    }
}
