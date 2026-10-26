# Localized App Store screenshots

Made 2026-10-22 for every store language. Sample mail only, never real mail.

1. Build the debug iPhone app (and Mac app) and install it on the
   "Corres L10n" simulator; set its status bar to 9:57 with a full battery
   that isn't charging (`xcrun simctl status_bar <id> override --time 9:57
   --batteryState discharging --batteryLevel 100`). Never the charging bolt.
2. `capture-iphone.sh`: Needs You, Everything, a reply (`-SampleReplies
   -OpenThread sample-0`) and the bottom tabs, in each language, into
   /tmp/claude-501/shots/loc. Check for splash frames (tiny files) and
   retake with a longer wait.
3. `capture-mac.sh`: the reply and a receipt's Key Details, from the debug
   Mac build with `-SampleMailOnly -CorresScreenshots`. The window must be
   on the current desktop Space.
4. Render each with `swift Scripts/RenderStoreShot.swift <capture> <out>
   <headline> <line>` using `headlines.json`.

Uploaded to App Store Connect per locale (fr-CA uses French, es-MX
Spanish): four iPhone (6.3" set), two Mac. English keeps its fuller sets
plus Apple Watch. The rendered files live in
Docs/AppStore/localized-shots/ locally and aren't committed.
