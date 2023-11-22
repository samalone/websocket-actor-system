//
//  RemoteNode.swift
//
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation
import NIO
import NIOWebSocket

final class RemoteNode {
    let nodeID: NodeIdentity
    let channel: WebSocketAgentChannel
    let inbound: NIOAsyncChannelInboundStream<WebSocketFrame>
    let outbound: WebSocketOutbound

    static func withRemoteNode(nodeID: NodeIdentity, channel: WebSocketAgentChannel,
                               block: (RemoteNode) async throws -> Void) async throws
    {
        try await channel.executeThenClose { inbound, outbound in
            let remote = RemoteNode(nodeID: nodeID, channel: channel, inbound: inbound, outbound: outbound)
            try await block(remote)
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
}
