#!/bin/zsh
# BETA builds of Corres for Mac, for TestFlight. Same rules as
# Scripts/testflight.sh: Pro is included for testers (`-D CORRES_BETA`,
# and only when installed from TestFlight or Xcode), and a build made here
# must NEVER be submitted to App Review.
#
# The Mac app is the same App Store record as the iPhone app (macOS added
# as a platform, so one purchase covers both). Build numbers come from the
# one shared counter, so a number is never used twice across the two.
#
# Steps: bumps the build number, archives the CorresMac scheme in Release
# with the beta flag, checks the flag and the sandbox are really in,
# exports for App Store Connect and uploads.
# Usage:  Scripts/testflight-mac.sh
# Requires your Apple ID signed in to Xcode, or an App Store Connect API
# key (Docs/asc-api-key.md).
set -euo pipefail
cd "$(dirname "$0")/.."
# An App Store Connect API key, when one is set up (Docs/asc-api-key.md).
source Scripts/asc-auth.sh

PBX=Corres.xcodeproj/project.pbxproj
current=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBX" | grep -o '[0-9]*$')
next=$((current + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $next;/g" "$PBX"
version=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$PBX" | grep -o '[0-9.]*$')
echo "Building Corres for Mac $version ($next) BETA…"

ARCHIVE="build/CorresMac-$version-$next-beta.xcarchive"
rm -rf build/export-mac
xcodebuild -project Corres.xcodeproj -scheme CorresMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${ASC_AUTH[@]}" archive -quiet \
  OTHER_SWIFT_FLAGS='$(inherited) -D CORRES_BETA'

APP="$ARCHIVE/Products/Applications/Corres.app"
markers=$(strings "$APP/Contents/MacOS/Corres" | grep -o 'CORRES_[A-Z]*_BUILD' | sort -u | tr '\n' ' ')
if [[ "$markers" != *CORRES_BETA_BUILD* ]]; then
  echo "Stopped: the beta flag isn't in this build, so testers would be locked out of Pro. Nothing was uploaded."
  exit 1
fi
# The Mac App Store refuses an app that isn't sandboxed.
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; then
  echo "Stopped: the archived app isn't sandboxed. Nothing was uploaded."
  exit 1
fi

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/export-mac \
  -exportOptionsPlist Scripts/ExportOptions.plist -allowProvisioningUpdates "${ASC_AUTH[@]}"

git add "$PBX"
git commit -qm "TestFlight beta build for Mac $version ($next)" || true
echo "Uploaded Corres for Mac $version ($next) BETA (Pro included for testers). Do not submit build $next to the App Store."
