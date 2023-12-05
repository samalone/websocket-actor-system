#  Initializing the actor system

Learn how to initialize the actor system and connect clients to servers.

## Specifying the actor system

Swift's distributed actor system requires a library that identifies actors and handles communications between them. When you are declaring your distributed actors, you can either specify a default actor system for all distributed actors, or specify the actor system for each distrubted actor separately.

Your distributed actors should be defined in a library that is shared by your client and server code.

### To declare a default actor system for all actors in your library

```swift
import Distributed
import WebSocketActors

typealias DefaultDistributedActorSystem = WebSocketActorSystem
```

### To declare the actor system for a single actor

```swift
import Distributed
import WebSocketActors

distributed actor Greeter {
    typealias ActorSystem = WebSocketActorSystem

    distributed func hello(name: String) -> String {
        return "Hello \(name)!"
    }
}
```
