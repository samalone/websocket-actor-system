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
        case future([Continuation<RemoteNode, Never>])
    }

    private var remoteNodes: [NodeIdentity: Status] = [:]
    private var firstNode: [Continuation<RemoteNode, Never>] = []

    func remoteNode(for actorID: ActorIdentity) async throws -> RemoteNode {
        if let nodeID = actorID.node {
            return await requireRemoteNode(nodeID: nodeID)
        }
        else if remoteNodes.count == 1 {
            return await requireRemoteNode(nodeID: remoteNodes.first!.key)
        }
        else if remoteNodes.isEmpty {
            return await waitForFirstNode()
        }
        else {
            // If there are multiple remote nodes, and the actor isn't tagged
            // with which one it is from, we have to give up.
            throw WebSocketActorSystemError.missingNodeID(id: actorID)
        }
    }

    func waitForFirstNode() async -> RemoteNode {
        await withCheckedContinuation { continuation in
            Task {
                firstNode.append(continuation)
            }
        }
    }

    func requireRemoteNode(nodeID: NodeIdentity) async -> RemoteNode {
        if let status = remoteNodes[nodeID] {
            switch status {
            case .current(let node):
                node
            case .future(let continuations):
                await withContinuation { continuation in
                    Task {
                        remoteNodes[nodeID] = .future(continuations + [continuation])
                    }
                }
            }
        }
        else {
            await withContinuation { continuation in
                Task {
                    remoteNodes[nodeID] = .future([continuation])
                }
            }
        }
    }

    func opened(remote: RemoteNode) {
        let nodeID = remote.nodeID
        if let status = remoteNodes[nodeID], case .future(let continuations) = status {
            remoteNodes[nodeID] = .current(remote)
            for continuation in continuations {
                continuation.resume(returning: remote)
            }
        }
        else {
            remoteNodes[nodeID] = .current(remote)
        }
        for continuation in firstNode {
            continuation.resume(returning: remote)
        }
        firstNode = []
    }

    func closing(remote: RemoteNode) {
        remoteNodes.removeValue(forKey: remote.nodeID)
    }
}
