import XCTest
import Distributed
import Logging
@testable import WebSocketActors

typealias DefaultDistributedActorSystem = WebSocketActorSystem

distributed actor Alice {
    distributed func receiveGift(_ present: String) {
        print("Alice received \(present)")
    }
    
    distributed func addOne(_ n: Int) -> Int {
        return n + 1
    }
    
    distributed func howdy(from: Bob) async throws -> String {
        let name = try await from.name
        return "Nice to meet you, \(name)."
    }
}

extension ActorIdentity {
    static let alice = ActorIdentity(id: "alice")
    static let bob = ActorIdentity(id: "bob")
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
    var server: WebSocketActorSystem!
    
    override func setUp() async throws {
        server = try WebSocketActorSystem(mode: .serverOnly(host: "localhost", port: 0),
                                          logger: Logger(label: "\(name) server").with(level: .trace))
    }
    
    override func tearDown() async throws {
        try await server.shutdownGracefully()
    }
    
    func testLocalCall() async throws {
        let alice = server.makeActor() {
            Alice(actorSystem: server)
        }
        
        let fortyThree = try await alice.addOne(42)
        XCTAssertEqual(fortyThree, 43)
    }
    
    func testLocalCallback() async throws {
        let alice = server.makeActor() {
            Alice(actorSystem: server)
        }
        
        let bob = server.makeActor() {
            Bob(actorSystem: server)
        }
        
        try await bob.move(near: alice)
        let greeting = try await bob.introduceYourself()
        XCTAssertEqual(greeting, "Nice to meet you, Bob.")
    }
    
    func testRemoteCall() async throws {
        let client = try WebSocketActorSystem(mode: .clientFor(host: "localhost", port: server.port),
                                          logger: Logger(label: "\(name) client").with(level: .trace))
        
        let serverAlice = server.makeActor(id: .alice) {
            Alice(actorSystem: server)
        }
        
        let clientAlice = try Alice.resolve(id: .alice, using: client)
        
//        try await Task.sleep(for: .seconds(2))
        
        try await clientAlice.receiveGift("mandrake")
        
//        XCTAssertEqual(result, 43)
        
        
        try await client.shutdownGracefully()
    }
}
