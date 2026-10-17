// Sending a message to the Homylon engine: the JSON, a timestamp, and the security key when
// the house uses one. Small messages go by UDP, large ones by TCP (one message per connection).

import Foundation

public enum HomylonTransport: String {
    case udp
    case tcp
}

public enum Homylon {
    /// Sends `message` to `address`:`port`. Adds "timestamp" (seconds since 1970) and, when
    /// given, "securityKey". `completion` reports whether the message left this device.
    public static func send(_ message: [String: Any], to address: String, port: Int,
                            over transport: HomylonTransport = .udp, securityKey: String? = nil,
                            completion: ((Bool) -> Void)? = nil) {
        guard !address.isEmpty, (1...65535).contains(port) else {
            completion?(false)
            return
        }
        var signed = message
        signed["timestamp"] = Int(Date().timeIntervalSince1970)
        if let securityKey, !securityKey.isEmpty { signed["securityKey"] = securityKey }
        guard let data = try? JSONSerialization.data(withJSONObject: signed),
              let json = String(data: data, encoding: .utf8) else {
            completion?(false)
            return
        }
        switch transport {
        case .udp:
            UDPClient.shared.sendMessage(to: address, onPort: port, message: json) { error in
                completion?(error == nil)
            }
        case .tcp:
            TCPClient.shared.sendMessage(to: address, onPort: port, message: json) { ok in
                completion?(ok)
            }
        }
    }
}
