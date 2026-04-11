import Foundation
import AppKit
import Darwin
import CoreWLAN
import CoreLocation
import SystemConfiguration
import Network

// MARK: - Data Models

struct SpeedSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let download: Double  // bytes/sec
    let upload: Double    // bytes/sec
}

// MARK: - Network Monitor

class NetworkMonitor: NSObject, ObservableObject {

    // Speed
    @Published var downloadSpeed: Double = 0
    @Published var uploadSpeed: Double = 0
    @Published var downloadSpeedString: String = "0 B/s"
    @Published var uploadSpeedString: String = "0 B/s"
    @Published var speedHistory: [SpeedSample] = []

    // IP
    @Published var ipv4Address: String = "--"
    @Published var ipv6Address: String = "--"
    @Published var publicIP: String    = "Fetching..."
    @Published var ispName: String     = "--"
    @Published var ipCity: String      = "--"
    @Published var ipRegion: String    = "--"
    @Published var ipCountry: String   = "--"
    @Published var subnetMask: String  = "--"

    // WiFi
    @Published var wifiSSID: String          = "--"
    @Published var wifiSignalPercent: Int    = 0
    @Published var wifiRSSI: Int             = 0
    @Published var wifiChannel: String       = "--"
    @Published var wifiBand: String          = "--"
    @Published var wifiTxRate: Double        = 0

    // Network config
    @Published var activeInterface: String   = "--"
    @Published var gateway: String           = "--"
    @Published var dnsServers: [String]      = []
    @Published var connectionType: ConnectionType = .unknown
    @Published var isConnected: Bool         = false

    // Session stats
    @Published var sessionDownload: UInt64   = 0
    @Published var sessionUpload: UInt64     = 0
    @Published var sessionStartDate: Date    = Date()
    @Published var packetsIn: UInt32         = 0
    @Published var packetsOut: UInt32        = 0
    @Published var networkErrors: UInt32     = 0

    // Latency
    @Published var latencyMs: Int            = -1
    @Published var latencyString: String     = "Measuring…"

    // MARK: Private

    private var timer: Timer?
    private var lastBytesIn: UInt64      = 0
    private var lastBytesOut: UInt64     = 0
    private var lastUpdateTime: Date     = Date()
    private var sessionDownloadAccum: Double = 0
    private var sessionUploadAccum: Double   = 0
    private var isFirstSample               = true
    private var tickCount: Int               = 0
    private var saveTickCount: Int           = 0

    private var wasConnected: Bool           = false
    private var isLatencyMeasuring: Bool     = false

    // WiFi SSID cached from shell (background-safe fallback)
    private var cachedSSID: String?          = nil

    // CoreLocation manager — grants CWWiFiClient.ssid() access on macOS 14+
    private var locationManager: CLLocationManager?

    private let nwPathMonitor = NWPathMonitor()
    private let bgQueue = DispatchQueue(label: "com.swiftmeter.monitor", qos: .utility)

    // MARK: - Connection Type

    enum ConnectionType: String {
        case wifi         = "Wi-Fi"
        case ethernet     = "Ethernet"
        case cellular     = "Cellular"
        case vpn          = "VPN"
        case unknown      = "Connected"
        case disconnected = "No Connection"

        var symbolName: String {
            switch self {
            case .wifi:         return "wifi"
            case .ethernet:     return "cable.connector.horizontal"
            case .cellular:     return "antenna.radiowaves.left.and.right"
            case .vpn:          return "lock.shield.fill"
            case .disconnected: return "wifi.slash"
            case .unknown:      return "network"
            }
        }
    }

    private struct IPInfoResponse: Decodable {
        let ip:      String?
        let city:    String?
        let region:  String?
        let country: String?
        let org:     String?   // "AS7922 Comcast Cable Communications"
    }

    // MARK: - Init

    override init() {
        super.init()
        loadSession()
        setupPathMonitor()
        setupLocationManager()   // request Location → unlocks CWWiFiClient.ssid()
        startTimer()
        Task { await fetchPublicIP() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.saveSession() }
    }

