//
//  File.swift
//  
//
//  Created by Stuart A. Malone on 11/9/23.
//

import Foundation
import NIOCore
import NIOHTTP1

// MARK: - Client pipeline configuration
/// Configuration for an upgradable HTTP pipeline.
public struct NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult: Sendable> {
    /// The strategy to use when dealing with leftover bytes after removing the ``HTTPDecoder`` from the pipeline.
    public var leftOverBytesStrategy = RemoveAfterUpgradeStrategy.dropBytes

    /// Whether to validate outbound response headers to confirm that they are
    /// spec compliant. Defaults to `true`.
    public var enableOutboundHeaderValidation = true

    /// The configuration for the ``HTTPRequestEncoder``.
    public var encoderConfiguration = HTTPRequestEncoder.Configuration()

    /// The configuration for the ``NIOTypedHTTPClientUpgradeHandler``.
    public var upgradeConfiguration: NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>

    /// Initializes a new ``NIOUpgradableHTTPClientPipelineConfiguration`` with default values.
    ///
    /// The current defaults provide the following features:
    /// 1. Outbound header fields validation to protect against response splitting attacks.
    public init(
        upgradeConfiguration: NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>
    ) {
        self.upgradeConfiguration = upgradeConfiguration
    }
}

extension ChannelPipeline {
    /// Configure a `ChannelPipeline` for use as an HTTP client.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured. The future contains an `EventLoopFuture`
    /// that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    public func configureUpgradableHTTPClientPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult>
    ) -> EventLoopFuture<EventLoopFuture<UpgradeResult>> {
        self._configureUpgradableHTTPClientPipeline(configuration: configuration)
    }

    private func _configureUpgradableHTTPClientPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult>
    ) -> EventLoopFuture<EventLoopFuture<UpgradeResult>> {
        let future: EventLoopFuture<EventLoopFuture<UpgradeResult>>

        if self.eventLoop.inEventLoop {
            let result = Result<EventLoopFuture<UpgradeResult>, Error> {
                try self.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: configuration
                )
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                try self.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: configuration
                )
            }
        }

        return future
    }
}

extension ChannelPipeline.SynchronousOperations {
    /// Configure a `ChannelPipeline` for use as an HTTP client.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    public func configureUpgradableHTTPClientPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult>
    ) throws -> EventLoopFuture<UpgradeResult> {
        self.eventLoop.assertInEventLoop()

        let requestEncoder = HTTPRequestEncoder(configuration: configuration.encoderConfiguration)
        let responseDecoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: configuration.leftOverBytesStrategy))
        var httpHandlers = [RemovableChannelHandler]()
        httpHandlers.reserveCapacity(3)
        httpHandlers.append(requestEncoder)
        httpHandlers.append(responseDecoder)

        try self.addHandler(requestEncoder)
        try self.addHandler(responseDecoder)

        if configuration.enableOutboundHeaderValidation {
            let headerValidationHandler = NIOHTTPRequestHeadersValidator()
            try self.addHandler(headerValidationHandler)
            httpHandlers.append(headerValidationHandler)
        }

        let upgrader = NIOTypedHTTPClientUpgradeHandler(
            httpHandlers: httpHandlers,
            upgradeConfiguration: configuration.upgradeConfiguration
        )
        try self.addHandler(upgrader)

        return upgrader.upgradeResultFuture
    }
}
