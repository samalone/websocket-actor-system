//
//  Continuation.swift
//
//
//  Created by Stuart A. Malone on 11/29/23.
//

import Foundation

// Used checked continuations for safety in debug mode,
// and unsafe continuations for speed in release mode.

#if DEBUG
    typealias Continuation = CheckedContinuation

    @inlinable func withContinuation<T>(function: String = #function,
                                        _ body: (CheckedContinuation<T, Never>) -> Void) async -> T
    {
        await withCheckedContinuation(function: function, body)
    }

    @inlinable func withThrowingContinuation<T>(function: String = #function,
                                                _ body: (CheckedContinuation<T, Error>) -> Void) async throws -> T
    {
        try await withCheckedThrowingContinuation(function: function, body)
    }
#else
    typealias Continuation = UnsafeContinuation

    @inlinable func withContinuation<T>(function: String = #function,
                                        _ body: (UnsafeContinuation<T, Never>) -> Void) async -> T
    {
        await withUnsafeContinuation(function: function, body)
    }

    @inlinable func withThrowingContinuation<T>(function: String = #function,
                                                _ body: (UnsafeContinuation<T, Error>) -> Void) async throws -> T
    {
        try await withUnsafeThrowingContinuation(function: function, body)
    }
#endif

/// A Continuation with a timeout. The continuation will either resume with
/// the value passed to `resume(returning:)`, or with the provided
/// error after the timeout expires.
actor TimedContinuation<T: Sendable> {
    var continuation: Continuation<T, Error>?
    var timeoutTask: Task<Void, Error>?

    init(continuation: Continuation<T, Error>,
         error timeoutError: Error,
         timeout: Duration,
         tolerance: Duration? = nil) async {
        self.continuation = continuation
        timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout, tolerance: tolerance)
                self.resume(throwing: timeoutError)
            }
            catch {
                self.resume(throwing: error)
            }
        }
    }

    private func cancelTimeout() {
        guard let timeoutTask else { return }
        timeoutTask.cancel()
        self.timeoutTask = nil
    }

    func resume(throwing error: Error) {
        guard let continuation else { return }
        continuation.resume(throwing: error)
        self.continuation = nil
        cancelTimeout()
    }

    func resume(returning value: T) {
        guard let continuation else { return }
        continuation.resume(returning: value)
        self.continuation = nil
        cancelTimeout()
    }
}
