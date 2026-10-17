// The Homylon transport on Apple platforms (Network.framework): UDP datagrams, and TCP with one
// length-prefixed message per connection (a 4-byte big-endian length, the JSON, then a FIN).
//
// Taken from the Homylon Engine's NetworkServices+Apple.swift, so apps and the engine speak with
// exactly the same code. The rules themselves: https://homylon.org/index.php/homylon-protocol

import Foundation

#if canImport(Network) && !HOMYLON_NIO
import Network

import Network

/// Shown at startup, so it is always clear which transport an engine was built with.
public let networkTransportName = "Network.framework"

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
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let data: Data
    private let timeout: DispatchTimeInterval
    private let didFinish: (UUID, NWError?) -> Void
    private let finishLock = NSLock()
    private var hasStartedSending = false
    private var hasFinished = false
    private var timeoutTask: DispatchSourceTimer?

    init(id: UUID, ip: String, port: Int, data: Data, queue: DispatchQueue,
         timeout: DispatchTimeInterval, didFinish: @escaping (UUID, NWError?) -> Void) {
        self.id = id
        self.connection = NWConnection(host: NWEndpoint.Host(ip),
                                       port: NWEndpoint.Port(String(port))!, using: .udp)
        self.queue = queue
        self.data = data
        self.timeout = timeout
        self.didFinish = didFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendOnce()
            case .failed(let error):
                self.finish(error: error)
            case .cancelled:
                self.finish(error: nil)
            default:
                break
            }
        }
        scheduleTimeout()
        connection.start(queue: queue)
    }

    private func sendOnce() {
        finishLock.lock()
        guard !hasFinished, !hasStartedSending else { finishLock.unlock(); return }
        hasStartedSending = true
        finishLock.unlock()

        connection.send(content: data, isComplete: true, completion: .contentProcessed { [weak self] error in
            self?.finish(error: error)
        })
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
        finishLock.lock()
        guard !hasFinished else { finishLock.unlock(); return }
        hasFinished = true
        timer = timeoutTask
        timeoutTask = nil
        finishLock.unlock()
        timer?.cancel()
        connection.cancel()
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
    private var listener: NWListener?
    private var listenerQueue: DispatchQueue?
    
    public init() {}
    
    public func start(onPort: UInt16, queue: DispatchQueue, maxRetries: Int = 3) {
        self.listenerQueue = queue
        var retries = 0
        
        func attemptStart() {
            let udpParameters = NWParameters.udp
            guard let port = NWEndpoint.Port(rawValue: onPort) else {
                let error = NSError(domain: "UDPServerError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid port number"])
                handleStartFailure(error: error)
                return
            }
            
            do {
                listener = try NWListener(using: udpParameters, on: port)
            } catch {
                handleStartFailure(error: error)
                return
            }
            
            configureListener(port: onPort)
        }
        
        queue.async {
            attemptStart()
        }
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        let closeAll = { [weak self] in
            guard let self = self else { return }
            self.openConnections.values.map { $0.connection }.forEach { self.close($0) }
        }
        if Thread.isMainThread { closeAll() } else { DispatchQueue.main.async(execute: closeAll) }
        print("UDP server stopped")
    }
    
    private func configureListener(port: UInt16) {
        listener?.newConnectionHandler = handleNewConnection
        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleListenerStateUpdate(state: state, port: port)
        }
        
        listener?.start(queue: listenerQueue!)
    }
    
    /// One NWConnection is one sender (its address and port). It keeps reading until the sender
    /// has been quiet for `idleTime`: closing it after the first message lost every message the
    /// same sender sent right behind it (1 of 20 arrived in a burst test).
    private let idleTime: TimeInterval = 10
    /// The open senders and the timer that closes each one; only touched on the main queue.
    private var openConnections: [ObjectIdentifier: (connection: NWConnection, idle: DispatchWorkItem)] = [:]

    private func handleNewConnection(connection: NWConnection) {
        connection.start(queue: .main)
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] (data, _, _, error) in
            guard let self = self else {
                connection.cancel()
                return
            }
            if let error = error {
                // A sender closed for being quiet ends its last read this way: not an error.
                if error != NWError.posix(.ECANCELED) {
                    print("Error receiving UDP message: \(error)")
                }
                self.close(connection)
                return
            }
            if let data = data {
                self.delegate?.udpDidReceiveData(data, from: connection.getHost())
            }
            self.closeWhenIdle(connection)
            self.receiveNext(on: connection)
        }
    }

    /// (Re)starts the quiet timer of this sender.
    private func closeWhenIdle(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        openConnections[key]?.idle.cancel()
        let idle = DispatchWorkItem { [weak self] in self?.close(connection) }
        openConnections[key] = (connection, idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTime, execute: idle)
    }

    private func close(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        openConnections[key]?.idle.cancel()
        openConnections[key] = nil
        connection.cancel()
    }
    
    private func handleListenerStateUpdate(state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            print("UDP server started successfully on port \(port)")
            delegate?.udpDidStartSuccessfully(onPort: Int(port))
        case .failed(let error):
            handleStartFailure(error: error)
        case .setup:
            print("UDP server is setting up")
        case .cancelled:
            print("UDP server was cancelled")
        case .waiting(let error):
            print("UDP server is waiting: \(error)")
        @unknown default:
            print("UDP server entered an unknown state")
        }
    }
    
    private func handleStartFailure(error: Error) {
        print("UDP server failed to start: \(error)")
        DispatchQueue.main.async {
            self.delegate?.udpDidFailToStartWithError(error)
        }
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
@available(macOS 10.14, iOS 12.0, *)
private final class TCPTransmission {
    private let id: UUID
    private let ip: String
    private let port: Int
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let data: Data
    private let timeout: DispatchTimeInterval
    private let didFinish: (UUID, Bool) -> Void
    private let finishLock = NSLock()
    private var hasStartedSending = false
    private var hasFinished = false
    private var timeoutTask: DispatchSourceTimer?

    init(id: UUID, ip: String, port: Int, data: Data, queue: DispatchQueue,
         timeout: DispatchTimeInterval, didFinish: @escaping (UUID, Bool) -> Void) {
        self.id = id
        self.ip = ip
        self.port = port
        self.connection = NWConnection(host: NWEndpoint.Host(ip),
                                       port: NWEndpoint.Port(String(port))!, using: .tcp)
        self.queue = queue
        self.data = data
        self.timeout = timeout
        self.didFinish = didFinish
    }

    func matches(ip: String, port: Int) -> Bool {
        return self.ip == ip && self.port == port
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendOneFrame()
            case .failed:
                self.finish(wasSuccessful: false)
            case .cancelled:
                self.finish(wasSuccessful: false)
            default:
                // `.waiting` is allowed only until this transaction's fixed deadline. The
                // client never re-starts or reuses it afterwards.
                break
            }
        }
        scheduleTimeout()
        connection.start(queue: queue)
    }

    func cancel() {
        finish(wasSuccessful: false)
    }

    private func sendOneFrame() {
        finishLock.lock()
        guard !hasFinished, !hasStartedSending else { finishLock.unlock(); return }
        hasStartedSending = true
        finishLock.unlock()

        let length = UInt32(data.count)
        let lengthData = withUnsafeBytes(of: length.bigEndian) { Data($0) }
        var frame = lengthData
        frame.append(data)

        connection.send(content: frame, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            guard error == nil else {
                self.finish(wasSuccessful: false)
                return
            }
            self.sendFinalMessage()
        })
    }

    private func sendFinalMessage() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            self?.finish(wasSuccessful: error == nil)
        })
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
        finishLock.lock()
        guard !hasFinished else { finishLock.unlock(); return }
        hasFinished = true
        timer = timeoutTask
        timeoutTask = nil
        finishLock.unlock()
        timer?.cancel()
        connection.cancel()
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
    
    var listener : NWListener?
    var connection : NWConnection?
    private var listenerQueue: DispatchQueue?
    private var connections: [TCPConnection] = []
    /// `connections` is appended from the listener's queue and removed from whichever
    /// network callback happens to end a connection. Without this it is an unsynchronised
    /// array mutated from several threads, which crashes under load rather than leaking
    /// quietly - it only looked stable before because connections were almost never removed.
    private let connectionsLock = DispatchQueue(label: "com.homylon.tcpserver.connections")
    
    public init() {
        // TODO:
    }
    
    public func start(onPort: UInt16, queue: DispatchQueue, maxRetries: Int = 3) {
        self.listenerQueue = queue
        var retries = 0
        
        func attemptStart() {
            let tcpParameters = NWParameters.tcp
            let port = NWEndpoint.Port(rawValue: onPort)!
            
            do {
                listener = try NWListener(using: tcpParameters, on: port)
            } catch {
                print("Failed to create TCP listener on port \(onPort): \(error)")
                DispatchQueue.main.async {
                    self.delegate?.tcpDidFailToStartWithError(error)
                }
                return
            }
            
            print("Attempting to start TCP listener on port \(onPort)")
            
            listener?.newConnectionHandler = { [weak self] connection in
                print("New TCP connection from \(connection.endpoint)")
                self?.handleNewConnection(connection)
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("TCP server started successfully on port \(onPort)")
                    DispatchQueue.main.async {
                        self.delegate?.tcpDidStartSuccessfully(onPort: Int(onPort))
                    }
                case .failed(let error):
                    print("TCP server failed to start: \(error)")
                    if retries < maxRetries {
                        retries += 1
                        print("Retrying TCP server start (attempt \(retries))")
                        self.listenerQueue?.asyncAfter(deadline: .now() + 1.0) {
                            attemptStart()
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.delegate?.tcpDidFailToStartWithError(error)
                        }
                    }
                case .setup:
                    print("TCP server is setting up")
                case .cancelled:
                    print("TCP server was cancelled")
                case .waiting(let error):
                    print("TCP server is waiting: \(error)")
                @unknown default:
                    print("TCP server entered an unknown state")
                }
            }
            
            listener?.start(queue: self.listenerQueue!)
        }
        
        queue.async {
            attemptStart()
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let tcpConnection = TCPConnection()
        tcpConnection.delegate = self
        connectionsLock.sync { connections.append(tcpConnection) }
        tcpConnection.didAccept(nwConnection)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
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

    
    // Consolidated function to handle .failed and .waiting states
    private func handleStateError(_ state: NWListener.State, error: NWError) {
        // this obviously does not work because "error" is either invalid or reports "Network is down" all the time
        let isPortInUse = (error == NWError.posix(POSIXErrorCode.EADDRINUSE))
        let message = isPortInUse ? "TCP port waiting. Could be due to an already in use port" : "Failed with error"
        
        // print("Debug \(message): \(error)") // Print the error for debugging purposes
        self.delegate?.tcpDidReportMessage(message)
        self.delegate?.tcpDidFailToStartWithError(error)
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
    private var acceptedConnection: NWConnection?
    private var timeoutTask: DispatchSourceTimer?
    private let maxSize: Int = 1_000_000 // a light list for a large house is a few KB; this is headroom
    private let timeout: DispatchTimeInterval = .seconds(3)
    
    public init() {
    }

    func reset() {
        close()
    }

    func close() {
        let connection: NWConnection?
        finishLock.lock()
        connection = acceptedConnection
        finishLock.unlock()
        if let connection = connection {
            finish(connection)
        }
    }
    
    func didAccept(_ connection: NWConnection) {
        finishLock.lock()
        guard !hasFinished else { finishLock.unlock(); connection.cancel(); return }
        acceptedConnection = connection
        finishLock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .failed, .cancelled:
                self.finish(connection)
            default:
                break
            }
        }

        // This bounds the complete transaction, including a client that sends only part of
        // a length prefix/body and then disappears. No accepted TCP connection may outlive it.
        scheduleTimeout(for: connection)
        connection.start(queue: queue)
        receiveOneFrame(connection)
    }
    
    /// Let go of an accepted connection, exactly once.
    ///
    /// Every path out of the read loop has to come through here. It used to `return` on an
    /// error, and on a nil read, without cancelling - and a peer closing cleanly hands back
    /// data == nil with NO error, so an ordinary disconnect abandoned the socket. One file
    /// descriptor per connection, forever, until the engine died with "Too many open files".
    private func finish(_ connection: NWConnection) {
        let timer: DispatchSourceTimer?
        finishLock.lock()
        if hasFinished { finishLock.unlock(); return }
        hasFinished = true
        acceptedConnection = nil
        timer = timeoutTask
        timeoutTask = nil
        finishLock.unlock()
        connection.cancel()
        timer?.cancel()
        delegate?.didCloseTcpConnection(self)
    }
    
    /// Receive exactly one length-prefixed application frame. TCP can split this frame across
    /// packets; Network buffers until the requested bytes are available. What it must not do
    /// here is read a second application frame on the same connection: that would be a session.
    private func receiveOneFrame(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { (data, _, _, error) in
            if let error = error {
                print("TCP receive (header): \(error)")
                self.finish(connection)
                return
            }

            // A clean close arrives as nil data with no error, which is the normal end of a
            // conversation rather than a fault.
            guard let data = data, data.count >= 4 else {
                self.finish(connection)
                return
            }

            let size = data.withUnsafeBytes({ $0.load(as: UInt32.self) }).bigEndian
            
            // A nonsense length means we are out of step with the sender; there is no way
            // back from that on this connection.
            guard size > 0, Int(size) <= self.maxSize else {
                print("TCP framing: refusing a \(size) byte message (max \(self.maxSize))")
                self.finish(connection)
                return
            }

            connection.receive(minimumIncompleteLength: Int(size), maximumLength: Int(size)) { (data, _, _, error) in
                if let error = error {
                    print("TCP receive (body): \(error)")
                    self.finish(connection)
                    return
                }

                guard let data = data, data.count == Int(size) else {
                    self.finish(connection)
                    return
                }

                let host = connection.getHost()
                self.delegate?.didReceiveTcpConnectionData(data, from: host)
                // The complete first frame is the whole stateless transaction. Close even if
                // the sender keeps its side open; TCP EOF is a courtesy, not a prerequisite.
                self.finish(connection)
            }
        }
    }

    private func scheduleTimeout(for connection: NWConnection) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self, weak connection] in
            guard let self = self, let connection = connection else { return }
            self.finish(connection)
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

@available(macOS 10.14, iOS 12.0, *)
extension NWConnection {
    func getHost() -> String {
        switch(self.endpoint) {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            break
        }
        return "not.a.valid.address"
    }
}

#endif
