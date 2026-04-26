import Foundation
import CoreWLAN
import SystemConfiguration

// Wi-Fi metadata: SSID, RSSI, channel, band, TX rate. Split into a
// background-safe helper (`ssidViaNetworkSetup`) and a main-thread-only
// snapshot reader (`collectMain`) because CWWiFiClient's interface APIs
// must be called on the main thread.

enum WiFi {

    struct Snapshot {
        var ssid: String       = "--"
        var rssi: Int          = 0
        var signalPercent: Int = 0
        var txRate: Double     = 0
        var channel: String    = "--"
        var band: String       = "--"
    }

    /// Main-thread snapshot of Wi-Fi state. SSID is resolved through
    /// SCDynamicStore (fast, no Location prompt) → CWWiFiClient.ssid()
    /// (needs Location) → caller-supplied `cachedSSID` fallback.
    @MainActor
    static func collectMain(cachedSSID: String?) -> Snapshot {
        var snap = Snapshot()

        // Stage 1: SCDynamicStore AirPort key — works without Location.
        var ssidFromSC: String? = nil
        if let store = SCDynamicStoreCreate(nil, "SwiftMeter" as CFString, nil, nil) {
            let pattern = "State:/Network/Interface/.*/AirPort" as CFString
            if let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] {
                for key in keys {
                    if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
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

        // Stage 2: CWWiFiClient for RSSI / channel / TX rate.
        // interfaces()?.first replaces the deprecated interface() on macOS 14+.
        if let iface = CWWiFiClient.shared().interfaces()?.first {
            let rssi = iface.rssiValue()
            snap.rssi          = rssi
            snap.txRate        = iface.transmitRate()
            snap.signalPercent = rssiToPercent(rssi)

            if let ch = iface.wlanChannel() {
                snap.channel = "\(ch.channelNumber)"
                switch ch.channelBand {
                case .band2GHz: snap.band = "2.4 GHz"
                case .band5GHz: snap.band = "5 GHz"
                case .band6GHz: snap.band = "6 GHz"
                default:        snap.band = "--"
                }
            }

            let cwSSID = iface.ssid()
            snap.ssid = ssidFromSC ?? cwSSID ?? cachedSSID ?? "--"
        } else {
            snap.ssid = ssidFromSC ?? cachedSSID ?? "--"
        }
        return snap
    }

    /// `/usr/sbin/networksetup -getairportnetwork <iface>` — last-ditch
    /// SSID source. Background-safe (Process.run is blocking) and used
    /// only when the in-process APIs come back empty.
    static func ssidViaNetworkSetup() -> String? {
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

    // RSSI values are dBm. Anything weaker than -100 is unusable; -50 and
    // above is "full bars". Linear-map that range to 0–100 %.
    private static func rssiToPercent(_ rssi: Int) -> Int {
        guard rssi != 0 else { return 0 }
        let clamped = max(-100, min(-50, rssi))
        return (clamped + 100) * 2
    }
}
