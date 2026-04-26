import Foundation
import Darwin
import SystemConfiguration

// IPv4 / IPv6 / public-IP / ISP / gateway / DNS collection. Pure data —
// nothing here touches @Published state or the main thread (the public-IP
// fetch is async and returns a struct; the caller applies it).

enum Identity {

    // MARK: - Local addresses

    struct IPInfo {
        var v4: String        = "--"
        var v6: String        = "--"
        var subnet: String    = "--"
        var bestIface: String = "--"
    }

    /// Walks interfaces and picks the highest-priority IPv4/IPv6 address.
    /// fe80:: link-local, ::1 loopback and scope-IDs (`%enX`) are filtered
    /// out so the user-facing IPv6 string is always a real GUA.
    static func collectIPs() -> IPInfo {
        var info = IPInfo()
        var currentV4Priority = 0
        var currentV6Priority = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return info }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name  = String(cString: ifa.pointee.ifa_name)
            let flags = Int32(ifa.pointee.ifa_flags)
            guard (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_UP) != 0,
                  let addr = ifa.pointee.ifa_addr else { continue }

            let prio   = Stats.ifPriority(name)
            let family = Int32(addr.pointee.sa_family)

            if family == AF_INET {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0, prio > currentV4Priority {
                    info.v4 = String(cString: host)
                    info.bestIface = name
                    currentV4Priority = prio
                }
                if let netmask = ifa.pointee.ifa_netmask, prio >= currentV4Priority - 1 {
                    var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(netmask, socklen_t(netmask.pointee.sa_len),
                                   &mask, socklen_t(mask.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        info.subnet = String(cString: mask)
                    }
                }
            } else if family == AF_INET6 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                // sa_len can be zero on some macOS builds — use the concrete struct size.
                let addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(addr, addrLen, &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    let bare = ip.components(separatedBy: "%").first ?? ip
                    if !bare.hasPrefix("fe80"), bare != "::1", prio > currentV6Priority {
                        info.v6 = bare.count > 30 ? String(bare.prefix(28)) + "…" : bare
                        currentV6Priority = prio
                    }
                }
            }
        }
        return info
    }

    // MARK: - Gateway / DNS

    struct NetConfig {
        var gateway: String = "--"
        var dns: [String]   = []
    }

    /// Pulls the active default-route gateway and up to 3 system DNS servers
    /// from SCDynamicStore.
    static func collectNetworkConfig() -> NetConfig {
        var config = NetConfig()
        guard let store = SCDynamicStoreCreate(nil, "SwiftMeter" as CFString, nil, nil) else {
            return config
        }

        let ipv4Key = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil, kSCDynamicStoreDomainState, kSCEntNetIPv4)
        if let val = SCDynamicStoreCopyValue(store, ipv4Key) as? [String: Any],
           let router = val["Router"] as? String {
            config.gateway = router
        }

        let dnsKey = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil, kSCDynamicStoreDomainState, kSCEntNetDNS)
        if let val = SCDynamicStoreCopyValue(store, dnsKey) as? [String: Any],
           let servers = val["ServerAddresses"] as? [String] {
            config.dns = Array(servers.prefix(3))
        }

        return config
    }

    // MARK: - Public IP / ISP / Geolocation

    struct PublicInfo {
        var ip:      String = "--"
        var isp:     String = "--"
        var city:    String = "--"
        var region:  String = "--"
        var country: String = "--"
    }

    private struct IPInfoResponse: Decodable {
        let ip:      String?
        let city:    String?
        let region:  String?
        let country: String?
        let org:     String?  // "AS7922 Comcast Cable Communications"
    }

    /// One-shot fetch of public IP + geo + ISP from ipinfo.io. Returns nil
    /// on any error so the caller can decide how to surface failure.
    static func fetchPublic() async -> PublicInfo? {
        do {
            let url     = URL(string: "https://ipinfo.io/json")!
            let request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 10)
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let info = try? JSONDecoder().decode(IPInfoResponse.self, from: data) else {
                return nil
            }
            var out = PublicInfo()
            out.ip      = info.ip      ?? "--"
            out.city    = info.city    ?? "--"
            out.region  = info.region  ?? "--"
            out.country = info.country ?? "--"
            // "AS7922 Comcast Cable" → strip leading ASN token
            if let org = info.org {
                let parts = org.split(separator: " ", maxSplits: 1)
                out.isp = parts.count > 1 ? String(parts[1]) : org
            }
            return out
        } catch {
            return nil
        }
    }
}
