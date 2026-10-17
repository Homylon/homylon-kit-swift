// The Homylon transport with SwiftNIO, for Linux (and for testing on a Mac): UDP datagrams, and
// TCP with one length-prefixed message per connection (a 4-byte big-endian length, the JSON, then
// a FIN). Same classes and signatures as Transport+Apple.swift, so code written against one
// compiles against the other. Exactly one of the two is compiled:
//   - Apple platforms use Transport+Apple.swift (Network.framework).
//   - Linux, or a Mac building with HOMYLON_NIO=1 in the environment, uses this file.
//
// Taken from the Homylon Engine's NetworkServices+NIO.swift, so apps and the engine speak with
// exactly the same code. The rules themselves: https://homylon.org/index.php/homylon-protocol

#if HOMYLON_NIO || !canImport(Network)
import Foundation
import NIOCore
import NIOPosix

/// The Network.framework version reports `NWError`. Here any `Error` is reported, under the
/// same name, so code written against either transport compiles unchanged.
public typealias NWError = Error

/// Shown at startup, so it is always clear which transport an engine was built with.
public let networkTransportName = "SwiftNIO"

/// One event-loop group for the whole process. Every transaction is short-lived; the group
/// lives as long as the process does.
private let homylonEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

/// The engine listens on IPv4 only, so a sender is always reported as a dotted IPv4 address.
///
/// The address is built directly. Binding by host name ("0.0.0.0") would run getaddrinfo on
/// every bind, and on macOS that lookup logs "send failed: Invalid argument" while it tries
/// to rank 0.0.0.0 as a destination.
private func anyIPv4(port: Int) -> SocketAddress {
    return try! SocketAddress(ipAddress: "0.0.0.0", port: port)
}

/// What Network.framework reports when an endpoint has no usable host.
private let invalidHost = "not.a.valid.address"

/// Resolves a destination to an IPv4 address. Address literals are used as they are; a name
/// such as "localhost" resolves to IPv4 only, where a plain lookup could return IPv6 first.
/// Lookups can block, so callers run this on a dispatch queue, never on the event loop.
private func resolveIPv4(_ host: String, port: Int) throws -> SocketAddress {
    if let literal = try? SocketAddress(ipAddress: host, port: port) {
        return literal
    }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    var results: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &results) == 0, let first = results,
          let address = first.pointee.ai_addr else {
        throw SocketAddressError.unknown(host: host, port: port)
    }
    defer { freeaddrinfo(results) }
    var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    ipv4.sin_port = in_port_t(port).bigEndian
    return SocketAddress(ipv4, host: host)
}


// / / / / / / / / / / / /  UDP CLIENT and SERVER PROTOCOLS AND CLASSES

@available(macOS 10.14, iOS 12.0, *)
public protocol UDPClientDelegate {
    func didSendUdpMessage(_ error: NWError?)
    func didSendUdpData(_ error: NWError)
}

@available(macOS 10.14, iOS 12.0, *)
public class UDPClient {
    public var delegate : UDPClientDelegate?
    let queue = DispatchQueue(label: "com.homylon.udpclient")
    private let lifecycleQueue = DispatchQueue(label: "com.homylon.udpclient.lifecycle")

    let MTU = 1000

    public static let shared = UDPClient()

    /// These owners exist only while one datagram is being attempted. They are deliberately
    /// keyed by transaction ID, never destination: a down monitor/agent must not leave an
    /// endpoint, a retry queue, or a warm socket behind in the engine.
    private var inFlight: [UUID: UDPDatagramTransmission] = [:]
    private let sendTimeout: DispatchTimeInterval = .seconds(3)

    private init() {}

    public func sendMessage(to ip: String, onPort: Int, message: String,
                     completion: ((NWError?) -> Void)? = nil) {
        guard let data = message.data(using: .utf8) else { return }
        sendData(to: ip, onPort: onPort, data: data, completion: completion)
    }

    public func sendData(to ip: String, onPort: Int, data: Data,
                  completion: ((NWError?) -> Void)? = nil) {
        // UDP carries already-prepared, compact datagrams only. Choosing TCP or making a
        // monitor payload shorter belongs to the semantic/message-building layer; transport
        // never promotes, truncates, queues, or retries a message on its own.
        if data.count > self.MTU {
            let head = String(data: data.prefix(80), encoding: .utf8) ?? ""
            print("DROPPED a \(data.count) byte UDP message to \(ip):\(onPort) - the "
                + "prepared payload exceeds the \(self.MTU)-byte transport limit. "
                + "Message began: \(head)")
            return
        }

        lifecycleQueue.async {
            let id = UUID()
            let transmission = UDPDatagramTransmission(
                id: id,
                ip: ip,
                port: onPort,
                data: data,
                queue: self.queue,
                timeout: self.sendTimeout,
                didFinish: { [weak self] id, error in
                    self?.finishTransmission(id: id, error: error, completion: completion)
                }
            )
            self.inFlight[id] = transmission
            transmission.start()
        }
    }

