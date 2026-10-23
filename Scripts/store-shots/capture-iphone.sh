#!/bin/bash
D=34836922-3486-45D5-B6F1-3B85D044FBE5
APP=studio.anwarcreative.corres
OUT=/tmp/claude-501/shots/loc
cap() { # lang locale name args...
  local lang=$1 loc=$2 name=$3; shift 3
  xcrun simctl launch --terminate-running-process $D $APP -AppleLanguages "($lang)" -AppleLocale $loc -CorresScreenshots "$@" >/dev/null
  sleep 20
  xcrun simctl io $D screenshot "$OUT/$lang-$name.png" >/dev/null 2>&1
}
for pair in "ja ja_JP" "zh-Hans zh_CN" "de de_DE" "ko ko_KR" "fr fr_FR" "es es_ES" "pt-BR pt_BR" "bn bn_BD"; do
  set -- $pair
  cap $1 $2 needs -corres.tabsAtBottom NO -corres.mailFilter "Needs You"
  cap $1 $2 everything -corres.tabsAtBottom NO -corres.mailFilter Everything
  cap $1 $2 replies -corres.tabsAtBottom NO -SampleReplies -OpenThread sample-0
  cap $1 $2 tabs -corres.tabsAtBottom YES -corres.mailFilter Primary
  echo "done $1"
done
xcrun simctl launch --terminate-running-process $D $APP -AppleLanguages "(en)" -corres.tabsAtBottom NO >/dev/null; sleep 10; xcrun simctl terminate $D $APP
echo ALLDONE
