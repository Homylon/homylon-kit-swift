import XCTest
@testable import HomylonKit

final class HomylonKitTests: XCTestCase {
    func testLocalAddressTowardLoopbackIsLoopback() {
        XCTAssertEqual(localAddress(toward: "127.0.0.1"), "127.0.0.1")
    }

    func testLocalAddressRejectsNonsense() {
        XCTAssertNil(localAddress(toward: "not an address"))
    }

    /// A TCP message sent with the kit arrives at a kit TCP server as exactly one message.
    func testTCPRoundTrip() {
        final class Receiver: TCPServerDelegate {
            let arrived: XCTestExpectation
            var body: String?
            init(_ arrived: XCTestExpectation) { self.arrived = arrived }
            func tcpDidReceiveData(_ data: Data?, from: String) {
                body = data.flatMap { String(data: $0, encoding: .utf8) }
                arrived.fulfill()
            }
            func tcpDidFailToStartWithError(_ error: Error) { XCTFail("\(error)") }
            func tcpDidStartSuccessfully(onPort: Int) {}
            func tcpDidReportMessage(_ message: String) {}
        }
        let arrived = expectation(description: "message arrived")
        let receiver = Receiver(arrived)
        let server = TCPServer()
        server.delegate = receiver
        server.start(onPort: 56411, queue: DispatchQueue(label: "test.tcp"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Homylon.send(["action": "hello"], to: "127.0.0.1", port: 56411, over: .tcp)
        }
        wait(for: [arrived], timeout: 10)
        XCTAssertTrue(receiver.body?.contains("\"action\":\"hello\"") ?? false)
        XCTAssertTrue(receiver.body?.contains("\"timestamp\"") ?? false)
        server.stop()
    }

    /// A UDP message sent with the kit arrives at a kit UDP server, whole.
    func testUDPRoundTrip() {
        final class Receiver: UDPServerDelegate {
            let arrived: XCTestExpectation
            var body: String?
            init(_ arrived: XCTestExpectation) { self.arrived = arrived }
            func udpDidReceiveData(_ data: Data?, from: String) {
                body = data.flatMap { String(data: $0, encoding: .utf8) }
                arrived.fulfill()
            }
            func udpDidFailToStartWithError(_ error: Error) { XCTFail("\(error)") }
            func udpDidStartSuccessfully(onPort: Int) {}
        }
        print("Transport: \(networkTransportName)")
        let arrived = expectation(description: "message arrived")
        let receiver = Receiver(arrived)
        let server = UDPServer()
        server.delegate = receiver
        server.start(onPort: 56412, queue: DispatchQueue(label: "test.udp"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Homylon.send(["action": "hello"], to: "127.0.0.1", port: 56412, over: .udp)
        }
        wait(for: [arrived], timeout: 10)
        XCTAssertTrue(receiver.body?.contains("\"action\":\"hello\"") ?? false)
        server.stop()
    }

    /// Twenty messages sent back to back from ONE socket all arrive. The Apple transport used
    /// to close a sender after its first message, and then only 1 of the 20 arrived.
    func testUDPBurstFromOneSocket() {
        final class Receiver: UDPServerDelegate {
            let arrived: XCTestExpectation
            init(_ arrived: XCTestExpectation) { self.arrived = arrived }
            func udpDidReceiveData(_ data: Data?, from: String) { arrived.fulfill() }
            func udpDidFailToStartWithError(_ error: Error) { XCTFail("\(error)") }
            func udpDidStartSuccessfully(onPort: Int) {}
        }
        let arrived = expectation(description: "all 20 arrived")
        arrived.expectedFulfillmentCount = 20
        arrived.assertForOverFulfill = true
        let receiver = Receiver(arrived)
        let server = UDPServer()
        server.delegate = receiver
        server.start(onPort: 56413, queue: DispatchQueue(label: "test.burst"))

        let port: UInt16 = 56413
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            #if canImport(Glibc)
            let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
            #else
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            #endif
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            for n in 0..<20 {
                let message = Array("{\"n\":\(n)}".utf8)
                _ = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            close(fd)
        }
        wait(for: [arrived], timeout: 10)
        server.stop()
    }
}