    private func finishTransmission(id: UUID, error: NWError?, completion: ((NWError?) -> Void)?) {
        lifecycleQueue.async {
            guard self.inFlight.removeValue(forKey: id) != nil else { return }
            completion?(error)
            // A refused UDP port or an offline monitor is ordinary best-effort delivery,
            // not an engine error. Preserve the delegate callback for clients that choose
            // to observe it, but do not queue or retry it here.
            if let error = error {
                DispatchQueue.main.async {
                    self.delegate?.didSendUdpData(error)
                }
            }
        }
    }

    public func broadcast(to ip: String, onPort: Int, data: Data) {

        let a : [String] = ip.components(separatedBy: ".")
        guard a.count == 4 else {
            print("Invalid subnet address")
            return
        }

        print("Broadcast to local network \(ip) with individual messages")

        for n in 1...254 {
            let broadcastAddress = "\(a[0]).\(a[1]).\(a[2]).\(n)"
            self.sendData(to: broadcastAddress, onPort: onPort, data: data)
        }
    }

    public func broadcast2(to subnet: String, onPort: Int, data: Data) {
        // Construct the broadcast address
        let a: [String] = subnet.components(separatedBy: ".")
        guard a.count == 4 else {
            print("Invalid subnet address")
            return
        }
        let broadcastAddress = "\(a[0]).\(a[1]).\(a[2]).255"
        print("Broadcasting to address \(broadcastAddress)")

        // Send data to the broadcast address
        sendData(to: broadcastAddress, onPort: onPort, data: data)
    }

}

/// Owns exactly one UDP attempt. It is retained by UDPClient only until a send result,
/// network failure, cancellation, or deadline. There is no destination-level state.
@available(macOS 10.14, iOS 12.0, *)
private final class UDPDatagramTransmission {
    private let id: UUID
    private let ip: String
    private let port: Int
    private let queue: DispatchQueue
    private let data: Data
    private let timeout: DispatchTimeInterval
    private let didFinish: (UUID, NWError?) -> Void
    private let finishLock = NSLock()
    private var channel: Channel?
    private var hasFinished = false
    private var timeoutTask: DispatchSourceTimer?

    init(id: UUID, ip: String, port: Int, data: Data, queue: DispatchQueue,
         timeout: DispatchTimeInterval, didFinish: @escaping (UUID, NWError?) -> Void) {
        self.id = id
        self.ip = ip
        self.port = port
        self.queue = queue
        self.data = data
        self.timeout = timeout
        self.didFinish = didFinish
    }

    func start() {
        scheduleTimeout()
        // Name resolution can block, so it runs on our queue and never on the event loop.
        queue.async { self.sendOnce() }
    }

    private func sendOnce() {
        let remote: SocketAddress
        do {
            remote = try resolveIPv4(ip, port: port)
        } catch {
            finish(error: error)
            return
        }

        DatagramBootstrap(group: homylonEventLoopGroup)
            .channelOption(ChannelOptions.socketOption(NIOBSDSocket.Option(rawValue: SO_BROADCAST)),
                           value: 1)
            .bind(to: anyIPv4(port: 0))
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    self.finish(error: error)
                case .success(let channel):
                    guard self.adopt(channel) else { return }
                    var buffer = channel.allocator.buffer(capacity: self.data.count)
                    buffer.writeBytes(self.data)
                    let envelope = AddressedEnvelope(remoteAddress: remote, data: buffer)
                    channel.writeAndFlush(envelope).whenComplete { result in
                        switch result {
                        case .success:
                            self.finish(error: nil)
                        case .failure(let error):
                            self.finish(error: error)
                        }
                    }
                }
            }
    }

    /// Takes ownership of the channel unless the deadline already ended this attempt.
    private func adopt(_ channel: Channel) -> Bool {
        finishLock.lock()
        guard !hasFinished else {
            finishLock.unlock()
            channel.close(promise: nil)
            return false
        }
        self.channel = channel
        finishLock.unlock()
        return true
    }

    private func scheduleTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(error: nil) }
        finishLock.lock()
        timeoutTask = timer
        finishLock.unlock()
        timer.resume()
    }

    private func finish(error: NWError?) {
        let timer: DispatchSourceTimer?
        let channel: Channel?
        finishLock.lock()
        guard !hasFinished else { finishLock.unlock(); return }
        hasFinished = true
        timer = timeoutTask
        timeoutTask = nil
        channel = self.channel
        self.channel = nil
        finishLock.unlock()
        timer?.cancel()
        channel?.close(promise: nil)
        didFinish(id, error)
    }
}

