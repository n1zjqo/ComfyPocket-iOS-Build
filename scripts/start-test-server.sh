#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"
TEMPORARY="$(printenv RUNNER_TEMP || true)"
[[ -n "$TEMPORARY" ]] || TEMPORARY="$BUILD"
DIRECTORY="$TEMPORARY/ComfyPocket-ComfyUI-v0.3.26"
REVISION=9aac21f894a122ddb8d825c57ad61c0db5e630db
mkdir -p "$DIRECTORY"
if [[ ! -f "$DIRECTORY/main.py" ]]; then
  ARCHIVE="$DIRECTORY/source.tar.gz"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 2 "https://codeload.github.com/Comfy-Org/ComfyUI/tar.gz/$REVISION" -o "$ARCHIVE"
  printf '%s  %s\n' 9e298ea612b659823789bf107adf533e76270baa2ebfe8cd7a2ca57c1230463f "$ARCHIVE" | shasum -a 256 -c -
  tar -xzf "$ARCHIVE" -C "$DIRECTORY" --strip-components=1
fi
python3 -m venv "$DIRECTORY/.venv"
[[ "$(uname -m)" == arm64 ]] || { echo 'The reviewed dependency lock targets macOS arm64 + CPython 3.12 only.' >&2; exit 1; }
"$DIRECTORY/.venv/bin/python" -m pip install --index-url https://pypi.org/simple --only-binary=:all: --require-hashes --requirement "$ROOT/scripts/comfyui-ci-requirements.lock.txt" 2>&1 | tee "$BUILD/comfyui-install.log"
"$DIRECTORY/.venv/bin/python" -m pip check
cd "$DIRECTORY"
nohup "$DIRECTORY/.venv/bin/python" main.py --cpu --listen 127.0.0.1 --port 8188 --disable-all-custom-nodes --disable-auto-launch --output-directory "$DIRECTORY/test-output" > "$BUILD/comfyui-server.log" 2>&1 &
SERVER_PID=$!
printf '%s\n' "$SERVER_PID" > "$BUILD/comfyui-test-server.pid"
for attempt in $(seq 1 180); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:8188/system_stats > "$BUILD/comfyui-stats.json"; then
    printf 'Official ComfyUI %s is ready for native integration tests.\n' "$REVISION"
    exit 0
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    tail -n 100 "$BUILD/comfyui-server.log"
    exit 1
  fi
  sleep 1
done
tail -n 100 "$BUILD/comfyui-server.log"
echo 'ComfyUI startup timed out.' >&2
exit 1
