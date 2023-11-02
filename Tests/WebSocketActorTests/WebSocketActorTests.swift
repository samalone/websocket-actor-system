import XCTest
import Distributed
import Logging
@testable import WebSocketActors

typealias DefaultDistributedActorSystem = WebSocketActorSystem

distributed actor Alice {
    distributed func addOne(_ n: Int) -> Int {
        return n + 1
    }
    
    distributed func howdy(from: Bob) async throws -> String {
        let name = try await from.name
        return "Nice to meet you, \(name)."
    }
}

distributed actor Bob {
    var neighbor: Alice? = nil
    distributed var name: String {
        "Bob"
    }
    
    distributed func move(near: Alice) {
        neighbor = near
    }
    
    distributed func introduceYourself() async throws -> String {
        guard let neighbor else { return "I'm all alone" }
        return try await neighbor.howdy(from: self)
    }
}

extension Logger {
    func with(level: Logger.Level) -> Logger {
        var logger = self
        logger.logLevel = level
        return logger
    }
    
    func with(_ actorID: ActorIdentity) -> Logger {
        var logger = self
        logger[metadataKey: "actorID"] = .stringConvertible(actorID)
        return logger
    }
    
    func with(_ system: WebSocketActorSystem) -> Logger {
        var logger = self
        logger[metadataKey: "system"] = .string("\(system.mode)")
        return logger
    }
}

// Note that since Swift runs these tests in parallel, they cannot use the same
// port number. By passing a port number of 0, we let the system assign us a port number.

final class WebsocketActorSystemTests: XCTestCase {
    func getLogger(fun: String = #function) -> Logger {
        return Logger(label: fun).with(level: .trace)
    }
    
    func testLocalCall() async throws {
        let system = try WebSocketActorSystem(mode: .serverOnly(host: "localhost", port: 0),
                                              logger: getLogger())
        
        let alice = system.makeActorWithID(.random) {
            Alice(actorSystem: system)
        }
        
        let fortyThree = try await alice.addOne(42)
        XCTAssertEqual(fortyThree, 43)
    }
    
    func testLocalCallback() async throws {
        let system = try WebSocketActorSystem(mode: .serverOnly(host: "localhost", port: 0),
                                              logger: getLogger())
        
        let alice = system.makeActorWithID(.random) {
            Alice(actorSystem: system)
        }
        
        let bob = system.makeActorWithID(.random) {
            Bob(actorSystem: system)
        }
        
        try await bob.move(near: alice)
        let greeting = try await bob.introduceYourself()
        XCTAssertEqual(greeting, "Nice to meet you, Bob.")
        
    }
}
