#!/bin/bash
# Builds LimitBar.app, LimitBar.zip and LimitBar.dmg into ./build.
#   --install     also copy the app to ~/Applications and launch it
#   --send        also send the zip to your Telegram "Saved Messages"
#   --send-only   send the zip of the last build without building again
# Sending is never automatic, so only builds worth keeping reach the chat. BUILD_NOTE="…"
# adds a line to the caption. Telegram is set up once with scripts/telegram_setup.sh.
# Every build gets the next build number, kept in ./build-number: "1.0 (12)".
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0 SEND=0 SEND_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --send) SEND=1 ;;
        --send-only) SEND_ONLY=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

APP="build/LimitBar.app"
ZIP="build/LimitBar.zip"
DMG="build/LimitBar.dmg"
VERSION="1.0"

send_to_telegram() {
    local telegram="$HOME/.config/tvremote-telegram"
    if [[ ! -f "$telegram/session.session" ]]; then
        echo "Telegram isn't set up: run scripts/telegram_setup.sh to get builds in Saved Messages."
        return
    fi
    local plist="$APP/Contents/Info.plist" version build
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
    build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
    local caption="📊 LimitBar $version ($build) — build of $(date -r "$ZIP" '+%d/%m/%Y %H:%M')"
    [[ -n "${BUILD_NOTE:-}" ]] && caption="$caption"$'\n'"$BUILD_NOTE"
    "$telegram/venv/bin/python" -I scripts/telegram_send.py send "$ZIP" "$caption" \
        || echo "Sending to Telegram failed: the build is ready in $ZIP anyway."
}

if (( SEND_ONLY )); then
    [[ -f "$ZIP" ]] || { echo "No build to send: run ./build.sh first" >&2; exit 1; }
    send_to_telegram
    exit 0
fi

swift build -c release
BUILD=$(( $(cat build-number 2>/dev/null || echo 0) + 1 ))
echo "$BUILD" > build-number
BIN="$(swift build -c release --show-bin-path)/LimitBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LimitBar"
# SwiftPM records the deployment target (14.0) as the SDK version, and AppKit then draws the
# pre-macOS 26 controls (old switches and buttons). Stamp the SDK actually used instead.
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$APP/Contents/MacOS/LimitBar.stamped" "$APP/Contents/MacOS/LimitBar"
mv -f "$APP/Contents/MacOS/LimitBar.stamped" "$APP/Contents/MacOS/LimitBar"
# Regenerate with scripts/make_icon.swift (see its header) after changing the drawing.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The translations: English is the base (the keys), Italian in it.lproj.
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# The iPhone widget; ICloudExport installs it in Scriptable's iCloud folder.
cp scripts/LimitBar.js "$APP/Contents/Resources/LimitBar.js"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LimitBar</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
    <key>CFBundleDisplayName</key><string>LimitBar</string>
    <key>CFBundleIdentifier</key><string>com.francescocinotti.limitbar</string>
    <key>CFBundleExecutable</key><string>LimitBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP $VERSION ($BUILD)"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# The disk image to install from: LimitBar, an arrow and Applications to drag it onto. The window
# is laid out by the Finder (macOS asks once to let this script control it); if the Finder doesn't
# answer, the image still works, with the icons where the Finder puts them.
# Regenerate the background with scripts/make_dmg_background.swift (see its header).
make_dmg() {
    local stage="build/dmg" rw="build/LimitBar-rw.dmg" volume="LimitBar"
    rm -rf "$stage" "$rw" "$DMG"
    mkdir -p "$stage/.background"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    cp Resources/dmg-background.tiff "$stage/.background/background.tiff"
    # A volume left mounted from an earlier build would take the name.
    [[ -d "/Volumes/$volume" ]] && hdiutil detach "/Volumes/$volume" -quiet -force
    hdiutil create -quiet -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$rw"
    local device
    device=$(hdiutil attach -readwrite -noverify -noautoopen "$rw" 2>/dev/null | awk '/\/Volumes\// {print $1; exit}')
    osascript 2>/dev/null <<APPLESCRIPT || echo "The Finder didn't lay out the disk image window: it opens with its default layout."
with timeout of 120 seconds
    tell application "Finder"
        tell disk "$volume"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {200, 120, 740, 500}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item "LimitBar.app" of container window to {140, 175}
            set position of item "Applications" of container window to {400, 175}
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end timeout
APPLESCRIPT
    sync
    hdiutil detach "$device" -quiet || hdiutil detach "$device" -quiet -force
    hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$DMG"
    rm -rf "$stage" "$rw"
    echo "Built $DMG"
}
make_dmg

(( SEND )) && send_to_telegram

if (( INSTALL )); then
    pkill -x LimitBar 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/LimitBar.app"
    cp -R "$APP" "$HOME/Applications/"
    # Claude Code's status line (~/.claude/settings.json) runs this copy.
    SUPPORT="$HOME/Library/Application Support/LimitBar"
    mkdir -p "$SUPPORT"
    cp scripts/claude-statusline.sh "$SUPPORT/"
    # Claude Code hooks (~/.claude/settings.json) run this to report when Claude is working.
    cp scripts/claude-activity.sh "$SUPPORT/"
    open "$HOME/Applications/LimitBar.app"
    echo "Installed to ~/Applications/LimitBar.app"
fi
