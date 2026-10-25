#!/usr/bin/env bash
# Register the ATLAS native-messaging helper with installed browsers.
# Usage: scripts/install-native-host.sh <chrome-extension-id> [--firefox]
#   The extension ID is shown on chrome://extensions after "Load unpacked" → Extensions/chromium.
set -euo pipefail
cd "$(dirname "$0")/.."
EXT_ID="${1:-}"
HOST_NAME="com.atlas.tracker.nm"
if [[ -x build/ATLAS.app/Contents/MacOS/atlas-nm-host ]]; then
  HOST_PATH="$(pwd)/build/ATLAS.app/Contents/MacOS/atlas-nm-host"
else
  swift build -c release
  HOST_PATH="$(swift build -c release --show-bin-path)/atlas-nm-host"
fi

write_manifest() { # dir, allowed-key, allowed-value
  mkdir -p "$1"
  cat > "$1/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "ATLAS activity bridge",
  "path": "$HOST_PATH",
  "type": "stdio",
  "$2": [$3]
}
JSON
  echo "Registered in $1"
}

SUP="$HOME/Library/Application Support"
if [[ -n "$EXT_ID" && "$EXT_ID" != --* ]]; then
  ORIGIN="\"chrome-extension://$EXT_ID/\""
  for d in "Google/Chrome" "Google/Chrome Canary" "Chromium" "Microsoft Edge" "BraveSoftware/Brave-Browser" "Vivaldi" "Arc/User Data"; do
    [[ -d "$SUP/$d" ]] && write_manifest "$SUP/$d/NativeMessagingHosts" allowed_origins "$ORIGIN"
  done
fi
if [[ " $* " == *" --firefox "* ]]; then
  write_manifest "$SUP/Mozilla/NativeMessagingHosts" allowed_extensions '"atlas-bridge@atlas.local"'
fi
echo "Host binary: $HOST_PATH"
