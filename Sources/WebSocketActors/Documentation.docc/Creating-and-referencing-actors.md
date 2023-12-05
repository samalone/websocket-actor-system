# Creating and referencing actors

Learn to create local actors and reference actors remotely.

## Local actors

To create a local actor, use the `WebSocketActorSystem/makeLocalActor(_:)`
function:

```swift
// In your shared library:
typealias DefaultDistributedActorSystem = WebSocketActorSystem

distributed actor Person {
    var name: String

    init(actorSystem: WebSocketActorSystem, name: String) {
        self.actorSystem = actorSystem
        self.name = name
    }
}

// In your server or client:
let actorSystem = WebSocketActorSystem()
let alice = server.makeLocalActor {
    Person(actorSystem: actorSystem, name: "Alice")
}
```

This will assign the actor a random ID. If you need to specify a particular ID,
pass it when you make the actor:

```swift
extension ActorIdentity {
    public static let alice: ActorIdentity = "alice"
}

let alice = server.makeLocalActor(id: .alice) {
    Person(actorSystem: actorSystem, name: "Alice")
}
```

## Remote actors

In principle, you can reference a remote actor knowing only its ID.

```swift
let alice = try Person.resolve(id: .alice, using: actorSystem)
```

This will work if your actor system is only connected to one other node, since
any actor that is not present locally must be on the remote node. However, if
you are running a server, or if your client is connected to multiple servers,
then the actor system will also need to know the node ID of the remote node.

There are several ways of determining the correct node ID.

### Global node identity

If you know that the remote actor will always be hosted on a particular node,
you can specify the node ID as part of the actor ID.

```swift
extension NodeIdentity {
    public static let server = NodeIdentity(id: "server")
}

extension ActorIdentity {
    public static let alice = ActorIdentity(id: "alice", node: .server)
}
```

### Passed references

When you pass an actor to another node as a function argument or return value,
the actor system will automatically include the node ID in the actor ID.

```swift
// Get the global receptionist actor from the server.
let receptionist = try Receptionist.resolve(id: .receptionist, using: actorSystem)

// Ask the receptionist for the weather forecaster for our ZIP code.
let forecaster = try await receptionist.forecaster(for: "02905")

// The forecaster will have both the actor ID and the node ID.
```
