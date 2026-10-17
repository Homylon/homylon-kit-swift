// Which address of this device another machine can reach it on.

import Foundation

/// The address of this device that traffic to `host` leaves from - the one to give the engine
/// when registering. Asks the operating system's routing; nothing is sent. Nil when it cannot tell.
public func localAddress(toward host: String) -> String? {
    var remote = sockaddr_in()
    remote.sin_family = sa_family_t(AF_INET)
    remote.sin_port = in_port_t(9).bigEndian
    guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }
    #if canImport(Glibc)
    let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    #endif
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    let connected = withUnsafePointer(to: &remote) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil }
    var local = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { return nil }
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &local.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
    let address = String(cString: text)
    return address == "0.0.0.0" ? nil : address
}