@available(macOS 10.14, iOS 12.0, *)
public enum UDPServerError: Error {
    case invalidPort(UInt16)
    case listenerCreationFailed(Error)
    case startFailed(Error)
}

@available(macOS 10.14, iOS 12.0, *)
public protocol UDPServerDelegate: AnyObject {
    func udpDidReceiveData(_ data: Data?, from: String)
    func udpDidFailToStartWithError(_ error: Error)
    func udpDidStartSuccessfully(onPort: Int)
}

@available(macOS 10.14, iOS 12.0, *)
public class UDPServer {
    public weak var delegate: UDPServerDelegate?
    private var channel: Channel?
    private var listenerQueue: DispatchQueue?

    public init() {}

    public func start(onPort: UInt16, queue: DispatchQueue, maxRetries: Int = 3) {
        self.listenerQueue = queue

        func attemptStart() {
            guard onPort != 0 else {
                let error = NSError(domain: "UDPServerError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid port number"])
                handleStartFailure(error: error)
                return
            }

            print("UDP server is setting up")
            DatagramBootstrap(group: homylonEventLoopGroup)
                // Network.framework hands over a whole datagram; NIO's default buffer is 2 KB.
                .channelOption(ChannelOptions.recvAllocator,
                               value: FixedSizeRecvByteBufferAllocator(capacity: 65536))
                .channelInitializer { channel in
                    channel.pipeline.addHandler(UDPServerHandler(server: self))
                }
                .bind(to: anyIPv4(port: Int(onPort)))
                .whenComplete { result in
                    queue.async {
                        switch result {
                        case .success(let channel):
                            self.channel = channel
                            print("UDP server started successfully on port \(onPort)")
                            self.delegate?.udpDidStartSuccessfully(onPort: Int(onPort))
                        case .failure(let error):
                            self.handleStartFailure(error: error)
                        }
                    }
                }
        }

        queue.async {
            attemptStart()
        }
    }

    public func stop() {
        channel?.close(promise: nil)
        channel = nil
        print("UDP server stopped")
    }

    fileprivate func didReceive(_ data: Data, from sendingIP: String) {
        DispatchQueue.main.async {
            self.delegate?.udpDidReceiveData(data, from: sendingIP)
        }
    }

    private func handleStartFailure(error: Error) {
        print("UDP server failed to start: \(error)")
        DispatchQueue.main.async {
            self.delegate?.udpDidFailToStartWithError(error)
        }
    }
}

/// Hands every received datagram, whole, to the UDPServer together with its sender.
@available(macOS 10.14, iOS 12.0, *)
private final class UDPServerHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private weak var server: UDPServer?

    init(server: UDPServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let bytes = envelope.data.getBytes(at: envelope.data.readerIndex,
                                           length: envelope.data.readableBytes) ?? []
        let sendingIP = envelope.remoteAddress.ipAddress ?? invalidHost
        server?.didReceive(Data(bytes), from: sendingIP)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // One bad datagram must not take the listener down.
        print("Error receiving UDP message: \(error)")
    }
}



// / / / / / / / / / / / /  TCP CLIENT and SERVER PROTOCOLS AND CLASSES
@available(macOS 10.14, iOS 12.0, *)
public protocol TCPClientDelegate: AnyObject {
    func didSendTcpData(wasSuccessful: Bool)
}

@available(macOS 10.14, iOS 12.0, *)
public class TCPClient {
    public weak var delegate: TCPClientDelegate?

    public static let shared = TCPClient()
    private let lifecycleQueue = DispatchQueue(label: "com.homylon.tcpclient.lifecycle")
    private let connectionQueue = DispatchQueue(label: "com.homylon.tcpclient.connection")
    /// Transaction owners only. An entry is removed on every terminal path, so this is not a
    /// connection pool and never carries state from one message to the next.
    private var inFlight: [UUID: TCPTransmission] = [:]
    private let sendTimeout: DispatchTimeInterval = .seconds(5)

