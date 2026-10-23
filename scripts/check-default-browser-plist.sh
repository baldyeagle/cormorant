#!/usr/bin/env bash
# Checks the app against Apple's default-browser entitlement requirements that can be verified
# statically: https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser
#   - http and https are declared in CFBundleURLTypes
#   - none of the forbidden usage-description keys appear in any Info.plist or entitlements file
#   - UIWebView is not referenced anywhere in app source
# Usage: scripts/check-default-browser-plist.sh [path/to/built/Cormorant.app]
# With no argument it checks the source plists under apps/ios.
set -euo pipefail
cd "$(dirname "$0")/.."

FORBIDDEN=(
  NSPhotoLibraryUsageDescription
  NSLocationAlwaysUsageDescription
  NSLocationAlwaysAndWhenInUseUsageDescription
  NSHomeKitUsageDescription
  NSBluetoothAlwaysUsageDescription
  NSHealthShareUsageDescription
  NSHealthUpdateUsageDescription
)

if [[ $# -ge 1 ]]; then
  APP_PLIST="$1/Info.plist"
  PLISTS=("$APP_PLIST")
  while IFS= read -r p; do PLISTS+=("$p"); done < <(find "$1/PlugIns" -name Info.plist 2>/dev/null)
else
  APP_PLIST="apps/ios/Cormorant/Info.plist"
  PLISTS=("$APP_PLIST" apps/ios/CormorantShare/Info.plist apps/ios/Cormorant/Cormorant.entitlements apps/ios/CormorantShare/CormorantShare.entitlements)
fi

fail=0
schemes=$(plutil -extract CFBundleURLTypes json -o - "$APP_PLIST" 2>/dev/null | tr -d ' \n' || true)
for s in http https; do
  if [[ "$schemes" != *"\"$s\""* ]]; then echo "FAIL: scheme '$s' missing from CFBundleURLTypes in $APP_PLIST"; fail=1; fi
done

for p in "${PLISTS[@]}"; do
  [[ -f "$p" ]] || { echo "FAIL: missing $p"; fail=1; continue; }
  plutil -lint -s "$p" || { echo "FAIL: $p is not a valid plist"; fail=1; }
  for k in "${FORBIDDEN[@]}"; do
    if grep -q "$k" "$p"; then echo "FAIL: forbidden key $k in $p"; fail=1; fi
  done
done

if grep -rn "UIWebView" apps/ios --include='*.swift' | grep -v "^.*//" ; then
  echo "FAIL: UIWebView referenced in app source"; fail=1
fi

if [[ $fail -eq 0 ]]; then echo "OK: default-browser plist checklist passes"; fi
exit $fail
