import XCTest
import Distributed
import Logging
import NIO
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

extension NodeIdentity {
    static let server = NodeIdentity(id: "server")
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
        server = try await WebSocketActorSystem(mode: .serverOnly(host: "localhost", port: 0),
                                          id: .server,
                                          logger: Logger(label: "\(name) server").with(level: .trace))
        // We need this function to return so the unit tests can run,
        // but we also need the server to continue running in the background.
        // Spawn a new task to run the server.
        Task {
            try await server.runServer()
        }
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
        let client = try await WebSocketActorSystem(mode: .clientFor(server: NodeAddress(scheme: "ws", host: "localhost", port: server.localPort)),
                                          logger: Logger(label: "\(name) client").with(level: .trace))
        client.runClient()
    
//        try await Task.sleep(for: .seconds(1))
        
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
        let client = try await WebSocketActorSystem(mode: .clientFor(server: NodeAddress(scheme: "ws", host: "localhost", port: server.localPort)),
                                          logger: Logger(label: "\(name) client").with(level: .trace))
        client.runClient()
        
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
        XCTAssertEqual(greeting, "Nice to meet you, Alice.")
    }
    
//    func testResilientTask() async throws {
//        var retryCount = -1
//        
//        func monitor(status: ResilientTask.Status) {
//            switch status {
//            case .initializing:
//                print("initializing")
//            case .running:
//                print("running")
//            case .waiting(let delay):
//                print("waiting \(delay) seconds")
//            case .cancelled:
//                print("cancelled")
//            case .failed(let error):
//                print("failed with \(error)")
//            }
//        }
//        
//        let action = ResilientTask(monitor: monitor) { initializationSuccessful in
//            retryCount = (retryCount + 1) % 3
//            print("retryCount = \(retryCount)")
//            if retryCount > 0 {
//                return
//            }
//            await initializationSuccessful()
//            try await Task.sleep(for: .seconds(20))
//        }
//        
//        try await Task.sleep(for: .seconds(120))
//        
//        action.cancel()
//    }
}
