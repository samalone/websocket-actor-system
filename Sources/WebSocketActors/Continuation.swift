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