    private init() {}

    public func sendMessage(to ip: String, onPort port: Int, message: String,
                     completion: ((Bool) -> Void)? = nil) {
        guard let data = message.data(using: .utf8) else {
            print("Failed to convert message to data.")
            return
        }
        lifecycleQueue.async {
            let id = UUID()
            let transaction = TCPTransmission(
                id: id,
                ip: ip,
                port: port,
                data: data,
                queue: self.connectionQueue,
                timeout: self.sendTimeout,
                didFinish: { [weak self] id, wasSuccessful in
                    self?.finishTransmission(id: id, wasSuccessful: wasSuccessful,
                                             completion: completion)
                }
            )
            self.inFlight[id] = transaction
            transaction.start()
        }
    }

    /// A semantic restart can supersede a currently in-flight list for the same endpoint.
    /// There is no pooled connection to discard; cancel only those short-lived transactions.
    public func discardConnection(to ip: String, onPort port: Int) {
        var doomed: [TCPTransmission] = []
        lifecycleQueue.sync {
            let matches = inFlight.filter { $0.value.matches(ip: ip, port: port) }
            for (id, transaction) in matches {
                inFlight.removeValue(forKey: id)
                doomed.append(transaction)
            }
        }
        for transaction in doomed { transaction.cancel() }
    }

    private func finishTransmission(id: UUID, wasSuccessful: Bool,
                                     completion: ((Bool) -> Void)?) {
        lifecycleQueue.async {
            guard self.inFlight.removeValue(forKey: id) != nil else { return }
            completion?(wasSuccessful)
            DispatchQueue.main.async {
                self.delegate?.didSendTcpData(wasSuccessful: wasSuccessful)
            }
        }
    }
}

/// Owns exactly one TCP frame. Its lifetime is bounded by a send deadline; it sends a FIN
/// after the frame so receivers following the original EOF contract and the current framed
/// contract both know that this transaction is over.
///
/// Unlike Network.framework, which waits in `.waiting` until the deadline, a refused or
/// unreachable destination fails here as soon as the operating system reports it.
@available(macOS 10.14, iOS 12.0, *)
private final class TCPTransmission {
    private let id: UUID
    private let ip: String
    private let port: Int
    private let queue: DispatchQueue
    private let data: Data
    private let timeout: DispatchTimeInterval
    private let didFinish: (UUID, Bool) -> Void
    private let finishLock = NSLock()
    private var channel: Channel?
    private var hasFinished = false
    private var timeoutTask: DispatchSourceTimer?

    init(id: UUID, ip: String, port: Int, data: Data, queue: DispatchQueue,
         timeout: DispatchTimeInterval, didFinish: @escaping (UUID, Bool) -> Void) {
        self.id = id
        self.ip = ip
        self.port = port
        self.queue = queue
        self.data = data
        self.timeout = timeout
        self.didFinish = didFinish
    }

    func matches(ip: String, port: Int) -> Bool {
        return self.ip == ip && self.port == port
    }

    func start() {
        scheduleTimeout()
        // Name resolution can block, so it runs on our queue and never on the event loop.
        queue.async { self.connect() }
    }

    func cancel() {
        finish(wasSuccessful: false)
    }

    private func connect() {
        let remote: SocketAddress
        do {
            remote = try resolveIPv4(ip, port: port)
        } catch {
            finish(wasSuccessful: false)
            return
        }

        ClientBootstrap(group: homylonEventLoopGroup)
            .connect(to: remote)
            .whenComplete { result in
                switch result {
                case .failure:
                    self.finish(wasSuccessful: false)
                case .success(let channel):
                    guard self.adopt(channel) else { return }
                    self.sendOneFrame(on: channel)
                }
            }
    }

    /// Takes ownership of the channel unless the deadline or a cancel already ended this
    /// transaction.
    private func adopt(_ channel: Channel) -> Bool {
        finishLock.lock()
        guard !hasFinished else {
            finishLock.unlock()
            channel.close(promise: nil)
            return false
        }
        self.channel = channel
        finishLock.unlock()
        return true
    }

    private func sendOneFrame(on channel: Channel) {
        var frame = channel.allocator.buffer(capacity: 4 + data.count)
        frame.writeInteger(UInt32(data.count), endianness: .big)
        frame.writeBytes(data)

        channel.writeAndFlush(frame).whenComplete { result in
            guard case .success = result else {
                self.finish(wasSuccessful: false)
                return
            }
            self.sendFinalMessage(on: channel)
        }
    }

