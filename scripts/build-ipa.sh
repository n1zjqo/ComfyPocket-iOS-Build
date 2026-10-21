#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This build requires macOS with Xcode. No IPA was created." >&2
  exit 1
fi
for tool in xcodebuild xcrun xcodegen swift codesign ditto python3; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
if [[ -f SOURCE-SNAPSHOT.json ]]; then python3 scripts/verify-source-snapshot.py; fi
BUILD="$ROOT/build"
mkdir -p "$BUILD"
xcodebuild -version | tee "$BUILD/xcode-version.txt"
python3 scripts/test_verify_ipa.py 2>&1 | tee "$BUILD/validator-tests.log"
swift test --package-path Core 2>&1 | tee "$BUILD/core-tests.log"
xcodegen generate
SKIP_UI_TESTS="$(printenv SKIP_UI_TESTS || true)"
if [[ "$SKIP_UI_TESTS" != 1 ]]; then
  SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); a=[v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if v.get("isAvailable",False) and v["name"] in ["iPhone XS","ComfyPocket iPhone XS"]]; print(a[0] if a else "")')"
  if [[ -z "$SIMULATOR_ID" ]]; then
    RUNTIME="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; a=[v for v in json.load(sys.stdin)["runtimes"] if v.get("isAvailable",False) and v["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-") and v["version"].split(".")[0] == "18"]; a.sort(key=lambda v: tuple(map(int,v["version"].split(".")))); print(a[-1]["identifier"] if a else "")')"
    [[ -n "$RUNTIME" ]] || { echo "Install an iOS 18 simulator runtime for the iPhone XS display checks." >&2; exit 1; }
    SIMULATOR_ID="$(xcrun simctl create "ComfyPocket iPhone XS" com.apple.CoreSimulator.SimDeviceType.iPhone-XS "$RUNTIME")"
  fi
  xcrun simctl list devices available | tee "$BUILD/simulators.txt"
  UI_RESULT="$BUILD/Smoke-$(date +%Y%m%d-%H%M%S).xcresult"
  UI_STATUS=0
  xcodebuild -project ComfyPocket.xcodeproj -scheme ComfyPocket -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath "$BUILD/SimDerivedData" \
    -resultBundlePath "$UI_RESULT" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test 2>&1 | tee "$BUILD/ui-tests.log" || UI_STATUS=$?
  xcrun xcresulttool export attachments --path "$UI_RESULT" --output-path "$BUILD/screenshots"
  if [[ "$UI_STATUS" != 0 ]]; then exit "$UI_STATUS"; fi
fi
xcodebuild -project ComfyPocket.xcodeproj -scheme ComfyPocket -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=15.0 build 2>&1 | tee "$BUILD/device-build.log"
APP="$BUILD/DerivedData/Build/Products/Release-iphoneos/ComfyPocket.app"
[[ -d "$APP" ]] || { echo "Xcode did not produce ComfyPocket.app" >&2; exit 1; }
STAGING="$(mktemp -d "$BUILD/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
ditto "$APP" "$STAGING/Payload/ComfyPocket.app"
PACKAGED="$STAGING/Payload/ComfyPocket.app"
while IFS= read -r -d '' library; do codesign --force --sign - --timestamp=none "$library"; done < <(find "$PACKAGED" -type f -name '*.dylib' -print0)
if [[ -d "$PACKAGED/Frameworks" ]]; then
  while IFS= read -r -d '' framework; do codesign --force --sign - --timestamp=none "$framework"; done < <(find "$PACKAGED/Frameworks" -depth -type d -name '*.framework' -print0)
fi
codesign --force --sign - --timestamp=none --entitlements "$ROOT/App/ComfyPocket.entitlements" "$PACKAGED"
codesign --verify --deep --strict --verbose=2 "$PACKAGED"
IPA="$BUILD/ComfyPocket-iOS15.ipa"
if [[ -e "$IPA" ]]; then mv "$IPA" "$BUILD/ComfyPocket-previous-$(date +%Y%m%d-%H%M%S).ipa"; fi
(cd "$STAGING" && ditto -c -k --keepParent Payload "$IPA")
python3 scripts/verify-ipa.py "$IPA"
shasum -a 256 "$IPA" | tee "$IPA.sha256"
printf '\nBuilt: %s\n' "$IPA"
