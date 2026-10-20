#!/usr/bin/env bash
# 在真实 Skynet Lua State 中运行 WordFilter 的公开 Lua/Native API。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"
if [[ "$#" -lt 1 ]]; then printf '%s\n' '用法: run_word_filter_sample.sh SKYNET_ROOT' >&2; exit 1; fi
SKYNET_ROOT="$(realpath -- "$1")"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/word-filter-sample"
LOG="$RUNTIME_ROOT/sample.log"
[[ -x "$SKYNET_ROOT/skynet" ]] || { printf '找不到 Skynet: %s\n' "$SKYNET_ROOT/skynet" >&2; exit 1; }
if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_word_filter_native.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" word_filter
fi
rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT"
cd "$SERVER_ROOT"
set +e
timeout --signal=TERM 15s "$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" 2>&1 | tee "$LOG"
status=$?
set -e
if [[ "$status" -ne 0 ]] || ! grep -q '^FLYWOW_WORD_FILTER_SAMPLE_OK$' "$LOG"; then
    printf 'WordFilter 示例失败，日志位于 %s\n' "$LOG" >&2
    exit 1
fi
