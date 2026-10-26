# Sourced by Scripts/testflight.sh, testflight-mac.sh and appstore.sh.
# With an App Store Connect API key configured, xcodebuild signs and
# uploads with it instead of the Apple ID signed in to Xcode. Without one,
# ASC_AUTH stays empty and the scripts work exactly as before.
# Setup: Docs/asc-api-key.md.
#
# Configure with ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH in the
# environment, or in ~/.corres/asc.env (ASC_ENV_FILE to use another file),
# which is read only when the environment doesn't already have all three.
# Never prints the key itself, only its id.

ASC_AUTH=()
if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || -z "${ASC_KEY_PATH:-}" ]]; then
  asc_env_file="${ASC_ENV_FILE:-$HOME/.corres/asc.env}"
  if [[ -f "$asc_env_file" ]]; then
    source "$asc_env_file"
  fi
fi

if [[ -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" || -n "${ASC_KEY_PATH:-}" ]]; then
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || -z "${ASC_KEY_PATH:-}" ]]; then
    echo "Stopped: the App Store Connect API key needs all three of ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH. Nothing was built."
    exit 1
  fi
  asc_key_path="${ASC_KEY_PATH/#\~/$HOME}"
  if [[ ! -r "$asc_key_path" ]]; then
    echo "Stopped: can't read the API key file at ASC_KEY_PATH. Nothing was built."
    exit 1
  fi
  # Keep the key out of the repo, where a commit could pick it up.
  asc_key_dir="$(cd "$(dirname "$asc_key_path")" && pwd -P)"
  if [[ "$asc_key_dir/" == "$(pwd -P)/"* ]]; then
    echo "Stopped: the API key file is inside the repo. Move it to ~/.corres (see Docs/asc-api-key.md). Nothing was built."
    exit 1
  fi
  asc_key_mode="$(stat -L -f %Lp "$asc_key_path")"
  if (( (8#$asc_key_mode & 8#077) != 0 )); then
    echo "Note: the API key file can be read by other users on this Mac. Run: chmod 600 \"$asc_key_path\""
  fi
  ASC_AUTH=(-authenticationKeyPath "$asc_key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "Using App Store Connect API key $ASC_KEY_ID for signing and upload."
fi
