//
//  ExponentialBackoff.swift
//  
//
//  Created by Stuart A. Malone on 11/14/23.
//

import Foundation

extension Double {
    /// The [golden ratio](https://en.wikipedia.org/wiki/Golden_ratio).
    public static let phi = 1.6180339887498948482
}

/// Provides a slightly randomized infinite sequence of exponentially growing numbers.
/// `ExponentialBackoff` is used internally by the WebSocketActorSystem
/// to time client reconnects after errors, but is public so it can be used elsewhere.
///
/// > Note: See [Exponential backoff](https://en.wikipedia.org/wiki/Exponential_backoff). (2023, September 23). In Wikipedia.
public struct ExponentialBackoff: Sequence {
    
    /// The first value in the sequence. If this is >= ``jitter``, then the
    /// first value will be randomized with jitter.
    public var initialDelay: TimeInterval
    
    /// The minimum value in the sequence after the first value. If `initialDelay` is zero,
    /// this will be the second value in the sequence (adjusted by jitter).
    public var minDelay: TimeInterval
    
    /// The maximum value appearing in the sequence (adjusted by jitter).
    public var maxDelay: TimeInterval
    
    /// An amount to randomize each value in the sequence. Each value will be
    /// adjusted by plus or minus the `jitter`.
    public var jitter: TimeInterval
    
    /// The exponential growth factor from one value in the sequence to the next.
    public var growth: Double
    
    public init(initialDelay: TimeInterval = 0.0,
                minDelay: TimeInterval = 0.5,
                maxDelay: TimeInterval = 30.0,
                jitter: TimeInterval = 0.25,
                growth: Double = .phi) {
        precondition(initialDelay >= 0)
        precondition(minDelay > 0)
        precondition(minDelay <= maxDelay)
        precondition(jitter <= minDelay)
        precondition(growth > 0)
        
        self.initialDelay = initialDelay
        self.minDelay = minDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.growth = growth
    }
    
    public struct Iterator: IteratorProtocol {
        let backoff: ExponentialBackoff
        var delay: TimeInterval
        
        init(backoff: ExponentialBackoff) {
            self.backoff = backoff
            if backoff.initialDelay >= backoff.jitter {
                self.delay = backoff.initialDelay + Double.random(in: -backoff.jitter ... backoff.jitter)
            }
            else {
                self.delay = backoff.initialDelay
            }
        }
        
        public mutating func next() -> TimeInterval? {
            let t = delay
            delay = Swift.min(Swift.max(delay * backoff.growth, backoff.minDelay), backoff.maxDelay) + Double.random(in: -backoff.jitter ... backoff.jitter)
            return t
        }
    }
    
    public func makeIterator() -> Iterator {
        Iterator(backoff: self)
    }
    
    public static let standard = ExponentialBackoff()
}
