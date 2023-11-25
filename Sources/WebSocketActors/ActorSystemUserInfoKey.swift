//
//  ActorSystemUserInfoKey.swift
//
//
//  Created by Stuart Malone on 11/23/23.
//

import Foundation

/// A user-defined key for providing context during encoding and decoding.
public struct ActorSystemUserInfoKey: RawRepresentable, Equatable, Hashable, Sendable {
    /// The raw type that can be used to represent all values of the conforming
    /// type.
    ///
    /// Every distinct value of the conforming type has a corresponding unique
    /// value of the `RawValue` type, but there may be values of the `RawValue`
    /// type that don't have a corresponding value of the conforming type.
    public typealias RawValue = String
    
    /// The key's string value.
    public let rawValue: String
    
    /// Creates a new instance with the given raw value.
    ///
    /// - parameter rawValue: The value of the key.
    public init?(rawValue: String) {
        self.rawValue = rawValue
    }
    
    /// Returns a Boolean value indicating whether the given keys are equal.
    ///
    /// - parameter lhs: The key to compare against.
    /// - parameter rhs: The key to compare with.
    public static func == (lhs: ActorSystemUserInfoKey, rhs: ActorSystemUserInfoKey) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
    
    /// Hashes the essential components of this value by feeding them into the
    /// given hasher.
    ///
    /// - Parameter hasher: The hasher to use when combining the components
    ///   of this instance.
    public func hash(into hasher: inout Hasher) {
        rawValue.hash(into: &hasher)
    }
}
