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

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Client-side networking stack

extension WebSocketActorSystem {
    func createClientManager(to address: ServerAddress) async -> ClientManager {
        let manager = ClientManager(system: self)
        await manager.connect(host: address.host, port: address.port)
        return manager
    }
}
