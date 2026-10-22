#!/usr/bin/env bash
# 从 Unity golden fixture 准备地图后，在真实 Skynet Lua State 运行 Native API。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"

if [[ "$#" -lt 1 ]]; then printf '%s\n' '用法: run_navigation_sample.sh SKYNET_ROOT' >&2; exit 1; fi
SKYNET_ROOT="$(realpath -- "$1")"

RUNTIME_ROOT="$FRAMEWORK_DIR/build/navigation-sample"
LOG="$RUNTIME_ROOT/sample.log"
FIXTURE_DIR="$FRAMEWORK_DIR/navigation/unity/Tests/Editor/Fixtures"
[[ -x "$SKYNET_ROOT/skynet" ]] || { printf '找不到 Skynet: %s\n' "$SKYNET_ROOT/skynet" >&2; exit 1; }

if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_navigation_native.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" navigation
fi

rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT"
python3 - "$FIXTURE_DIR/bmap_v1.txt" "$RUNTIME_ROOT/map.bmap" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[2]).write_bytes(bytes.fromhex(Path(sys.argv[1]).read_text(encoding="ascii")))
PY

export FLYWOW_NAVIGATION_SAMPLE_MAP="$RUNTIME_ROOT/map.bmap"
cd "$SERVER_ROOT"

set +e
timeout --signal=TERM 15s "$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" 2>&1 | tee "$LOG"
status=$?
set -e

if [[ "$status" -ne 0 ]] || ! grep -q '^FLYWOW_NAVIGATION_SAMPLE_OK$' "$LOG"; then
    printf 'Navigation 示例失败，日志位于 %s\n' "$LOG" >&2
    exit 1
fi
