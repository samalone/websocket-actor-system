import XCTest
import Distributed
import Logging
@testable import WebSocketActors

typealias DefaultDistributedActorSystem = WebSocketActorSystem

distributed actor Person {
    private var _lastGift = "nothing"
    private var _name: String
    var neighbor: Person? = nil
    
    init(actorSystem: WebSocketActorSystem, name: String) {
        self.actorSystem = actorSystem
        self._name = name
    }
    
    distributed var lastGift: String {
        _lastGift
    }
    
    distributed var name: String {
        _name
    }
    
    distributed func receiveGift(_ present: String) {
        _lastGift = present
    }
    
    distributed func addOne(_ n: Int) -> Int {
        return n + 1
    }
    
    distributed func howdy(from: Person) async throws -> String {
        let name = try await from.name
        return "Nice to meet you, \(name)."
    }
    
    distributed func move(near: Person) {
        neighbor = near
    }
    
    distributed func introduceYourself() async throws -> String {
        guard let neighbor else { return "I'm all alone" }
        return try await neighbor.howdy(from: self)
    }
}

extension ActorIdentity {
    static let alice = ActorIdentity(id: "alice")
    static let bob = ActorIdentity(id: "bob")
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
            Person(actorSystem: server, name: "Alice")
        }
        
        let fortyThree = try await alice.addOne(42)
        XCTAssertEqual(fortyThree, 43)
    }
    
    func testLocalCallback() async throws {
        let alice = server.makeActor() {
            Person(actorSystem: server, name: "Alice")
        }
        
        let bob = server.makeActor() {
            Person(actorSystem: server, name: "Bob")
        }
        
        try await bob.move(near: alice)
        let greeting = try await bob.introduceYourself()
        XCTAssertEqual(greeting, "Nice to meet you, Bob.")
    }
    
    func testRemoteCalls() async throws {
        let client = try WebSocketActorSystem(mode: .clientFor(host: "localhost", port: server.port),
                                          logger: Logger(label: "\(name) client").with(level: .trace))
        
        // Create the real Alice on the server
        let serverAlice = server.makeActor(id: .alice) {
            Person(actorSystem: server, name: "Alice")
        }
        
        // Create a local reference to Alice on the client
        let clientAlice = try Person.resolve(id: .alice, using: client)
        
        // Send Alice a message without needing a reply
        try await clientAlice.receiveGift("mandrake")
        // Make sure Alice received the gift.
        let gift = try await serverAlice.lastGift
        XCTAssertEqual(gift, "mandrake")
        
        // Send Alice a message that returns a result
        let result = try await clientAlice.addOne(42)
        XCTAssertEqual(result, 43)
        
        try await client.shutdownGracefully()
    }
    
    func testServerPush() async throws {
        let client = try WebSocketActorSystem(mode: .clientFor(host: "localhost", port: server.port),
                                          logger: Logger(label: "\(name) client").with(level: .trace))
        
        // Create the real Alice on the server
        let serverAlice = server.makeActor(id: .alice) {
            Person(actorSystem: server, name: "Alice")
        }
        
        // Create a local reference to Alice on the client
        let clientAlice = try Person.resolve(id: .alice, using: client)
        
        let clientBob = client.makeActor(id: .bob) {
            Person(actorSystem: client, name: "Bob")
        }
        
        try await clientAlice.move(near: clientBob)
        
        let greeting = try await serverAlice.introduceYourself()
        XCTAssertEqual(greeting, "Nice to meet you, Bob.")
    }
}
