import Foundation
import Darwin

// Pure byte-counter collector. No @Published state, no main-thread requirement.
// NetworkMonitor's tick() calls Stats.collect() on a background queue; the
// returned struct is then applied on the main thread.

enum Stats {

    struct Raw {
        var ibytes: UInt64        = 0
        var obytes: UInt64        = 0
        var ipackets: UInt32      = 0
        var opackets: UInt32      = 0
        var errors: UInt32        = 0
        var bestInterface: String = "--"
        var bestPriority: Int     = 0
    }

    /// Walks all up, non-loopback interfaces and sums AF_LINK byte/packet
    /// counters. Picks the highest-priority interface name (en0 > en1 > rest)
    /// as `bestInterface`.
    static func collect() -> Raw {
        var result = Raw()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name  = String(cString: ifa.pointee.ifa_name)
            let flags = Int32(ifa.pointee.ifa_flags)
            guard (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_UP) != 0 else { continue }

            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let rawData = ifa.pointee.ifa_data else { continue }

            let s = rawData.load(as: if_data.self)
            result.ibytes   += UInt64(s.ifi_ibytes)
            result.obytes   += UInt64(s.ifi_obytes)
            result.ipackets += s.ifi_ipackets
            result.opackets += s.ifi_opackets
            result.errors   += s.ifi_ierrors + s.ifi_oerrors

            let prio = Stats.ifPriority(name)
            if prio > result.bestPriority {
                result.bestInterface = name
                result.bestPriority  = prio
            }
        }
        return result
    }

    /// Stable interface ranking: en0 wins, then en1, then anything else.
    static func ifPriority(_ name: String) -> Int {
        switch name {
        case "en0": return 3
        case "en1": return 2
        default:    return 1
        }
    }
}
