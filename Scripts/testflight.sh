#!/bin/zsh
# BETA builds for TestFlight testers. Pro is included for testers
# (`-D CORRES_BETA`, see EntitlementStore "Beta access").
#
#   NEVER submit a build made by this script to App Review / the App Store.
#   For the App Store, use Scripts/appstore.sh and pick ITS build number in
#   App Store Connect. (Even if one slipped through, App Store customers
#   still can't get Pro free: the unlock also requires a TestFlight/Xcode
#   install. But the reviewer would, and the review would be rejected.)
#
# Steps: bumps the build number (app and widget stay in step), archives a
# Release build with the beta flag, checks the flag is really in, uploads.
# Usage:  Scripts/testflight.sh
# Requires your Apple ID signed in to Xcode (Xcode > Settings > Accounts).
set -euo pipefail
cd "$(dirname "$0")/.."

PBX=Corres.xcodeproj/project.pbxproj
current=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBX" | grep -o '[0-9]*$')
next=$((current + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $next;/g" "$PBX"
version=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$PBX" | grep -o '[0-9.]*$')
echo "Building Corres $version ($next) BETA…"

ARCHIVE="build/Corres-$version-$next-beta.xcarchive"
rm -rf build/export
xcodebuild -project Corres.xcodeproj -scheme Corres -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive -quiet \
  OTHER_SWIFT_FLAGS='$(inherited) -D CORRES_BETA'

BIN="$ARCHIVE/Products/Applications/Corres.app/Corres"
# Read in full, not `grep -q`: with pipefail, -q stopping early made the
# pipeline report failure even when the marker was there.
markers=$(strings "$BIN" | grep -o 'CORRES_[A-Z]*_BUILD' | sort -u | tr '\n' ' ')
if [[ "$markers" != *CORRES_BETA_BUILD* ]]; then
  echo "Stopped: the beta flag isn't in this build, so testers would be locked out of Pro. Nothing was uploaded."
  exit 1
fi

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/export \
  -exportOptionsPlist Scripts/ExportOptions.plist -allowProvisioningUpdates

git add "$PBX"
git commit -qm "TestFlight beta build $version ($next)" || true
echo "Uploaded Corres $version ($next) BETA (Pro included for testers). Do not submit build $next to the App Store."
