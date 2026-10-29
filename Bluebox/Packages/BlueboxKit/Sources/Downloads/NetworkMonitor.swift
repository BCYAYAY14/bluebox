import Foundation
import Network

/// The current network path, reduced to what Bluebox decides on.
public struct NetworkPathInfo: Sendable, Equatable {
    public var isOnline: Bool
    /// Cellular, or a personal hotspot the system marks as expensive.
    public var isExpensive: Bool
    /// Low Data Mode is on for this network.
    public var isConstrained: Bool
    public var usesCellular: Bool
    public var usesWiFi: Bool

    public init(isOnline: Bool = true, isExpensive: Bool = false, isConstrained: Bool = false,
                usesCellular: Bool = false, usesWiFi: Bool = false) {
        self.isOnline = isOnline; self.isExpensive = isExpensive; self.isConstrained = isConstrained
        self.usesCellular = usesCellular; self.usesWiFi = usesWiFi
    }

    /// Mobile data as Settings › Mobile Data means it: cellular, an expensive
    /// network such as a phone's hotspot, or any network in Low Data Mode.
    public var isMobileData: Bool { isOnline && (isExpensive || isConstrained || (usesCellular && !usesWiFi)) }

    init(_ path: NWPath) {
        isOnline = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        usesCellular = path.usesInterfaceType(.cellular)
        usesWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
    }
}

/// Reports whether the device is online and whether the connection counts as
/// mobile data, for Wi‑Fi Only downloads and Settings › Mobile Data.
public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.bluebox.network")

    public init() {}

    /// Calls `onChange` on a background queue with every path change (and once at start).
    public func start(_ onChange: @escaping @Sendable (NetworkPathInfo) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(NetworkPathInfo(path)) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
