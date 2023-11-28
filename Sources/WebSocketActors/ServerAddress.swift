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

    public init?(url: URL) {
        guard let comp = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let host = comp.host
        else {
            return nil
        }
        switch comp.scheme {
        case "http", "ws":
            self.scheme = .insecure
        case "https", "wss":
            self.scheme = .secure
        default:
            return nil
        }
        self.host = host
        self.port = comp.port ?? scheme.port
        self.path = comp.path.isEmpty ? "/" : comp.path
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    func with(port: Int) -> ServerAddress {
        var address = self
        address.port = port
        return address
    }
}

extension ServerAddress: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        guard let address = ServerAddress(string: value) else {
            fatalError("Invalid ServerAddress URL: \(value)")
        }
        self = address
    }
}

extension ServerAddress: CustomStringConvertible {
    public var description: String {
        "\(scheme.socketScheme)://\(host):\(port)\(path)"
    }
}
