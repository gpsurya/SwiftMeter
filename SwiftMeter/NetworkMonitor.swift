import Foundation
import AppKit
import CoreLocation
import Network

// MARK: - Data Models

struct SpeedSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let download: Double  // bytes/sec
    let upload: Double    // bytes/sec
}

// MARK: - Network Monitor (coordinator)
//
// Owns all `@Published` UI state and the master DispatchSourceTimer. Heavy
// data collection lives in the `Monitor/*.swift` modules:
//   • Stats     — getifaddrs byte counters
//   • Identity  — IPv4/IPv6/public IP/ISP/geo, gateway, DNS
//   • WiFi      — SSID, RSSI, channel, band, TX rate
//   • Latency   — single-host TCP RTT probe
//
// Each tick: collect on a background queue, apply on main.

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

    private var timer: DispatchSourceTimer?
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

    // Popover visibility — drives throttling. When hidden we only sample
    // bytes (needed for the menu-bar icon) and skip WiFi/IP/DNS/latency
    // / graph work.
    private var isPopoverVisible: Bool       = false
    private var ssidNeedsRefresh: Bool       = true

    // WiFi SSID cached from shell (background-safe fallback used by WiFi.collectMain)
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

    // MARK: - Init

    override init() {
        super.init()
        loadSession()
        setupPathMonitor()
        setupLocationManager()
        startTimer()
        Task { await refreshPublicIP() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.saveSession() }
    }

    deinit {
        timer?.cancel()
        nwPathMonitor.cancel()
        saveSession()
    }

    // MARK: - Popover visibility

    func setPopoverVisible(_ visible: Bool) {
        let wasVisible = isPopoverVisible
        isPopoverVisible = visible
        // When the popover opens, refresh slow-moving info immediately so
        // users don't see stale values from while it was hidden.
        if visible && !wasVisible {
            bgQueue.async { [weak self] in
                guard let self else { return }
                let ips     = Identity.collectIPs()
                let netConf = Identity.collectNetworkConfig()
                DispatchQueue.main.async {
                    self.applyIPs(ips)
                    self.applyNetConf(netConf)
                    if self.connectionType == .wifi { self.applyWiFiSnapshot() }
                    Task { await self.runLatencyProbe() }
                }
            }
        }
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

                // Network went DOWN: erase public WAN / ISP info
                if wasConn && !nowConnected {
                    self.publicIP  = "--"
                    self.ispName   = "--"
                    self.ipCity    = "--"
                    self.ipRegion  = "--"
                    self.ipCountry = "--"
                    self.cachedSSID = nil
                    self.wifiSSID   = "--"
                    self.ssidNeedsRefresh = true
                }

                // Network came UP: refresh public WAN / ISP info
                if !wasConn && nowConnected {
                    self.ssidNeedsRefresh = true
                    Task { await self.refreshPublicIP() }
                }
            }
        }
        nwPathMonitor.start(queue: bgQueue)
    }

    // MARK: - Timer
    //
    // One DispatchSourceTimer on a utility queue (instead of a 1 s NSTimer
    // on the main run loop) — avoids waking the main thread every second.
    //
    // Per-tick work is split by cost:
    //   • Every tick (1 s):  byte counters → drives status-bar icon. Cheap.
    //   • Slow tier:         WiFi details, IP addresses, DNS/gateway, graph
    //                        history, latency. Runs every 5 s when popover
    //                        open, every 30 s when hidden.
    //   • SSID shell call:   only when needed (network just came up, or SSID
    //                        unknown). Was firing every 5 s = 12 Process
    //                        spawns/min — biggest battery win.

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: bgQueue)
        t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        tickCount += 1
        let currentTick = tickCount

        // Always: cheap byte-counter sample. Drives the menu-bar icon.
        let stats = Stats.collect()

        // Slow tier cadence: 5 s open, 30 s hidden.
        let slowInterval = isPopoverVisible ? 5 : 30
        let runSlow = (currentTick == 1) || (currentTick % slowInterval == 0)

        // Latency cadence: 10 s when open, 60 s when hidden.
        let latencyInterval = isPopoverVisible ? 10 : 60
        let runLatency = (currentTick == 1) || (currentTick % latencyInterval == 0)

        let ips     = runSlow ? Identity.collectIPs()           : nil
        let netConf = runSlow ? Identity.collectNetworkConfig() : nil

        // SSID shell call: only when we don't have one yet (or network just
        // changed). SSID rarely changes mid-session; periodic polling wastes
        // power spawning Process subtasks.
        let shellSSID: String? = (ssidNeedsRefresh && connectionType == .wifi)
            ? WiFi.ssidViaNetworkSetup()
            : nil
        if shellSSID != nil { ssidNeedsRefresh = false }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyStats(stats, recordHistory: self.isPopoverVisible || runSlow)

            if let ips     { self.applyIPs(ips) }
            if let netConf { self.applyNetConf(netConf) }
            if let s = shellSSID { self.cachedSSID = s }

            // CWWiFiClient is main-thread-only and only meaningful on Wi-Fi.
            if runSlow && self.connectionType == .wifi {
                self.applyWiFiSnapshot()
            }

            if runLatency {
                Task { await self.runLatencyProbe() }
            }
        }
    }

    // MARK: - Apply: Stats

    private func applyStats(_ s: Stats.Raw, recordHistory: Bool) {
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

        let newDLString = formatSpeed(downloadSpeed)
        let newULString = formatSpeed(uploadSpeed)
        // Only assign when changed — avoids needless menu-bar icon redraws
        if newDLString != downloadSpeedString { downloadSpeedString = newDLString }
        if newULString != uploadSpeedString   { uploadSpeedString   = newULString }
        sessionDownload = UInt64(sessionDownloadAccum)
        sessionUpload   = UInt64(sessionUploadAccum)

        // Skip history churn when popover hidden — speedHistory drives the
        // graph (only visible in the popover) and republishing it triggers
        // SwiftUI invalidations even when nothing is on-screen.
        if recordHistory {
            let sample = SpeedSample(timestamp: now,
                                     download: downloadSpeed,
                                     upload: uploadSpeed)
            speedHistory.append(sample)
            if speedHistory.count > 60 { speedHistory.removeFirst() }
        }

        packetsIn     = s.ipackets
        packetsOut    = s.opackets
        networkErrors = s.errors

        if activeInterface == "--" { activeInterface = s.bestInterface }
        lastBytesIn    = s.ibytes
        lastBytesOut   = s.obytes
        lastUpdateTime = now

        saveTickCount += 1
        if saveTickCount >= 30 {
            saveTickCount = 0
            saveSession()
        }
    }

    // MARK: - Apply: IPs

    private func applyIPs(_ info: Identity.IPInfo) {
        ipv4Address = info.v4
        ipv6Address = info.v6
        subnetMask  = info.subnet
        if info.bestIface != "--" { activeInterface = info.bestIface }
    }

    // MARK: - Apply: Net config (gateway / DNS)

    private func applyNetConf(_ config: Identity.NetConfig) {
        gateway    = config.gateway
        dnsServers = config.dns
    }

    // MARK: - Apply: Wi-Fi snapshot (main-thread)

    @MainActor
    private func applyWiFiSnapshot() {
        let snap = WiFi.collectMain(cachedSSID: cachedSSID)
        wifiSSID          = snap.ssid
        wifiRSSI          = snap.rssi
        wifiSignalPercent = snap.signalPercent
        wifiTxRate        = snap.txRate
        wifiChannel       = snap.channel
        wifiBand          = snap.band
    }

    // MARK: - Public IP

    @MainActor
    func refreshPublicIP() async {
        publicIP  = "Fetching..."
        ispName   = "--"
        ipCity    = "--"
        ipRegion  = "--"
        ipCountry = "--"
        if let info = await Identity.fetchPublic() {
            publicIP  = info.ip
            ispName   = info.isp
            ipCity    = info.city
            ipRegion  = info.region
            ipCountry = info.country
        } else {
            publicIP = "--"
        }
    }

    // Old name kept as a thin alias because PopoverView buttons may bind to it.
    @MainActor
    func fetchPublicIP() async { await refreshPublicIP() }

    // MARK: - Latency

    func runLatencyProbe() async {
        let shouldMeasure = await MainActor.run { () -> Bool in
            guard !self.isLatencyMeasuring else { return false }
            self.isLatencyMeasuring = true
            return true
        }
        guard shouldMeasure else { return }

        let ms = await Latency.measure()

        await MainActor.run {
            self.latencyMs          = ms
            self.latencyString      = ms >= 0 ? "\(ms) ms" : "--"
            self.isLatencyMeasuring = false
        }
    }

    // Backwards-compat alias for anything still referencing measureLatency().
    func measureLatency() async { await runLatencyProbe() }

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
}

// MARK: - CLLocationManagerDelegate

extension NetworkMonitor: CLLocationManagerDelegate {
    /// Called when the user responds to the location-access dialog (or if
    /// the status changes later). After authorisation the next CWWiFiClient
    /// call returns the real SSID without needing an app restart.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.connectionType == .wifi { self.applyWiFiSnapshot() }
        }
    }
}
