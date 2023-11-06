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
        
        XCTAssert(ActorIdentity.random(for: Person.self).hasType(for: Person.self))
    }
}
