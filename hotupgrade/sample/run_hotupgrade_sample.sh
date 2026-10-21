#!/usr/bin/env bash
# 从 FlyWow 根目录运行；第一个参数是 Skynet 根目录。准备隔离宿主/Patch 并运行真实 Skynet 示例。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?用法: run_hotupgrade_sample.sh SKYNET_ROOT}")"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/hotupgrade-sample"
HOST_ROOT="$RUNTIME_ROOT/host"
PATCH_ROOT="$RUNTIME_ROOT/patches"
LOG="$RUNTIME_ROOT/sample.log"

[[ -x "$SKYNET_ROOT/skynet" ]] || {
    printf '找不到 Skynet 可执行文件: %s\n' "$SKYNET_ROOT/skynet" >&2
    exit 1
}

if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_hotupgrade_native.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" hotupgrade
fi

rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$HOST_ROOT" "$PATCH_ROOT"
cp -a "$SCRIPT_DIR/host_v1/." "$HOST_ROOT/"
cp -a "$SCRIPT_DIR/patches/." "$PATCH_ROOT/"

export HOTUPGRADE_SAMPLE_ROOT="$RUNTIME_ROOT"
cd "$SERVER_ROOT"

set +e
timeout --signal=TERM 60s "$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" 2>&1 | tee "$LOG"
sample_status=${PIPESTATUS[0]}
set -e

if [[ "$sample_status" -ne 0 ]] || ! grep -q '^HOTUPGRADE_SAMPLE_OK$' "$LOG"; then
    printf 'HotUpgrade 示例失败，日志位于 %s\n' "$LOG" >&2
    exit 1
fi
