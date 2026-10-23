#!/bin/bash
APP=/tmp/claude-501/ddmac/Build/Products/Debug/Corres.app
OUT=/tmp/claude-501/shots/loc
cap() { # lang name args...
  local lang=$1 name=$2; shift 2
  pkill -f "Debug/Corres.app/Contents/MacOS/Corres"; sleep 1
  "$APP/Contents/MacOS/Corres" -AppleLanguages "($lang)" -SampleMailOnly -CorresScreenshots "$@" > /dev/null 2>&1 &
  local pid=$!
  sleep 10; open "$APP"; sleep 4
  local w=$(/tmp/claude-501/winid $pid | awk '$2==1280{print $1}' | head -1)
  screencapture -x -o -l $w "$OUT/$lang-$name.png"
  kill $pid 2>/dev/null
}
for lang in ja zh-Hans de ko fr es pt-BR bn; do
  cap $lang mac-replies -SampleReplies -SelectThread sample-0
  cap $lang mac-details -ShowMailbox everything -SelectThread sample-6
  echo "done $lang"
done
echo ALLDONE
