//
//  TimedPing.swift
//
//
//  Created by Stuart A. Malone on 11/22/23.
//

import Foundation

/// A timer that repeatedly pings a remote node.
///
/// > Note: The pings occur at fixed intervals regardless
/// > of other network traffic to the same node. A future
/// > enhancement would be to delay future pings when
/// > data is received from the remote.
class TimedPing {
    weak var node: RemoteNode?
    let frequency: TimeInterval
    var loop: Task<Void, Error>?

    init(node: RemoteNode, frequency: TimeInterval) {
        self.node = node
        self.frequency = frequency
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        loop = Task.detached {
            while !(Task.isCancelled || (self.node == nil)) {
                try await Task.sleep(for: .seconds(self.frequency))
                if Task.isCancelled { break }
                if self.node == nil { break }
                try? await self.node?.ping()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}
