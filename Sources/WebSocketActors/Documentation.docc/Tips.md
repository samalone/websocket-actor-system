# Tips for writing distributed actors

Writing distributed actors is a little different from writing local actors.
Here are tips for implementing distributed actors in a client/server world.

## Start with your `Sendable` data

Although it's tempting to start by defining your distributed actors, you'll probably be more productive by focusing first on the data that will pass between your client and your server.

One of your goals using distributed actors will be to minimize the amount of communications between the client and the server. Remember that your code can't access a remote actor directly, it can only access the data that is passed from the remote actor, and that data must be `Sendable` and `Codable`. 

For example, if your server will be returning a list of weather stations near a location, you'll probably want to define a sendable `WeatherStation` struct:

```swift
public struct WeatherStation: Codable, Sendable {
    public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
}
```

## Try to pass exactly the required data in a single function call

There is overhead whenever you make a remote function call, so design your actors to minimize the number of function calls. Pass all of the necessary data in as arguments and return all the required data as the function result.

Also, design your APIs to minimize the amount of data that is passed with each call so you aren't wasting the user's bandwidth.

For example, if you need an API that lets the user select a nearby weather station, pass the location filters as arguments and return only the weather stations that match the filters:

```swift
public distributed actor WeatherStationRegistry {
    public distributed func getStationsNear(latitude: Double,
                                            longitude: Double,
                                            radius: Double) -> [WeatherStation] {
        ...
    }
}
```

## Hide the implementation

Your client and server will often host different actors and implement them using different libraries. Since your distributed actors must be defined in a shared library, add a layer of indirection so the client and server can implement them independently.

```swift
public protocol WeatherStationRegistryImplementation {
    func getStationsNear(latitude: Double,
                         longitude: Double,
                         radius: Double) -> [WeatherStation]
}

public distributed actor WeatherStationRegistry {
    private let implementation: WeatherStationRegistryImplementation
    
    public init(actorSystem: WebSocketActorSystem,
                implementation: WeatherStationRegistryImplementation) {
        self.actorSystem = actorSystem
        self.implementation = implementation
    }
    
    public distributed func getStationsNear(latitude: Double,
                                            longitude: Double,
                                            radius: Double) -> [WeatherStation] {
        return implementation.getStationsNear(latitude: latitude,
                                              longitude: longitude,
                                              radius: radius)
    }
}
```

This keeps your client- and server-specific code out of the shared library.