#!/bin/sh
# Bump CURRENT_PROJECT_VERSION after every Release build so the next
# archive gets a fresh build number. Build settings are resolved before
# this phase runs, so the bump applies to the NEXT build, not this one.
if [ "$CONFIGURATION" = "Release" ]; then
  cd "$PROJECT_DIR"
  xcrun agvtool next-version -all >/dev/null
fi

