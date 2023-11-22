//
//  ServerAddress.swift
//
//
//  Created by Stuart A. Malone on 11/6/23.
//

import Foundation

public enum ServerScheme: Hashable, Sendable, Codable, Equatable {
    case secure
    case insecure

    public var socketScheme: String {
        switch self {
        case .secure:
            "wss"
        case .insecure:
            "ws"
        }
    }

    public var port: Int {
        switch self {
        case .secure:
            443
        case .insecure:
            80
        }
    }

    public var webScheme: String {
        switch self {
        case .secure:
            "https"
        case .insecure:
            "http"
        }
    }
}

public struct ServerAddress: Hashable, Sendable, Codable, Equatable {
    /// Either "ws" for an unencrypted connection, or "wss" for an ecnrypted connection.
    public var scheme: ServerScheme

    /// The IP address or hostname of the remote node.
    public var host: String

    /// The port number of the node. For a server, this can be 0 to assign a port number automatically.
    public var port: Int

    public var path: String

    public init(scheme: ServerScheme,
                host: String = "localhost",
                port: Int = -1,
                path: String = "/")
    {
        self.scheme = scheme
        self.host = host
        self.port = (port < 0) ? scheme.port : port
        self.path = path
    }

    func with(port: Int) -> ServerAddress {
        var address = self
        address.port = port
        return address
    }
}

extension ServerAddress: CustomStringConvertible {
    public var description: String {
        "\(scheme.socketScheme)://\(host):\(port)\(path)"
    }
}
