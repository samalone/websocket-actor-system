# Identifying actors

Before you can work with actors, you need to identify them. Learn how to identify
actors and provide hints about where they can be found.

## Identifying nodes

An important part of identifying actors is identifying the nodes that host them. 
You assign a node's identity when you create its ``WebSocketActorSystem``.

```swift
// In your shared library:
extension NodeIdentity {
    public static let server: NodeIdentity = "server"
}

// In your server:
let actorSystem = WebSocketActorSystem(id: .server)
```

In client code, you can leave out the node ID and the actor system will
assign the client a random node ID.

```swift
// In your client:
let actorSystem = WebSocketActorSystem()    // assigns a random node ID
```

## Identifying actors

To access an actor, you need to know its identity, which is represented with an
`ActorIdentity` value with three parts:

- `id`: A string that uniquely identifies the actor within the actor system.
  This is often a UUID, but it can be any string that uniquely identifies the
  actor.
- `node`: The id of the node that hosts the actor. This is a hint that helps the
  actor system route calls to the correct node.
- `type`: A string indicating the type of the actor. This hint is used when
  resolving actors on demand.

Actors will commonly have a global, assigned, or random identity.

### Global identity

Most applications using distributed actors need at least one actor whose
identity is known globally. This actor is sometimes called a "receptionist", and
it provides a lookup service to locate other actors in the system.

To provide a fixed identity for an actor, extend the `ActorIdentity` type with a
static property.

```swift
// In your shared library:
extension ActorIdentity {
    public static let receptionist = ActorIdentity(id: "receptionist")
}
```

If you know that the receptionist will always be hosted on a particular node,
you can specify the node ID as well.

```swift
// In your shared library:
extension ActorIdentity {
    public static let receptionist = ActorIdentity(id: "receptionist", node: .server)
}
```

### Assigned identity

If you are associating actors with some other system like database records, you
may want to use IDs that map to the other system. Just remember that the IDs you
assign must be globally unique, so you may need to add additional information to
the ID.

> Warning: The ``ActorIdentity/type`` field is a hint that is only used when
> resolving actors on demand. It _cannot_ be used to distinguish between actors
> with the same ID. If you have actors of different types that might have the
> same ID, you must add other information to the ID to make it unique.

```swift
// A database record
struct PersonRecord {
    var id: Int
    var name: String
}

extension ActorIdentity {
    public static func forPerson(_ record: PersonRecord) -> ActorIdentity {
        ActorIdentity(id: "person-\(record.id)")
    }
}
```

### Random identity

When you are creating a local actor you may not care about its ID. In this case
you can allow the actor system to assign a random ID.

```swift
let alice = actorSystem.makeLocalActor {
    Person(actorSystem: actorSystem, name: "Alice")
}
```

Of course, the only way that you can access this actor remotely is to pass the actor to a remote node.
The "receptionist" pattern is a common way to do this.