    deinit {
        timer?.invalidate()
        nwPathMonitor.cancel()
        saveSession()
    }

    // MARK: - Session Persistence

    private let kSessionDL    = "np.session.dl"
    private let kSessionUL    = "np.session.ul"
    private let kSessionStart = "np.session.start"

    private func loadSession() {
        let ud    = UserDefaults.standard
        let dl    = ud.double(forKey: kSessionDL)
        let ul    = ud.double(forKey: kSessionUL)
        let start = ud.double(forKey: kSessionStart)

        sessionDownloadAccum = dl > 0 ? dl : 0
        sessionUploadAccum   = ul > 0 ? ul : 0

        if start > 0 {
            sessionStartDate = Date(timeIntervalSince1970: start)
        } else {
            sessionStartDate = Date()
            ud.set(sessionStartDate.timeIntervalSince1970, forKey: kSessionStart)
        }

        sessionDownload = UInt64(sessionDownloadAccum)
        sessionUpload   = UInt64(sessionUploadAccum)
    }

    private func saveSession() {
        let ud = UserDefaults.standard
        ud.set(sessionDownloadAccum, forKey: kSessionDL)
        ud.set(sessionUploadAccum,   forKey: kSessionUL)
        ud.set(sessionStartDate.timeIntervalSince1970, forKey: kSessionStart)
        ud.synchronize()
    }

    func resetSession() {
        sessionDownloadAccum = 0
        sessionUploadAccum   = 0
        sessionStartDate     = Date()
        sessionDownload      = 0
        sessionUpload        = 0
        let ud = UserDefaults.standard
        ud.set(0.0, forKey: kSessionDL)
        ud.set(0.0, forKey: kSessionUL)
        ud.set(sessionStartDate.timeIntervalSince1970, forKey: kSessionStart)
    }

    // MARK: - Location Manager (unlocks CWWiFiClient.ssid() on macOS 14+)

    private func setupLocationManager() {
        // CLLocationManager must be created on the main thread
        DispatchQueue.main.async {
            let lm = CLLocationManager()
            lm.delegate = self
            self.locationManager = lm
            switch lm.authorizationStatus {
            case .notDetermined:
                lm.requestWhenInUseAuthorization()
            default:
                break
            }
        }
    }

    // MARK: - Path Monitor

