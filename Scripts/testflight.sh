#!/bin/zsh
# Ships the current code to TestFlight in one step:
#   1. bumps the build number (app and widget stay in step),
#   2. archives a Release build,
#   3. uploads it to App Store Connect.
# Usage:  Scripts/testflight.sh
# Requires your Apple ID signed in to Xcode (Xcode > Settings > Accounts).
set -euo pipefail
cd "$(dirname "$0")/.."

PBX=Corres.xcodeproj/project.pbxproj
current=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBX" | grep -o '[0-9]*$')
next=$((current + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $next;/g" "$PBX"
version=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$PBX" | grep -o '[0-9.]*$')
echo "Building Corres $version ($next)…"

ARCHIVE="build/Corres-$version-$next.xcarchive"
rm -rf build/export
xcodebuild -project Corres.xcodeproj -scheme Corres -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive -quiet
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/export \
  -exportOptionsPlist Scripts/ExportOptions.plist -allowProvisioningUpdates

git add "$PBX"
git commit -qm "TestFlight build $version ($next)" || true
echo "Uploaded Corres $version ($next). It appears in TestFlight after Apple finishes processing (about 10–30 minutes)."
