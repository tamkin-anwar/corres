#!/bin/zsh
# corres.app's devices: real screenshots inside Apple's Product Bezels, as
# web-sized WebP for the dark and light page. Only these small copies go on
# the site; Apple's full-size bezels stay on this Mac (Apple Design
# Resources terms: drawn as supplied, never redrawn, tilted or recolored).
#
#   Scripts/site-devices.sh <captures dir> <portfolio>/public/corres/img/devices
#
# Captures are named <name>-dark.png / <name>-light.png: iphone-*, ipad-*,
# mac-*, and the Watch set comes from Docs/AppStore/watch. Mount the bezel
# disk images first (Bezel-iPhone-18, Bezel-iPad-Pro-(M5),
# Bezel-MacBook-Pro-M5, Bezel-Apple-Watch-Series-11-2025).
set -euo pipefail
here=${0:A:h}/..
shots=${1:?captures dir}
out=${2:?output dir}
mkdir -p "$out"
tmp=$(mktemp -d)

typeset -A bezel
bezel[iphone-dark]="/Volumes/Bezel-iPhone-18/PNG/iPhone 18 Pro/iPhone 18 Pro - Black - Portrait.png"
bezel[iphone-light]="/Volumes/Bezel-iPhone-18/PNG/iPhone 18 Pro/iPhone 18 Pro - Silver - Portrait.png"
bezel[ipad-dark]="/Volumes/Bezel-iPad-Pro-(M5)/PNG/iPad Pro (M5) 13\" - Space Black - Landscape.png"
bezel[ipad-light]="/Volumes/Bezel-iPad-Pro-(M5)/PNG/iPad Pro (M5) 13\" - Silver - Landscape.png"
bezel[mac-dark]="/Volumes/Bezel-MacBook-Pro-M5/PNG/MacBook Pro M5 14-inch Space Black.png"
bezel[mac-light]="/Volumes/Bezel-MacBook-Pro-M5/PNG/MacBook Pro M5 14-inch Silver.png"
bezel[watch-dark]="/Volumes/Bezel-Apple-Watch-Series-11-2025/PNG/Sport Band/Apple Watch S11 - 46mm - Aluminum Jet Black + Sport Band Black.png"
bezel[watch-light]="/Volumes/Bezel-Apple-Watch-Series-11-2025/PNG/Sport Band/Apple Watch S11 - 46mm - Aluminum Silver + Sport Band Purple Fog.png"
# Web widths (2× the largest size the page draws them at).
typeset -A width=(iphone 640 ipad 1400 mac 2000 watch 320)
# The desktop behind a Mac window, matching the page.
typeset -A desk=(dark "#16171C" light "#DCDFE4")

render() { # kind mode capture name
  local kind=$1 mode=$2 capture=$3 name=$4
  swift "$here/Scripts/RenderDeviceShot.swift" "${bezel[$kind-$mode]}" "$capture" "$tmp/$name-$mode.png" "${desk[$mode]}" >/dev/null
  cwebp -quiet -q 82 -alpha_q 90 -resize ${width[$kind]} 0 "$tmp/$name-$mode.png" -o "$out/$name-$mode.webp"
  echo "$name-$mode.webp $(( $(stat -f %z "$out/$name-$mode.webp") / 1024 )) KB"
}

for capture in "$shots"/*-(dark|light).png(N); do
  base=${capture:t:r}; mode=${base##*-}; name=${base%-*}; kind=${name%%-*}
  [[ -n ${bezel[$kind-$mode]:-} ]] || { echo "skipped $base"; continue }
  render $kind $mode "$capture" "$name"
done
# The Watch app is dark in either appearance; only the case changes.
for mode in dark light; do
  render watch $mode "$here/Docs/AppStore/watch/watch-1.png" watch-needs-you
done
rm -rf "$tmp"