    private func setupPathMonitor() {
        nwPathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let nowConnected = path.status == .satisfied
            DispatchQueue.main.async {
                let wasConn      = self.wasConnected
                self.isConnected = nowConnected
                self.wasConnected = nowConnected

                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .ethernet
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else if path.status == .satisfied {
                    self.connectionType = .unknown
                } else {
                    self.connectionType = .disconnected
                }

                // ── Network went DOWN: erase public WAN / ISP info ──────────
                if wasConn && !nowConnected {
                    self.publicIP  = "--"
                    self.ispName   = "--"
                    self.ipCity    = "--"
                    self.ipRegion  = "--"
                    self.ipCountry = "--"
                    self.cachedSSID = nil
                    self.wifiSSID   = "--"
                }

                // ── Network came UP: refresh public WAN / ISP info ──────────
                if !wasConn && nowConnected {
                    Task { await self.fetchPublicIP() }
                }
            }
        }
        nwPathMonitor.start(queue: bgQueue)
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.performUpdate()
        }
        RunLoop.main.add(timer!, forMode: .common)
        timer?.fire()
    }

    private func performUpdate() {
        tickCount += 1
        let currentTick = tickCount

        bgQueue.async { [weak self] in
            guard let self else { return }

            let stats   = self.collectNetStats()
            let ips     = self.collectIPAddresses()
            let netConf = self.collectNetworkConfig()

            // Fetch WiFi SSID via networksetup (blocking but bg-safe).
            // Run on tick 1 and every 5 ticks, or whenever SSID is unknown.
            let shellSSID: String? = (currentTick == 1 || currentTick % 5 == 0)
                ? self.fetchSSIDViaNetworkSetup()
                : nil

            DispatchQueue.main.async {
                self.applyStats(stats)
                self.applyIPs(ips)
                self.applyNetConf(netConf)
                if let s = shellSSID { self.cachedSSID = s }
                // WiFi details (CWWiFiClient) must run on main thread
                self.collectAndApplyWiFi()

                // Latency: first tick + every 5 ticks
                if currentTick == 1 || currentTick % 5 == 0 {
                    Task { await self.measureLatency() }
                }
            }
        }
    }

    // MARK: - Network Stats (getifaddrs)

    private struct RawStats {
        var ibytes: UInt64      = 0
        var obytes: UInt64      = 0
        var ipackets: UInt32    = 0
        var opackets: UInt32    = 0
        var errors: UInt32      = 0
        var bestInterface: String = "--"
        var bestPriority: Int   = 0
    }

    private func collectNetStats() -> RawStats {
        var result = RawStats()
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

            let prio = ifPriority(name)
            if prio > result.bestPriority {
                result.bestInterface = name
                result.bestPriority  = prio
            }
        }
        return result
    }

    private func applyStats(_ s: RawStats) {
        let now     = Date()
        let elapsed = now.timeIntervalSince(lastUpdateTime)

        if isFirstSample {
            isFirstSample  = false
            lastBytesIn    = s.ibytes
            lastBytesOut   = s.obytes
            lastUpdateTime = now
            if activeInterface == "--" { activeInterface = s.bestInterface }
            packetsIn     = s.ipackets
            packetsOut    = s.opackets
            networkErrors = s.errors
            return
        }

        guard elapsed > 0 else { return }

        // Guard against 32-bit counter wrap (skip that tick silently)
        if s.ibytes >= lastBytesIn && s.obytes >= lastBytesOut {
            let deltaIn  = s.ibytes  - lastBytesIn
            let deltaOut = s.obytes  - lastBytesOut

            let newDL = Double(deltaIn)  / elapsed
            let newUL = Double(deltaOut) / elapsed

            // Smooth the displayed values with a light EMA (α = 0.6)
            downloadSpeed = downloadSpeed * 0.4 + newDL * 0.6
            uploadSpeed   = uploadSpeed   * 0.4 + newUL * 0.6

            sessionDownloadAccum += Double(deltaIn)
            sessionUploadAccum   += Double(deltaOut)
        }
        // else: counter wrap detected — keep previous speeds, skip accumulation

        downloadSpeedString = formatSpeed(downloadSpeed)
        uploadSpeedString   = formatSpeed(uploadSpeed)
        sessionDownload     = UInt64(sessionDownloadAccum)
        sessionUpload       = UInt64(sessionUploadAccum)

        let sample = SpeedSample(timestamp: now,
                                 download: downloadSpeed,
                                 upload: uploadSpeed)
        speedHistory.append(sample)
        if speedHistory.count > 60 { speedHistory.removeFirst() }

        packetsIn     = s.ipackets
        packetsOut    = s.opackets
        networkErrors = s.errors

        if activeInterface == "--" { activeInterface = s.bestInterface }
        lastBytesIn    = s.ibytes
        lastBytesOut   = s.obytes
        lastUpdateTime = now

        saveTickCount += 1
        if saveTickCount >= 10 {
            saveTickCount = 0
            saveSession()
        }
    }

    // MARK: - Interface Priority

    private func ifPriority(_ name: String) -> Int {
        switch name {
        case "en0": return 3
        case "en1": return 2
        default:    return 1
        }
    }

    // MARK: - IP Addresses

    private struct IPInfo {
        var v4: String       = "--"
        var v6: String       = "--"
        var subnet: String   = "--"
        var bestIface: String = "--"
    }

    private func collectIPAddresses() -> IPInfo {
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

            let prio   = ifPriority(name)
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
                // Use the concrete struct size; sa_len can be zero on some macOS builds
                let addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(addr, addrLen, &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    // Strip scope ID (e.g. "fe80::abc%en0" → "fe80::abc") before prefix check
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

    private func applyIPs(_ info: IPInfo) {
        ipv4Address = info.v4
        ipv6Address = info.v6
        subnetMask  = info.subnet
        if info.bestIface != "--" { activeInterface = info.bestIface }
    }

    // MARK: - WiFi Info  (must run on main thread — CWWiFiClient requirement)

    private func collectAndApplyWiFi() {
        // Stage 1: SCDynamicStore AirPort key (no Location needed, fast)
        var ssidFromSC: String? = nil
        if let store = SCDynamicStoreCreate(nil, "SwiftMeter" as CFString, nil, nil) {
            let pattern = "State:/Network/Interface/.*/AirPort" as CFString
            if let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] {
                for key in keys {
                    if let dict = SCDynamicStoreCopyValue(store, key as CFString)
                                        as? [String: Any],
                       let ssid = dict["SSID_STR"] as? String, !ssid.isEmpty {
                        ssidFromSC = ssid
                        break
                    }
                }
            }
            if ssidFromSC == nil {
                for ifname in ["en0", "en1", "en2"] {
                    let key = "State:/Network/Interface/\(ifname)/AirPort" as CFString
                    if let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                       let ssid = dict["SSID_STR"] as? String, !ssid.isEmpty {
                        ssidFromSC = ssid
                        break
                    }
                }
            }
        }

        // Stage 2: CWWiFiClient for RSSI / channel / tx-rate (main-thread only)
        // interfaces()?.first replaces the deprecated interface() on macOS 14+
        if let iface = CWWiFiClient.shared().interfaces()?.first {
            let rssi = iface.rssiValue()
            wifiRSSI          = rssi
            wifiTxRate        = iface.transmitRate()
            wifiSignalPercent = rssiToPercent(rssi)

            if let ch = iface.wlanChannel() {
                wifiChannel = "\(ch.channelNumber)"
                switch ch.channelBand {
                case .band2GHz: wifiBand = "2.4 GHz"
                case .band5GHz: wifiBand = "5 GHz"
                case .band6GHz: wifiBand = "6 GHz"
                default:        wifiBand = "--"
                }
            }

            // SSID priority: SCDynamicStore → CWWiFiClient.ssid() → networksetup cache
            let cwSSID = iface.ssid()
            wifiSSID = ssidFromSC ?? cwSSID ?? cachedSSID ?? "--"
        } else {
            wifiSSID          = ssidFromSC ?? cachedSSID ?? "--"
            wifiRSSI          = 0
            wifiSignalPercent = 0
        }
    }

    // MARK: - WiFi SSID via networksetup (background-safe, no Location needed)

    /// Runs `/usr/sbin/networksetup -getairportnetwork <iface>` for each candidate
    /// interface and returns the first non-empty SSID found.  Must be called on
    /// a background thread (Process.run is blocking).
    private func fetchSSIDViaNetworkSetup() -> String? {
        let prefix = "Current Wi-Fi Network: "
        for iface in ["en0", "en1", "en2"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            task.arguments     = ["-getairportnetwork", iface]
            let out  = Pipe()
            let err  = Pipe()
            task.standardOutput = out
            task.standardError  = err
            guard (try? task.run()) != nil else { continue }
            task.waitUntilExit()
            let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            guard raw.hasPrefix(prefix) else { continue }
            let ssid = String(raw[raw.index(raw.startIndex, offsetBy: prefix.count)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !ssid.isEmpty { return ssid }
        }
        return nil
    }

    // MARK: - Network Config (DNS / Gateway)

    private struct NetConfig {
        var gateway: String   = "--"
        var dns: [String]     = []
    }

    private func collectNetworkConfig() -> NetConfig {
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

    private func applyNetConf(_ config: NetConfig) {
        gateway    = config.gateway
        dnsServers = config.dns
    }

    // MARK: - Public IP (ipinfo.io)

    @MainActor
    func fetchPublicIP() async {
        publicIP  = "Fetching..."
        ispName   = "--"
        ipCity    = "--"
        ipRegion  = "--"
        ipCountry = "--"
        do {
            let url     = URL(string: "https://ipinfo.io/json")!
            let request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 10)
            let (data, _) = try await URLSession.shared.data(for: request)
            if let info = try? JSONDecoder().decode(IPInfoResponse.self, from: data) {
                publicIP  = info.ip      ?? "--"
                ipCity    = info.city    ?? "--"
                ipRegion  = info.region  ?? "--"
                ipCountry = info.country ?? "--"
                // "AS7922 Comcast Cable" → strip leading ASN token
                if let org = info.org {
                    let parts = org.split(separator: " ", maxSplits: 1)
                    ispName = parts.count > 1 ? String(parts[1]) : org
                }
            } else {
                publicIP = "--"
            }
        } catch {
            publicIP = "--"
        }
    }

    // MARK: - Latency  (TCP connect to 1.1.1.1:443 ≈ 1 RTT)

    func measureLatency() async {
        // Only one measurement at a time
        let shouldMeasure = await MainActor.run { () -> Bool in
            guard !self.isLatencyMeasuring else { return false }
            self.isLatencyMeasuring = true
            return true
        }
        guard shouldMeasure else { return }

        let connection = NWConnection(
            host: NWEndpoint.Host("1.1.1.1"),
            port: NWEndpoint.Port(rawValue: 443)!,
            using: .tcp
        )
        let start = Date()

        // NSLock guards `done` — accessed from NWConnection callback queue AND
        // the 5-second timeout queue concurrently.
        let lock = NSLock()
        var done = false

        let ms: Int = await withCheckedContinuation { continuation in
            let finish: (Int) -> Void = { result in
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
                    connection.cancel()
                    finish(elapsed)
                case .failed, .cancelled:
                    finish(-1)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))

            // 5-second hard timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                connection.cancel()
                finish(-1)
            }
        }

        await MainActor.run {
            self.latencyMs      = ms
            self.latencyString  = ms >= 0 ? "\(ms) ms" : "--"
            self.isLatencyMeasuring = false
        }
    }

    // MARK: - Formatting Helpers

    /// Bytes/sec → human-readable with 1024 divisor (KBps / MBps / GBps)
    func formatSpeed(_ bytesPerSec: Double) -> String {
        switch bytesPerSec {
        case ..<1_024:
            return String(format: "%.0f B/s",   bytesPerSec)
        case ..<(1_024 * 1_024):
            return String(format: "%.1f KBps",  bytesPerSec / 1_024)
        case ..<(1_024 * 1_024 * 1_024):
            return String(format: "%.1f MBps",  bytesPerSec / (1_024 * 1_024))
        default:
            return String(format: "%.2f GBps",  bytesPerSec / (1_024 * 1_024 * 1_024))
        }
    }

    /// Bytes → human-readable storage size
    func formatBytes(_ bytes: UInt64) -> String {
        switch bytes {
        case ..<1_024:
            return "\(bytes) B"
        case ..<(1_024 * 1_024):
            return String(format: "%.1f KB", Double(bytes) / 1_024)
        case ..<(1_024 * 1_024 * 1_024):
            return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
        default:
            return String(format: "%.2f GB", Double(bytes) / (1_024 * 1_024 * 1_024))
        }
    }

    private func rssiToPercent(_ rssi: Int) -> Int {
        guard rssi != 0 else { return 0 }
        let clamped = max(-100, min(-50, rssi))
        return (clamped + 100) * 2
    }
}

// MARK: - CLLocationManagerDelegate

extension NetworkMonitor: CLLocationManagerDelegate {
    /// Called when the user responds to the location-access dialog (or if the
    /// status changes later).  After authorization the next CWWiFiClient call
    /// will return the real SSID without needing an app restart.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            self?.collectAndApplyWiFi()
        }
    }
}
