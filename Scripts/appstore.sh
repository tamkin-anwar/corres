#!/bin/zsh
# The App Store build: a normal paywall, no beta Pro. This is the ONLY
# kind of build to submit to App Review. In App Store Connect, add the
# build number this script prints to the version you're submitting.
#
# Refuses to upload if the beta flag got into the build in any way (a
# project setting, an environment variable), so App Store customers can
# never get Pro free.
# Usage:  Scripts/appstore.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PBX=Corres.xcodeproj/project.pbxproj
if grep -q CORRES_BETA "$PBX"; then
  echo "Stopped: CORRES_BETA is in the project's build settings. Remove it; only Scripts/testflight.sh may pass it."
  exit 1
fi
unset OTHER_SWIFT_FLAGS 2>/dev/null || true

current=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBX" | grep -o '[0-9]*$')
next=$((current + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $next;/g" "$PBX"
version=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$PBX" | grep -o '[0-9.]*$')
echo "Building Corres $version ($next) for the App Store…"

ARCHIVE="build/Corres-$version-$next-appstore.xcarchive"
rm -rf build/export
xcodebuild -project Corres.xcodeproj -scheme Corres -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive -quiet

BIN="$ARCHIVE/Products/Applications/Corres.app/Corres"
# Read in full, not `grep -q`: with pipefail, -q stopping early reads as
# "not found", which here would have let a beta build through.
markers=$(strings "$BIN" | grep -o 'CORRES_[A-Z]*_BUILD' | sort -u | tr '\n' ' ')
if [[ "$markers" == *CORRES_BETA_BUILD* || "$markers" != *CORRES_APPSTORE_BUILD* ]]; then
  echo "Stopped: this build isn't a clean App Store build (beta Pro would be included). Nothing was uploaded."
  sed -i '' "s/CURRENT_PROJECT_VERSION = $next;/CURRENT_PROJECT_VERSION = $current;/g" "$PBX"
  exit 1
fi

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/export \
  -exportOptionsPlist Scripts/ExportOptions.plist -allowProvisioningUpdates

git add "$PBX"
git commit -qm "App Store build $version ($next)" || true
echo "Uploaded Corres $version ($next) for the App Store. Submit THIS build ($next) for review."