    private func sendFinalMessage(on channel: Channel) {
        channel.close(mode: .output).whenComplete { result in
            if case .success = result {
                self.finish(wasSuccessful: true)
            } else {
                self.finish(wasSuccessful: false)
            }
        }
    }

    private func scheduleTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(wasSuccessful: false) }
        finishLock.lock()
        timeoutTask = timer
        finishLock.unlock()
        timer.resume()
    }

    private func finish(wasSuccessful: Bool) {
        let timer: DispatchSourceTimer?
        let channel: Channel?
        finishLock.lock()
        guard !hasFinished else { finishLock.unlock(); return }
        hasFinished = true
        timer = timeoutTask
        timeoutTask = nil
        channel = self.channel
        self.channel = nil
        finishLock.unlock()
        timer?.cancel()
        channel?.close(promise: nil)
        didFinish(id, wasSuccessful)
    }
}

@available(macOS 10.14, iOS 12.0, *)
// Add tcpDidReportMessage to TCPServerDelegate
public protocol TCPServerDelegate {
    func tcpDidReceiveData(_ data: Data?, from: String)
    func tcpDidFailToStartWithError(_ error: Error)
    func tcpDidStartSuccessfully(onPort: Int)
    func tcpDidReportMessage(_ message: String)
}

@available(macOS 10.14, iOS 12.0, *)
public class TCPServer {
    public var delegate : TCPServerDelegate?

    var channel : Channel?
    private var listenerQueue: DispatchQueue?
    private var connections: [TCPConnection] = []
    /// `connections` is appended from the event loop and removed from whichever callback
    /// happens to end a connection. Without this it is an unsynchronised array mutated from
    /// several threads.
    private let connectionsLock = DispatchQueue(label: "com.homylon.tcpserver.connections")

    public init() {
    }

    public func start(onPort: UInt16, queue: DispatchQueue, maxRetries: Int = 3) {
        self.listenerQueue = queue
        var retries = 0

        func attemptStart() {
            print("Attempting to start TCP listener on port \(onPort)")

            ServerBootstrap(group: homylonEventLoopGroup)
                // Lets a restart re-use the port while connections from the previous
                // listener are still in TIME_WAIT. It does not allow two listeners.
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    guard let self = self else { return channel.close() }
                    let peer = channel.remoteAddress
                    print("New TCP connection from \(peer?.ipAddress ?? invalidHost):\(peer?.port.map(String.init) ?? "?")")
                    return self.handleNewConnection(channel)
                }
                .bind(to: anyIPv4(port: Int(onPort)))
                .whenComplete { [weak self] result in
                    guard let self = self else { return }
                    queue.async {
                        switch result {
                        case .success(let channel):
                            self.channel = channel
                            print("TCP server started successfully on port \(onPort)")
                            DispatchQueue.main.async {
                                self.delegate?.tcpDidStartSuccessfully(onPort: Int(onPort))
                            }
                        case .failure(let error):
                            print("TCP server failed to start: \(error)")
                            if retries < maxRetries {
                                retries += 1
                                print("Retrying TCP server start (attempt \(retries))")
                                queue.asyncAfter(deadline: .now() + 1.0) {
                                    attemptStart()
                                }
                            } else {
                                DispatchQueue.main.async {
                                    self.delegate?.tcpDidFailToStartWithError(error)
                                }
                            }
                        }
                    }
                }
        }

        queue.async {
            attemptStart()
        }
    }

    private func handleNewConnection(_ channel: Channel) -> EventLoopFuture<Void> {
        let tcpConnection = TCPConnection()
        tcpConnection.delegate = self
        connectionsLock.sync { connections.append(tcpConnection) }
        return tcpConnection.didAccept(channel)
    }

    public func stop() {
        channel?.close(promise: nil)
        channel = nil
        let activeConnections: [TCPConnection] = connectionsLock.sync {
            let snapshot = connections
            connections.removeAll()
            return snapshot
        }
        for connection in activeConnections {
            connection.close()
        }
        print("TCP server stopped")
    }
}

@available(macOS 10.14, iOS 12.0, *)
// Implement tcpDidReportMessage in the extension
extension TCPServer: TCPConnectionDelegate {
    func didReceiveTcpConnectionData(_ data: Data?, from: String) {
        DispatchQueue.main.async {
            self.delegate?.tcpDidReceiveData(data, from: from)
        }
    }

