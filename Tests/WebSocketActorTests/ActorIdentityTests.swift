//
//  ActorIdentityTests.swift
//  
//
//  Created by Stuart A. Malone on 11/2/23.
//

import XCTest
@testable import WebSocketActors

final class ActorIdentityTests: XCTestCase {

    func testActorIdentitySyntax() throws {
        XCTAssertEqual(ActorIdentity(id: "foo"), ActorIdentity(id: "foo"))
        
        XCTAssertNotEqual(ActorIdentity.random(), ActorIdentity.random())
        
        XCTAssert(ActorIdentity.random(for: Alice.self).id.starts(with: "Alice/"))
        XCTAssert(ActorIdentity.random(for: Bob.self).id.starts(with: "Bob/"))
        
        XCTAssert(ActorIdentity.random(for: Alice.self).hasPrefix(for: Alice.self))
        XCTAssert(ActorIdentity.random(for: Bob.self).hasPrefix(for: Bob.self))
    }
}
