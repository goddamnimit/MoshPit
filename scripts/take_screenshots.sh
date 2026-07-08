#!/bin/bash
# App Store screenshot automation for MoshPit.
#
# Boots an iPhone 15 Pro Max simulator (6.7-inch class, 1290x2796 — the size
# App Store Connect requires), builds a Debug build (the -testpattern/-coach/
# -drawer/-trace hooks are #if DEBUG and do not exist in Release), drives the
# app into each state via launch arguments, and captures PNGs with
# `xcrun simctl io ... screenshot`.
#
# Output: docs/screenshots/appstore/*.png
#
# Usage: scripts/take_screenshots.sh
set -euo pipefail

DEVICE_NAME="iPhone 15 Pro Max"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro-Max"
BUNDLE_ID="com.nimit.datamosh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/screenshots/appstore"
DERIVED="$REPO_ROOT/build/screenshots-deriveddata"

mkdir -p "$OUT_DIR"

# --- Simulator: find or create, then boot -----------------------------------
UDID=$(xcrun simctl list devices available | grep "$DEVICE_NAME (" \
       | head -1 | grep -oE '[0-9A-F-]{36}' || true)
if [ -z "$UDID" ]; then
  echo "Creating $DEVICE_NAME simulator (latest runtime)..."
  UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE")
fi
echo "Using simulator $DEVICE_NAME ($UDID)"

if ! xcrun simctl list devices | grep "$UDID" | grep -q Booted; then
  xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b   # wait until fully booted

# Clean status bar for every shot (app hides it, but be deterministic anyway).
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 || true

# --- Build & install ---------------------------------------------------------
echo "Building MoshPit (Debug, simulator)..."
xcodebuild -project "$REPO_ROOT/MoshPit.xcodeproj" -scheme MoshPit \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  build | tail -2

APP="$DERIVED/Build/Products/Debug-iphonesimulator/MoshPit.app"
xcrun simctl install "$UDID" "$APP"

# --- Capture -----------------------------------------------------------------
# snap <output-name> <settle-seconds> <launch-args...>
snap() {
  local name=$1 settle=$2; shift 2
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@" >/dev/null
  sleep "$settle"
  xcrun simctl io "$UDID" screenshot "$OUT_DIR/$name.png"
  echo "  captured $name.png"
}

# The simulator has no camera; -testpattern provides animated synthetic
# sources (slot A pattern + inverted slot B), so the mosh runs on every shot.
echo "Capturing screenshots..."
snap 01_main_canvas_moshing 6 -testpattern
snap 02_modes_drawer        5 -testpattern -drawer left
snap 03_parameters_drawer   5 -testpattern -drawer right
snap 04_trace_point_cloud   7 -testpattern -trace point
snap 05_tutorial_coach      5 -testpattern -coach 2
snap 06_mixer_luma_wipe     6 -testpattern -wipe 0.45

xcrun simctl status_bar "$UDID" clear || true

# --- Verify sizes ------------------------------------------------------------
echo
echo "Results in $OUT_DIR (App Store 6.7\" requires 1290x2796):"
for f in "$OUT_DIR"/*.png; do
  sips -g pixelWidth -g pixelHeight "$f" \
    | awk -v f="$(basename "$f")" 'BEGIN{ORS=""} /pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print f": "w"x"h"\n"}'
done
