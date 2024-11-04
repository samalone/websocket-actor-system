//
//  RemoteNodeDirectory.swift
//
//
//  Created by Stuart A. Malone on 11/28/23.
//

import Foundation

final actor RemoteNodeDirectory {
    enum Status {
        case current(RemoteNode)
        case future([TimedContinuation<RemoteNode>])
    }

    private var remoteNodes: [NodeIdentity: Status] = [:]
    private var firstNode: [TimedContinuation<RemoteNode>] = []
    private var timeout: Duration
    private var tolerance: Duration
    
    init(timeout: Duration = .seconds(5), tolerance: Duration = .seconds(0.5)) {
        self.timeout = timeout
        self.tolerance = tolerance
    }

    func remoteNode(for actorID: ActorIdentity) async throws -> RemoteNode {
        if let nodeID = actorID.node {
            return try await requireRemoteNode(nodeID: nodeID)
        }
        else if remoteNodes.count == 1 {
            return try await requireRemoteNode(nodeID: remoteNodes.first!.key)
        }
        else if remoteNodes.isEmpty {
            return try await waitForFirstNode()
        }
        else {
            // If there are multiple remote nodes, and the actor isn't tagged
            // with which one it is from, we have to give up.
            throw WebSocketActorSystemError.missingNodeID(id: actorID)
        }
    }

    private func withTimeout(nodeID: NodeIdentity?,
                             action: @Sendable @escaping (TimedContinuation<RemoteNode>) async -> ()) async throws -> RemoteNode
    {
        try await withThrowingContinuation { @Sendable continuation in
            Task {
                let tc = await TimedContinuation(continuation: continuation,
                                                 error: WebSocketActorSystemError.timeoutWaitingForNodeID(id: nodeID, timeout: timeout),
                                                 timeout: timeout,
                                                 tolerance: tolerance)
                await action(tc)
            }
        }
    }

    func waitForFirstNode() async throws -> RemoteNode {
        try await withTimeout(nodeID: nil) { tc in
            await self.queueRemoteNodeContinuation(tc: tc)
        }
    }

    private func queueRemoteNodeContinuation(tc: TimedContinuation<RemoteNode>) {
        firstNode.append(tc)
    }

    private func addContinuation(nodeID: NodeIdentity, continuation: TimedContinuation<RemoteNode>) async {
        if let status = remoteNodes[nodeID] {
            switch status {
            case .current(let node):
                await continuation.resume(returning: node)
            case .future(let continuations):
                remoteNodes[nodeID] = .future(continuations + [continuation])
            }
        }
        else {
            remoteNodes[nodeID] = .future([continuation])
        }
    }

    func requireRemoteNode(nodeID: NodeIdentity) async throws -> RemoteNode {
        if case .current(let node) = remoteNodes[nodeID] {
            node
        }
        else {
            try await withTimeout(nodeID: nodeID) { tc in
                await self.addContinuation(nodeID: nodeID, continuation: tc)
            }
        }
    }

    func opened(remote: RemoteNode) async {
        let nodeID = remote.nodeID
        if let status = remoteNodes[nodeID], case .future(let continuations) = status {
            remoteNodes[nodeID] = .current(remote)
            for continuation in continuations {
                await continuation.resume(returning: remote)
            }
        }
        else {
            remoteNodes[nodeID] = .current(remote)
        }
        for continuation in firstNode {
            await continuation.resume(returning: remote)
        }
        firstNode = []
    }

    func closing(remote: RemoteNode) {
        remoteNodes.removeValue(forKey: remote.nodeID)
    }
}
