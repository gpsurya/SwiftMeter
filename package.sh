#!/bin/bash
# package.sh — builds SwiftMeter and creates a distributable DMG
# Usage: bash package.sh

set -e

APP_NAME="SwiftMeter"
VERSION="1.2.0"
BUILD_DIR="$(pwd)/build"
APP="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_OUT="$(pwd)/$DMG_NAME"
STAGING="/tmp/${APP_NAME}_dmg_staging"
TMP_DMG="/tmp/${APP_NAME}_rw.dmg"

# ── Step 1: Build ──────────────────────────────────────────────────────────
bash build.sh

# ── Step 2: Staging folder ─────────────────────────────────────────────────
echo "→ Staging DMG content..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -r "$APP" "$STAGING/"
# Symlink to /Applications for drag-to-install
ln -s /Applications "$STAGING/Applications"

# ── Step 3: Create a writable DMG ─────────────────────────────────────────
echo "→ Creating DMG..."
rm -f "$TMP_DMG" "$DMG_OUT"

hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING" \
  -ov -format UDRW \
  -size 30m \
  "$TMP_DMG" > /dev/null

# ── Step 4: Mount + set window appearance via AppleScript ──────────────────
MOUNT_POINT=$(hdiutil attach "$TMP_DMG" -readwrite -nobrowse -noverify \
  | grep "/Volumes" | tail -1 | awk '{print substr($0, index($0,$3))}' | sed 's/[[:space:]]*$//')

echo "  Mounted at: $MOUNT_POINT"
sleep 2

# Set DMG window layout: app icon left, Applications alias right
osascript << APPLESCRIPT
tell application "Finder"
  tell disk "$APP_NAME $VERSION"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 460}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 110
    set text size of theViewOptions to 12
    delay 1
    set position of item "$APP_NAME.app" of container window to {150, 180}
    set position of item "Applications"  of container window to {410, 180}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# ── Step 5: Unmount + convert to compressed read-only DMG ──────────────────
hdiutil detach "$MOUNT_POINT" -quiet
sleep 1

echo "→ Compressing DMG..."
hdiutil convert "$TMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_OUT" > /dev/null

# ── Cleanup ────────────────────────────────────────────────────────────────
rm -f "$TMP_DMG"
rm -rf "$STAGING"

SIZE=$(du -sh "$DMG_OUT" | cut -f1)

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✓  $DMG_NAME  ($SIZE)  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Share this file with your friends."
echo "  They double-click it, drag SwiftMeter → Applications, done."
echo ""
echo "  Path: $DMG_OUT"
echo ""
