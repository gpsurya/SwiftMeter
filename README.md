<p align="center">
  <img src="NetPulse/AppIcon.icns" width="128" alt="SwiftMeter Icon"/>
</p>

<h1 align="center">SwiftMeter</h1>

<p align="center">
  A lightweight macOS menu bar app that shows live network upload &amp; download speeds — and a rich popover with Wi-Fi details, IP addresses, latency, ISP info, and session statistics.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square"/>
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square"/>
  <img src="https://img.shields.io/badge/version-1.0.0-green?style=flat-square"/>
  <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square"/>
</p>

---

## Features

| Category | Details |
|---|---|
| **Menu Bar** | Live ↑ upload / ↓ download speeds — two-line stacked display with blue/green arrows |
| **Speed Units** | Auto-scaling: B/s → KBps → MBps → GBps (1024-base) |
| **Speed Graph** | 60-second DL/UL sparkline with separate channels |
| **Connection** | Interface name, type (Wi-Fi / Ethernet / VPN / Cellular), latency (TCP RTT) |
| **IP Addresses** | IPv4, IPv6 (local), Public WAN IP with manual refresh button |
| **ISP & Location** | ISP name + city/region/country via ipinfo.io |
| **Wi-Fi Details** | SSID, signal strength (% + dBm + bars), channel, band (2.4/5/6 GHz), TX rate |
| **Network Config** | Gateway, subnet mask, DNS servers |
| **Session Stats** | Downloaded / Uploaded totals, packets in/out, error count, session age |
| **Persistence** | Session data survives restarts (UserDefaults) |
| **Auto-start** | Installs a LaunchAgent so SwiftMeter starts at every login |
| **Dark/Light Mode** | Full adaptive UI — glass cards, dynamic colors |

---

## Screenshot

> Click the status bar item to open the popover.

```
Status bar:   ↑ 12.4 MBps
              ↓ 48.7 MBps
```

---

## Requirements

- macOS 14 Sonoma or later
- Xcode Command Line Tools (for `swiftc`)

```bash
xcode-select --install
```

---

## Build & Install

```bash
# 1. Clone the repo
git clone https://github.com/YOUR_USERNAME/SwiftMeter.git
cd SwiftMeter

# 2. Build, sign (ad-hoc), and install the LaunchAgent
bash build.sh

# 3. Launch
open build/SwiftMeter.app
```

The build script:
- Compiles all Swift sources with `-O` optimisation
- Creates a proper `.app` bundle with `Info.plist` and `AppIcon.icns`
- Ad-hoc code-signs the bundle (`codesign --sign -`)
- Installs `~/Library/LaunchAgents/com.swiftmeter.app.plist` so the app starts automatically at login

---

## Wi-Fi SSID

macOS 14+ hides the Wi-Fi network name (SSID) from all APIs unless **Location Services** permission is granted.

On first launch SwiftMeter will ask:
> *"SwiftMeter wants to use your location to display your Wi-Fi network name"*

Click **Allow** — the SSID appears instantly. No GPS data is ever collected or sent anywhere; Location is only used to unlock the CoreWLAN SSID API.

---

## Stop / Uninstall

```bash
# Stop the running app
killall SwiftMeter

# Remove the login item
launchctl unload ~/Library/LaunchAgents/com.swiftmeter.app.plist
rm ~/Library/LaunchAgents/com.swiftmeter.app.plist

# Delete the build
rm -rf build/
```

---

## Project Structure

```
SwiftMeter/
├── build.sh                  # One-command build & install script
├── NetPulse/
│   ├── NetPulseApp.swift     # @main app + MenuBarExtra + StatusBarIcon
│   ├── NetworkMonitor.swift  # All network data collection & publishing
│   ├── PopoverView.swift     # Full popover UI (glass cards, sections)
│   ├── SpeedGraphView.swift  # Sparkline chart + signal bars
│   ├── AppIcon.icns          # App icon (all macOS sizes)
│   └── Info.plist            # Bundle metadata & permissions
└── NetPulse.xcodeproj        # Xcode project (optional — build.sh works standalone)
```

---

## How It Works

- **Speed measurement** — `getifaddrs()` reads `if_data` byte counters every second per interface. Delta / elapsed-time gives bytes/sec. 32-bit counter wraps are silently skipped (no corruption).
- **Wi-Fi** — `CoreWLAN (CWWiFiClient)` for RSSI / channel / TX rate; `SCDynamicStore` + `networksetup` subprocess as SSID fallbacks; Location permission as the definitive source.
- **Latency** — TCP connect to `1.1.1.1:443` timed to `.ready` state ≈ 1 RTT.
- **Public IP / ISP / Location** — single `ipinfo.io/json` call; refreshed automatically on network reconnect.
- **Session persistence** — `UserDefaults` stores accumulated bytes and session start timestamp (as `Double` to handle >4 GB totals). Saved every 10 ticks and on app quit.
- **Auto-start** — `~/Library/LaunchAgents/com.swiftmeter.app.plist` with `RunAtLoad=true`.

---

## License

```
MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
