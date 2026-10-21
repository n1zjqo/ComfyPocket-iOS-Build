#!/bin/bash
set -euo pipefail
DIRECTORY="$(mktemp -d "${RUNNER_TEMP:-/tmp}/comfypocket-xcodegen.XXXXXX")"
ARCHIVE="$DIRECTORY/xcodegen.zip"
curl --fail --location --proto '=https' --tlsv1.2 --retry 2 https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip -o "$ARCHIVE"
printf '%s  %s\n' a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73 "$ARCHIVE" | shasum -a 256 -c -
ditto -x -k "$ARCHIVE" "$DIRECTORY"
"$DIRECTORY/xcodegen/bin/xcodegen" --version
printf '%s\n' "$DIRECTORY/xcodegen/bin" >> "$GITHUB_PATH"

