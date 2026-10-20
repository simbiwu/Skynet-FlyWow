#!/usr/bin/env bash
# 从 FlyWow 根目录运行；日志和临时启动产物均限定在本示例 build 目录。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?用法: run_logger_sample.sh SKYNET_ROOT}")"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/logger-sample"
LOG="$RUNTIME_ROOT/sample.log"

[[ -x "$SKYNET_ROOT/skynet" ]] || {
    printf '找不到 Skynet 可执行文件: %s\n' "$SKYNET_ROOT/skynet" >&2
    exit 1
}
if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_logger.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" logger
fi

rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT/logs"
cd "$SERVER_ROOT"

set +e
timeout --signal=TERM 30s "$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" 2>&1 | tee "$LOG"
sample_status=${PIPESTATUS[0]}
set -e

if [[ "$sample_status" -ne 0 ]] || ! grep -q '^FLYWOW_LOGGER_SAMPLE_OK$' "$LOG"; then
    printf 'Logger 示例失败，日志位于 %s\n' "$LOG" >&2
    exit 1
fi

LOGGER_FILE="$RUNTIME_ROOT/logs/$(date +%F).log"
[[ -s "$LOGGER_FILE" ]] || {
    printf 'Logger 未生成预期日志文件: %s\n' "$LOGGER_FILE" >&2
    exit 1
}
grep -q 'FLYWOW_LOGGER_SAMPLE_NORMAL' "$LOGGER_FILE"
grep -q 'FLYWOW_LOGGER_SAMPLE_ERROR' "$LOGGER_FILE"