    func didCloseTcpConnection(_ connection: TCPConnection) {
        connectionsLock.sync {
            if let index = connections.firstIndex(where: { $0 === connection }) {
                connections.remove(at: index)
            }
        }
    }
}

@available(macOS 10.14, iOS 12.0, *)
protocol TCPConnectionDelegate {
    func didReceiveTcpConnectionData(_ data: Data?, from: String)
    func didCloseTcpConnection(_ connection: TCPConnection)
}

@available(macOS 10.14, iOS 12.0, *)
class TCPConnection {
    var delegate : TCPConnectionDelegate?
    let queue = DispatchQueue(label: "com.homylon.tcpconnection")
    private var hasFinished = false
    private let finishLock = NSLock()
    private var acceptedChannel: Channel?
    private var timeoutTask: DispatchSourceTimer?
    fileprivate let maxSize: Int = 1_000_000 // a light list for a large house is a few KB; this is headroom
    private let timeout: DispatchTimeInterval = .seconds(3)

    init() {
    }

    func reset() {
        close()
    }

    func close() {
        finish()
    }

    func didAccept(_ channel: Channel) -> EventLoopFuture<Void> {
        finishLock.lock()
        guard !hasFinished else { finishLock.unlock(); return channel.close() }
        acceptedChannel = channel
        finishLock.unlock()

        // This bounds the complete transaction, including a client that sends only part of
        // a length prefix/body and then disappears. No accepted TCP connection may outlive it.
        scheduleTimeout()
        return channel.pipeline.addHandler(TCPFrameReceiver(connection: self))
    }

    /// Let go of an accepted connection, exactly once.
    ///
    /// Every path out of the read loop has to come through here: a complete frame, a bad
    /// length, an error, the peer closing, the deadline, or the server stopping.
    fileprivate func finish() {
        let timer: DispatchSourceTimer?
        let channel: Channel?
        finishLock.lock()
        if hasFinished { finishLock.unlock(); return }
        hasFinished = true
        channel = acceptedChannel
        acceptedChannel = nil
        timer = timeoutTask
        timeoutTask = nil
        finishLock.unlock()
        channel?.close(promise: nil)
        timer?.cancel()
        delegate?.didCloseTcpConnection(self)
    }

    /// The complete first frame is the whole stateless transaction. Close even if the sender
    /// keeps its side open; TCP EOF is a courtesy, not a prerequisite.
    fileprivate func didReceiveFrame(_ data: Data, from host: String) {
        // The deadline or a server stop may have ended this connection while the frame was
        // being read; it is then no longer delivered.
        finishLock.lock()
        let isOver = hasFinished
        finishLock.unlock()
        guard !isOver else { return }
        delegate?.didReceiveTcpConnectionData(data, from: host)
        finish()
    }

    private func scheduleTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.finish()
        }
        timer.resume()

        finishLock.lock()
        if hasFinished {
            finishLock.unlock()
            timer.cancel()
            return
        }
        timeoutTask = timer
        finishLock.unlock()
    }
}

/// Collects exactly one length-prefixed application frame. TCP can split this frame across
/// packets, so bytes are buffered until the header and then the whole body are present. What
/// it must not do is read a second application frame on the same connection: that would be a
/// session.
@available(macOS 10.14, iOS 12.0, *)
private final class TCPFrameReceiver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let connection: TCPConnection
    private var buffer: ByteBuffer?
    private var frameSize: Int?

    init(connection: TCPConnection) {
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if buffer == nil {
            buffer = incoming
        } else {
            buffer!.writeBuffer(&incoming)
        }

        if frameSize == nil {
            guard let size = buffer!.readInteger(endianness: .big, as: UInt32.self) else { return }

            // A nonsense length means we are out of step with the sender; there is no way
            // back from that on this connection.
            guard size > 0, Int(size) <= connection.maxSize else {
                print("TCP framing: refusing a \(size) byte message (max \(connection.maxSize))")
                connection.finish()
                return
            }
            frameSize = Int(size)
        }

        guard let size = frameSize, let bytes = buffer!.readBytes(length: size) else { return }
        let host = context.remoteAddress?.ipAddress ?? invalidHost
        connection.didReceiveFrame(Data(bytes), from: host)
    }

    // A clean close before a complete frame is the normal end of a conversation, not a fault.
    func channelInactive(context: ChannelHandlerContext) {
        connection.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("TCP receive: \(error)")
        connection.finish()
    }
}

#endif
