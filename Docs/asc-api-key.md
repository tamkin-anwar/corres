# App Store Connect API key for uploads

`Scripts/testflight.sh`, `Scripts/testflight-mac.sh` and `Scripts/appstore.sh`
sign and upload with the Apple ID signed in to Xcode. When that sign-in
expires or Xcode asks for it again, uploads stop. With an App Store Connect
API key set up, the scripts pass it to `xcodebuild` (`-authenticationKeyPath`,
`-authenticationKeyID`, `-authenticationKeyIssuerID`) for both the archive
and the export and upload, and the Xcode account isn't needed. Without a
key they work exactly as before. The shared logic is in `Scripts/asc-auth.sh`.

## What kind of key

- A **Team** key, not an Individual key. Apple: individual keys "aren't able
  to use Provisioning endpoints", and `-allowProvisioningUpdates` needs them.
- Role: **Admin**. The scripts use automatic signing, so the export signs with
  a cloud-managed distribution certificate and may create or update
  distribution profiles. With a Developer or App Manager key `-exportArchive`
  fails with "Cloud signing permission error": users with those roles can be
  given access to cloud-managed certificates in Users and Access, but an API
  key can't, so only Admin works. A lower role would only work with a local
  Apple Distribution certificate and profiles, which is the setup this
  replaces.
- Admin is a powerful key (it can also manage users), so keep it only on this
  Mac and revoke it if it might have leaked.

Sources: [Creating API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api),
[Roles](https://developer.apple.com/help/account/access/roles/),
[forum: cloud signing needs an Admin key](https://developer.apple.com/forums/thread/698117),
`man xcodebuild`.

## Create it (Account Holder or Admin)

1. [App Store Connect](https://appstoreconnect.apple.com) > Users and Access > Integrations > App Store Connect API > Team Keys.
2. Generate API Key, name it (say "Corres uploads"), Access: Admin, Generate.
3. Note the **Issuer ID** (above the keys list) and the key's **Key ID**.
4. Download the `.p8`. Apple lets you download it only once.

## Put it on this Mac, outside the repo

```bash
mkdir -p ~/.corres && chmod 700 ~/.corres
mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/.corres/
chmod 600 ~/.corres/AuthKey_<KEY_ID>.p8
cat > ~/.corres/asc.env <<'EOF'
ASC_KEY_ID=<KEY_ID>
ASC_ISSUER_ID=<ISSUER_ID>
ASC_KEY_PATH=~/.corres/AuthKey_<KEY_ID>.p8
EOF
chmod 600 ~/.corres/asc.env
```

The scripts read `~/.corres/asc.env` when the three `ASC_` variables aren't
already set in the environment (`ASC_ENV_FILE` points them at another file).
They stop if only some are set, if the key file can't be read, or if it sits
inside the repo, and they warn if other users can read it. They print the
key id, never the key. `*.p8` is in `.gitignore` as a second guard.

## Test it

1. Without uploading: ask App Store Connect for the Corres app record with a
   token made from the key. The token stays in a variable and isn't printed.
   ```bash
   source ~/.corres/asc.env
   jwt=$(xcrun altool --generate-jwt --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
     --p8-file-path "${ASC_KEY_PATH/#\~/$HOME}" 2>/dev/null | tail -1)
   curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $jwt" \
     "https://api.appstoreconnect.apple.com/v1/apps?filter%5BbundleId%5D=studio.anwarcreative.corres"
   ```
   200 means the key works. 401 means a wrong key id, issuer id or file.
2. A real run: the next TestFlight upload prints "Using App Store Connect API
   key ..." near the start. To be sure the key is doing the work, sign out
   of Xcode (Settings > Accounts) for that run.
3. To go back to the Xcode account, move `~/.corres/asc.env` aside.

## The listing, from the repo

`node Scripts/asc-listing.mjs` uses the same key to keep App Store Connect's
listing in step with `Docs/app-store-listing.md` (English) and
`Docs/AppStore/localized/listing.json` (every other language):

- `status`: what's there now, per platform and language (read-only).
- `diff [locale]`: what `apply` would change, line by line (read-only).
- `apply`: descriptions, keywords, promotional text and subtitles, for
  versions that can still be edited. Nothing is submitted.
- `watch-shots`: the Apple Watch screenshots, if that set is empty.
- `iap`: the in-app purchases' settings (read-only).
