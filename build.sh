#!/bin/bash
set -e

APP_NAME="SwiftMeter"
BUNDLE_ID="com.swiftmeter.app"
VERSION="1.1.0"
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
  SwiftMeter/NetPulseApp.swift      \
  SwiftMeter/NetworkMonitor.swift   \
  SwiftMeter/PopoverView.swift      \
  SwiftMeter/SpeedGraphView.swift   \
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

# ── Launch Agent (auto-start at login) ────────────────────────────────────
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_AGENTS/${BUNDLE_ID}.plist"
EXEC_PATH="$APP/Contents/MacOS/$APP_NAME"

mkdir -p "$LAUNCH_AGENTS"

cat > "$LAUNCH_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${EXEC_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

# Unload any previous version, then load the new one
launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
launchctl load -w "$LAUNCH_PLIST"

echo ""
echo "✓ Built:         $APP"
echo "✓ Version:       $VERSION"
echo "✓ Launch agent:  $LAUNCH_PLIST"
echo "  (SwiftMeter will auto-start at next login)"
echo ""
echo "  Launch :  open \"$APP\""
echo "  Stop   :  killall $APP_NAME"
echo ""
