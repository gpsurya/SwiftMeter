#!/bin/bash
set -e

APP_NAME="SwiftMeter"
BUNDLE_ID="com.swiftmeter.app"
VERSION="1.2.0"
BUILD_DIR="$(pwd)/build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK=$(xcrun --show-sdk-path --sdk macosx)
ARCH=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel
TARGET="${ARCH}-apple-macos14.0"

echo "→ Building $APP_NAME $VERSION ($ARCH)..."

# Clean + scaffold
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# ── Compile ────────────────────────────────────────────────────────────────
swiftc -O \
  -target "$TARGET" \
  -sdk    "$SDK"    \
  -framework SwiftUI              \
  -framework AppKit               \
  -framework CoreWLAN             \
  -framework CoreLocation         \
  -framework SystemConfiguration  \
  -framework Network              \
  -framework Charts               \
  -framework ServiceManagement    \
  -lsqlite3                       \
  SwiftMeter/NetPulseApp.swift      \
  SwiftMeter/NetworkMonitor.swift   \
  SwiftMeter/PopoverView.swift      \
  SwiftMeter/SpeedGraphView.swift   \
  SwiftMeter/Settings.swift         \
  SwiftMeter/SettingsView.swift     \
  SwiftMeter/History.swift          \
  SwiftMeter/HistoryView.swift      \
  SwiftMeter/Monitor/Stats.swift    \
  SwiftMeter/Monitor/Identity.swift \
  SwiftMeter/Monitor/WiFi.swift     \
  SwiftMeter/Monitor/Latency.swift  \
  -o "$APP/Contents/MacOS/$APP_NAME"

# ── App Icon ──────────────────────────────────────────────────────────────
[ -f "SwiftMeter/AppIcon.icns" ] && cp "SwiftMeter/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# ── Info.plist ─────────────────────────────────────────────────────────────
cp SwiftMeter/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME"                    "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID"                   "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME"                          "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL"                        "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION"             "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION"                        "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0"                     "$APP/Contents/Info.plist"

# ── Ad-hoc sign ───────────────────────────────────────────────────────────
codesign --sign - --force --deep "$APP"

# ── Done ───────────────────────────────────────────────────────────────────
# Auto-launch is now managed in-app by SMAppService. The user enables it
# in Settings; macOS handles login-item registration. No LaunchAgent
# plist install here. (Any leftover plist from older versions is removed
# on first launch by AppSettings.migrateLegacyLaunchAgentIfNeeded().)

echo ""
echo "✓ Built:         $APP"
echo "✓ Version:       $VERSION"
echo ""
echo "  Launch     :  open \"$APP\""
echo "  Stop       :  killall $APP_NAME"
echo "  Auto-launch:  SwiftMeter ▸ Settings ▸ General"
echo ""
