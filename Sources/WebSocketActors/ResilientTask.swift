//
//  ResilientTask.swift
//
//
//  Created by Stuart A. Malone on 11/14/23.
//

import Foundation
import Logging

/// A `ResilientTask` tries to keep an action running continuously.
/// If the action fails or exits, it is restarted after an adjustable delay.
public struct ResilientTask {
    /// A function that the action should call once it is successfully initialized.
    public typealias SuccessfulInitializationCallback = () async -> Void

    /// A function that is called to monitor the status of the `ResilientTask`.
    /// This function is async so the task can be monitored by an actor on the main thread.
    public typealias MonitorFunction = (ResilientTask.Status) async -> Void

    /// The action that is run continuously.
    public typealias Action = (SuccessfulInitializationCallback) async throws -> Void

    /// The status of the `ResilientTask`. This is passed to the `monitor` function.
    public enum Status {
        /// The action has been started, but has not yet called the `initializationSuccessful` callback.
        case initializing

        /// The action has started and called the `initializationSuccessful` callback.
        case running

        /// We are waiting for the next attempt to start the action.
        case waiting(TimeInterval)

        /// The action has been cancelled and will not be restarted.
        case cancelled

        /// The action threw an error and will be restarted.
        case failed(Error)
    }

    private let task: Task<Void, Error>

    /// Create a `ResilientTask` and start the action immediately.
    ///
    /// - Parameter backoff: The settings that control how long to wait between attempts to start the action.
    /// - Parameter monitor: An optional function that is called when the status of the `ResilientTask` changes.
    /// - Parameter action: The action that is run continuously.
    public init(backoff: ExponentialBackoff = .standard,
                monitor: MonitorFunction? = nil,
                action: @escaping Action)
    {
        task = Task.detached {
            var iterator = backoff.makeIterator()
            while !Task.isCancelled {
                do {
                    await monitor?(.initializing)
                    try await action {
                        // The action calls this code once it has initialized successfully.
                        // This resets the exponential backoff and clears the current error.
                        iterator = backoff.makeIterator()
                        await monitor?(.running)
                    }
                }
                catch is CancellationError {
                    await monitor?(.cancelled)
                    break
                }
                catch {
                    await monitor?(.failed(error))
                }

                if Task.isCancelled {
                    await monitor?(.cancelled)
                    break
                }

                if let delay = iterator.next(), delay > 0 {
                    await monitor?(.waiting(delay))
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    /// Cancel the `ResilientTask`. The action will not be restarted.
    public func cancel() {
        task.cancel()
    }

    /// True if the `ResilientTask` has been cancelled.
    public var isCancelled: Bool {
        task.isCancelled
    }
}
