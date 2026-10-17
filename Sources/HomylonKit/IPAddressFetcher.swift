// This device's local IPv4 addresses, e.g. to show in an app's header.
//
// The kit contacts nothing outside the house: there is no lookup of the public (internet)
// address here, because that would make every app built with the kit call some server.

import Foundation

public let LocalIPAddressesFetchedNotification = "LocalIPAddressesFetched"

public final class IPAddressFetcher {

    /// Posts LocalIPAddressesFetched with userInfo["LocalIPAddresses"].
    public static func getLocalIPAddresses() {
        getLocalIPAddresses { addresses in
            NotificationCenter.default.post(name: Notification.Name(LocalIPAddressesFetchedNotification),
                                            object: nil, userInfo: ["LocalIPAddresses": addresses])
        }
    }

    public static func getLocalIPAddresses(completion: @escaping ([Any]) -> Void) {
        DispatchQueue.global().async {
            let addresses = localIPv4Addresses()
            DispatchQueue.main.async { completion(addresses) }
        }
    }

    /// Apple devices report their Ethernet and Wi-Fi interfaces (en0, en1); a phone's cellular
    /// and VPN interfaces are left out. Linux names its interfaces differently (enp3s0, wlan0,
    /// ...), so there every address except loopback counts.
    private static func isReported(_ interfaceName: String) -> Bool {
        #if canImport(Darwin)
        return interfaceName == "en0" || interfaceName == "en1"
        #else
        return interfaceName != "lo"
        #endif
    }

    private static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return addresses }
        defer { freeifaddrs(interfaces) }

        var cursor = interfaces
        while let interface = cursor {
            if let address = interface.pointee.ifa_addr,
               address.pointee.sa_family == sa_family_t(AF_INET),
               isReported(String(cString: interface.pointee.ifa_name)) {
                var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                    addresses.append(String(cString: text))
                }
            }
            cursor = interface.pointee.ifa_next
        }
        return addresses
    }
}
