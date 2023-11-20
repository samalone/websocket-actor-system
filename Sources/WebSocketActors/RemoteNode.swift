//
//  RemoteNodeConnection.swift
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
    
    @TaskLocal static var current: RemoteNode? = nil
    
    static func withRemoteNode(nodeID: NodeIdentity, channel: WebSocketAgentChannel, block: (RemoteNode) async throws -> Void) async throws {
        try await channel.executeThenClose { inbound, outbound in
            let remote = RemoteNode(nodeID: nodeID, channel: channel, inbound: inbound, outbound: outbound)
            print("scoping remote node on \(TaskPath.current)")
            try await RemoteNode.$current.withValue(remote) {
                try await block(remote)
            }
        }
    }
    
    private init(nodeID: NodeIdentity,
                 channel: WebSocketAgentChannel,
                 inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
                 outbound: WebSocketOutbound) {
        self.nodeID = nodeID
        self.channel = channel
        self.inbound = inbound
        self.outbound = outbound
    }
    
//    private func handleIncomingFrames() async throws {
//        try await RemoteNode.$current.withValue(self) {
//            for try await frame in inbound {
//                switch frame.opcode {
//                case .connectionClose:
//                    // Close the connection.
//                    //
//                    // We might also want to inform the actor system that this connection
//                    // went away, so it can terminate any tasks or actors working to
//                    // inform the remote receptionist on the now-gone system about our
//                    // actors.
//                    
//                    // This is an unsolicited close. We're going to send a response frame and
//                    // then, when we've sent it, close up shop. We should send back the close code the remote
//                    // peer sent us, unless they didn't send one at all.
//                    actorSystem.logger.trace("Received close")
//                    var data = frame.unmaskedData
//                    let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
//                    let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
//                    try await outbound.write(closeFrame)
//                    
//                case .text:
//                    var data = frame.unmaskedData
//                    let text = data.getString(at: 0, length: data.readableBytes) ?? ""
//                    actorSystem.logger.withOp().trace("Received: \(text), from: \(String(describing: channel.channel.remoteAddress))")
//                    
//                    await actorSystem.decodeAndDeliver(data: &data, from: channel.channel.remoteAddress,
//                                                       on: channel)
//                
//                case .ping:
//                    actorSystem.logger.trace("Received ping")
//                    var frameData = frame.data
//                    let maskingKey = frame.maskKey
//                    
//                    if let maskingKey = maskingKey {
//                        frameData.webSocketUnmask(maskingKey)
//                    }
//                    
//                    let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
//                    try await outbound.write(responseFrame)
//                    
//                case .binary, .continuation, .pong:
//                    // We ignore these frames.
//                    break
//                default:
//                    // Unknown frames are errors.
//                    await actorSystem.closeOnError(channel: channel)
//                }
//            }
//        }
//    }
    
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
            encoder.userInfo[.remoteNodeKey] = self

            var data = ByteBuffer()
            try data.writeJSONEncodable(envelope, encoder: encoder)

            let frame = WebSocketFrame(fin: true, opcode: .text, data: data)
            try await outbound.write(frame)
        }
    }
}
