//
//  ResilientChannel.swift
//
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation
import NIO
import Logging

actor ResilientChannel {
    typealias Factory = () async throws -> Channel
    
    private var _channel: Channel? = nil
    private var group: EventLoopGroup
    private var factory: Factory
    private let logger: Logger
    private let backoff: ExponentialBackoff
    
    init(group: EventLoopGroup,
         logger: Logger = Logger(label: "ResilientChannel"),
         backoff: ExponentialBackoff = .standard,
         _ factory: @escaping Factory) {
        self.group = group
        self.factory = factory
        self.logger = logger
        self.backoff = backoff
    }
    
    public var channel: Channel {
        get async throws {
            if let channel = _channel {
                return channel
            }
            
            for delay in backoff {
                do {
                    let channel = try await factory()
                    channel.closeFuture.whenComplete { _ in
                        Task {
                            await self.channelClosed(channel)
                        }
                    }
                    _channel = channel
                    return channel
                }
                catch {
                    logger.error("failed to connect: \(error), waiting \(delay) seconds")
                    try await Task.sleep(for: .seconds(delay))
                }
            }
            fatalError("infinite backoff exceeded!")
        }
    }
    
    private func channelClosed(_ oldChannel: Channel) {
        guard _channel === oldChannel else { return }
        _channel = nil
    }
    
    public func writeAndFlush<T>(_ any: T) async throws {
        let channel = try await self.channel
        try await channel.writeAndFlush(any)
    }
    
    public func write<T>(_ any: T) async throws {
        let channel = try await self.channel
        try await channel.write(any).get()
    }
    
    
}

class ExponentialBackoff: Sequence {
    private let minDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let jitter: TimeInterval
    private let growth: Double
    
    init(minDelay: TimeInterval = 0.5,
         maxDelay: TimeInterval = 30.0,
         jitter: TimeInterval = 0.5,
         growth: Double = 1.6180339) {
        self.minDelay = minDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.growth = growth
    }
    
    struct Iterator: IteratorProtocol {
        let backoff: ExponentialBackoff
        var delay: TimeInterval
        
        init(backoff: ExponentialBackoff) {
            self.backoff = backoff
            let j = backoff.jitter / 2
            self.delay = backoff.minDelay + Double.random(in: -j ... j)
        }
        
        mutating func next() -> TimeInterval? {
            let t = delay
            let j = backoff.jitter / 2
            delay = Swift.min(delay * backoff.growth, backoff.maxDelay) + Double.random(in: -j ... j)
            return t
        }
    }
    
    func makeIterator() -> Iterator {
        Iterator(backoff: self)
    }
    
    static let standard = ExponentialBackoff()
}
