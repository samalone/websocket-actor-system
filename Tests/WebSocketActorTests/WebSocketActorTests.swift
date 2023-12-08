import Distributed
import Logging
import NIO
@testable import WebSocketActors
import XCTest

typealias DefaultDistributedActorSystem = WebSocketActorSystem

distributed actor Person {
    private var _lastGift = "nothing"
    private var _name: String
    var neighbor: Person?

    init(actorSystem: WebSocketActorSystem, name: String) {
        self.actorSystem = actorSystem
        _name = name
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
        n + 1
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
        logger[metadataKey: "system"] = .string("\(system.nodeID)")
        return logger
    }
}

// Note that since Swift runs these tests in parallel, they cannot use the same
// port number. By passing a port number of 0, we let the system assign us a port number.

final class WebsocketActorSystemTests: XCTestCase {
    var server: WebSocketActorSystem!
    var serverManager: ServerManager!
    var serverAddress = ServerAddress(scheme: .insecure, host: "localhost", port: 0)

    override func setUp() async throws {
        server = WebSocketActorSystem(id: "server",
                                      logger: Logger(label: "\(name) server").with(level: .trace))
        serverManager = try await server.runServer(at: serverAddress)
        // Now that the server is started, we can find out what port number it is using.
        serverAddress = try await serverManager.address()
    }

    override func tearDown() async throws {
        await server.shutdownGracefully()
    }

    func testLocalCall() async throws {
        let alice = server.makeLocalActor {
            Person(actorSystem: server, name: "Alice")
        }

        let fortyThree = try await alice.addOne(42)
        XCTAssertEqual(fortyThree, 43)
    }

    func testLocalCallback() async throws {
        let alice = server.makeLocalActor {
            Person(actorSystem: server, name: "Alice")
        }

        let bob = server.makeLocalActor {
            Person(actorSystem: server, name: "Bob")
        }

        try await bob.move(near: alice)
        let greeting = try await bob.introduceYourself()
        XCTAssertEqual(greeting, "Nice to meet you, Bob.")
    }

    func testRemoteCalls() async throws {
        try await TaskPath.with(name: "testRemoteCalls") {
            let client = WebSocketActorSystem(logger: Logger(label: "\(name) client").with(level: .trace))
            try await client.connectClient(to: serverAddress)

            // Create the real Alice on the server
            let serverAlice = server.makeLocalActor(id: .alice) {
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

            await client.shutdownGracefully()
        }
    }

    func testServerPush() async throws {
        let client = WebSocketActorSystem(logger: Logger(label: "\(name) client").with(level: .trace))
        try await client.connectClient(to: serverAddress)

        // Create the real Alice on the server
        let serverAlice = server.makeLocalActor(id: .alice) {
            Person(actorSystem: server, name: "Alice")
        }

        // Create a local reference to Alice on the client
        let clientAlice = try Person.resolve(id: .alice, using: client)

        let clientBob = client.makeLocalActor(id: .bob) {
            Person(actorSystem: client, name: "Bob")
        }

        try await clientAlice.move(near: clientBob)

        let greeting = try await serverAlice.introduceYourself()
        XCTAssertEqual(greeting, "Nice to meet you, Alice.")
    }

    func testNoConnectionTimeout() async throws {
        // Make sure we get a timeout if the user tries to call a remote actor
        // without ever connecting to the server.

        let client = WebSocketActorSystem(logger: Logger(label: "\(name) client").with(level: .trace))

        // Create a local reference to Alice on the client
        let clientAlice = try Person.resolve(id: .alice, using: client)

        do {
            _ = try await clientAlice.addOne(42)
            XCTFail("Should fail to find remote node")
        }
        catch let WebSocketActorSystemError.timeoutWaitingForNodeID(nodeID, _) {
            XCTAssertNil(nodeID)
        }
        catch {
            XCTFail("Wrong error from actor call: \(error.localizedDescription)")
        }
    }

    func testWrongConnectionTimeout() async throws {
        // Make sure we get a timeout if the user tries to call a remote actor
        // whose node ID doesn't match the remote node.
        
        let client = WebSocketActorSystem(logger: Logger(label: "\(name) client").with(level: .trace))
        try await client.connectClient(to: serverAddress)
        
        // Create the real Alice on the server
        _ = server.makeLocalActor(id: .alice) {
            Person(actorSystem: server, name: "Alice")
        }
        
        // Create a local reference to Alice on the client, but get the node ID wrong
        let clientAlice = try Person.resolve(id: ActorIdentity(id: "alice", node: "wrong-server"), using: client)
        
        do {
            _ = try await clientAlice.addOne(42)
            XCTFail("Should fail to find remote node")
        }
        catch let WebSocketActorSystemError.timeoutWaitingForNodeID(nodeID, _) {
            XCTAssertNotNil(nodeID)
            XCTAssertEqual(nodeID?.id, "wrong-server")
        }
        catch {
            XCTFail("Wrong error from actor call: \(error.localizedDescription)")
        }
    }
}
