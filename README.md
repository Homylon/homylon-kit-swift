# HomylonKit (Swift)

**Homylon** is a home automation language and engine you can read: plain-text scenes that say how
a house should behave. Downloads, the manual and the Homylon engine: **[homylon.org](https://www.homylon.org)**.

The Homylon network layer for apps, tools and agents on iPhone, iPad, Mac, Apple TV and Linux:
the same code the Homylon Engine uses to talk to its agents and apps.

The transport is Network.framework on Apple platforms and SwiftNIO on Linux, with the same
classes and functions on both. SwiftNIO is only fetched on Linux, so Apple apps do not carry it.

## What is in it

| | |
|---|---|
| `Homylon.send(...)` | send a message to the engine: JSON, a timestamp and the security key; UDP for small messages, TCP for large ones |
| `UDPServer`, `TCPServer` | receive messages from the engine |
| `EngineFinder` | find the engine: Bonjour first, then the last engine that answered, then the address from your settings |
| `localAddress(toward:)` | your own address as the engine sees it, to register with |

The rules themselves - ports, message formats, one TCP message per connection, "the engine is
the master" - are in [homylon-protocol](https://github.com/Homylon/homylon-protocol)
(PROTOCOL.md), and on the Homylon website: https://www.homylon.org/index.php/homylon-protocol

## Use

Add the package in Xcode (File > Add Package Dependencies) with
`https://github.com/Homylon/homylon-kit-swift`, from version 1.0.2, and `import HomylonKit`.
In a Package.swift:

```swift
.package(url: "https://github.com/Homylon/homylon-kit-swift", from: "1.0.2")
```

Minimum: iOS 12, macOS 11.7, tvOS 12; on Linux, Swift 5.9 or later. The Homylon Monitor app
is a complete example.

Finding the engine with Bonjour (`EngineFinder`) is Apple-only for now; on Linux, give the
engine's address.

To run the tests with the SwiftNIO transport on a Mac: `HOMYLON_NIO=1 swift test`.

## Licence

MIT, see LICENSE.
