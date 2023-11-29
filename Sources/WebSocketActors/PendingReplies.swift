//
//  PendingReplies.swift
//
//
//  Created by Stuart A. Malone on 11/9/23.
//

import Foundation
import Logging

actor PendingReplies {
    private var callContinuations: [CallID: Continuation<Data, Error>] = [:]

    func expectReply(continuation: Continuation<Data, Error>) -> UUID {
        let callID = UUID()
        callContinuations[callID] = continuation
        return callID
    }

    func receivedReply(callID: CallID, data: Data) throws {
        guard let continuation = callContinuations.removeValue(forKey: callID) else {
            throw WebSocketActorSystemError.missingReplyContinuation(callID: callID)
        }
        continuation.resume(returning: data)
    }

    func receivedError(callID: CallID, error: Error) throws {
        guard let continuation = callContinuations.removeValue(forKey: callID) else {
            throw WebSocketActorSystemError.missingReplyContinuation(callID: callID)
        }
        continuation.resume(throwing: error)
    }

    nonisolated func sendMessage(_ body: @escaping (CallID) async throws -> Void) async throws -> Data {
        try await withThrowingContinuation { continuation in
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
