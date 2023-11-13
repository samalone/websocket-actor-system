//
//  File.swift
//  
//
//  Created by Stuart A. Malone on 11/9/23.
//

import Foundation
import Logging

internal actor PendingReplies {
    typealias CallID = UUID
    
    private var callContinuations: Dictionary<UUID, CheckedContinuation<Data, Error>> = [:]
    
    func expectReply(continuation: CheckedContinuation<Data, Error>) -> UUID {
        let callID = UUID()
        callContinuations[callID] = continuation
        return callID
    }
    
    func receivedReply(callID: UUID, data: Data) throws {
        guard let continuation = callContinuations.removeValue(forKey: callID) else {
            throw WebSocketActorSystemError.missingReplyContinuation(callID: callID)
        }
        continuation.resume(returning: data)
    }
    
    func receivedError(callID: UUID, error: Error) throws {
        guard let continuation = callContinuations.removeValue(forKey: callID) else {
            throw WebSocketActorSystemError.missingReplyContinuation(callID: callID)
        }
        continuation.resume(throwing: error)
    }
    
    nonisolated func sendMessage(_ body: @escaping (CallID) async throws -> Void) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let callID = await self.expectReply(continuation: continuation)
                do {
                    try await body(callID)
                }
                catch {
                    try await self.receivedError(callID: callID, error: error)
                }
            }
        }
    }
}
