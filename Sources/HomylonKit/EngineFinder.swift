// Finding the Homylon engine.
//
// The order, in every Homylon app:
//
//   1. Bonjour (_homylon._tcp), always first. It is right at home, and it follows the engine
//      when the engine moves to another machine. A Bonjour find wins at any moment.
//   2. When Bonjour finds nothing (over a VPN, from another network): the last engine that
//      actually answered.
//   3. Then the address from the app's settings.
//
// A fallback that stays silent for `fallbackPatience` makes way for the next. Call
// `engineAnswered()` whenever the engine says anything; that is also what makes an engine
// "the last one that answered".

import Foundation

#if canImport(Darwin)

public final class EngineFinder: NSObject {

    public enum Source: String {
        case found = "found"
        case lastAnswered = "last engine that answered"
        case settings = "address from settings"
    }

    public struct Engine: Equatable {
        public let address: String
        public let tcpPort: Int
        public let source: Source
        /// The engine listens for UDP one above its TCP port.
        public var udpPort: Int { tcpPort + 1 }
        public var description: String { "\(address):\(tcpPort) (\(source.rawValue))" }
    }

    /// Called on the main queue whenever the engine to talk to changes.
    public var onEngine: ((Engine) -> Void)?

    public private(set) var engine: Engine?

    /// How long Bonjour gets at start before the fallbacks are tried.
    public var bonjourGrace: TimeInterval = 4
    /// How long a fallback may stay silent before the next one is tried.
    public var fallbackPatience: TimeInterval = 10

    private let lastAddressKey: String
    private let lastPortKey: String
    private let settingsAddress: () -> String?
    private let defaultPort: Int

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private var timer: Timer?
    private var startedAt = Date()
    private var usingSince: Date?
    private var answeredSinceUse = false

    /// - Parameters:
    ///   - storageKey: prefix for remembering the last engine that answered, e.g. "HomylonMonitor".
    ///   - defaultPort: the engine's TCP port when only an address is known.
    ///   - settingsAddress: the address from the app's settings, read each time it is needed.
    public init(storageKey: String, defaultPort: Int = 55050,
                settingsAddress: @escaping () -> String?) {
        lastAddressKey = storageKey + ".lastEngineAddress"
        lastPortKey = storageKey + ".lastEnginePort"
        self.defaultPort = defaultPort
        self.settingsAddress = settingsAddress
        super.init()
    }

    public func start() {
        startedAt = Date()
        browser.delegate = self
        browser.searchForServices(ofType: "_homylon._tcp.", inDomain: "local.")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        browser.stop()
        resolving.removeAll()
    }

    /// The engine said something. Remembers it as the last engine that answered.
    public func engineAnswered() {
        answeredSinceUse = true
        guard let engine else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastAddressKey) != engine.address
            || defaults.integer(forKey: lastPortKey) != engine.tcpPort {
            defaults.set(engine.address, forKey: lastAddressKey)
            defaults.set(engine.tcpPort, forKey: lastPortKey)
        }
    }

    /// The settings address changed: an engine Bonjour found stands, otherwise choose again.
    public func settingsChanged() {
        guard engine?.source != .found else { return }
        engine = nil
        tryNextFallback()
    }

    // MARK: - choosing

    private func use(_ candidate: Engine) {
        usingSince = Date()
        answeredSinceUse = false
        guard candidate != engine else { return }
        engine = candidate
        onEngine?(candidate)
    }

    private func fallbacks() -> [Engine] {
        var list: [Engine] = []
        let defaults = UserDefaults.standard
        if let address = defaults.string(forKey: lastAddressKey), !address.isEmpty {
            let port = defaults.integer(forKey: lastPortKey)
            list.append(Engine(address: address, tcpPort: port > 0 ? port : defaultPort, source: .lastAnswered))
        }
        if let address = settingsAddress()?.trimmingCharacters(in: .whitespaces), !address.isEmpty,
           !list.contains(where: { $0.address == address }) {
            list.append(Engine(address: address, tcpPort: defaultPort, source: .settings))
        }
        return list
    }

    private func tryNextFallback() {
        let list = fallbacks()
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0 == engine }
        use(current.map { list[($0 + 1) % list.count] } ?? list[0])
    }

    private func tick() {
        guard let engine else {
            if Date().timeIntervalSince(startedAt) >= bonjourGrace { tryNextFallback() }
            return
        }
        if engine.source != .found, !answeredSinceUse, let since = usingSince,
           Date().timeIntervalSince(since) > fallbackPatience, fallbacks().count > 1 {
            tryNextFallback()
        }
    }

    private static func ipv4(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
            guard family == sa_family_t(AF_INET) else { return nil }
            var address = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: text)
        }
    }
}

extension EngineFinder: NetServiceBrowserDelegate, NetServiceDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                                  moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceDidResolveAddress(_ service: NetService) {
        resolving.removeAll { $0 === service }
        guard let ip = service.addresses?.compactMap({ Self.ipv4(from: $0) }).first else { return }
        use(Engine(address: ip, tcpPort: service.port, source: .found))
    }

    public func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === service }
    }
}

#endif
