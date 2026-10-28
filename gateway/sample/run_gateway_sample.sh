#!/usr/bin/env bash
# 从脚本目录定位宿主 Server；参数为模式及固定 Skynet 根目录。
# 运行会重建 build/gateway-sample/<模式> 日志目录，启动一个 Skynet 子进程并在退出时回收。
# 缺少 Native 时调用统一构建入口；本脚本自身不生成宿主协议产物。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"
mode=websocket
if [[ $# -gt 0 ]]; then
    case "$1" in
        websocket|protobuf|binary) mode="$1"; shift ;;
    esac
fi
if [[ $# -lt 1 ]]; then
    printf '%s\n' '用法: run_gateway_sample.sh [websocket|protobuf|binary] SKYNET_ROOT' >&2
    exit 2
fi
SKYNET_ROOT="$(realpath -- "$1")"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/gateway-sample/$mode"
LOG="$RUNTIME_ROOT/skynet.log"
CLIENT_LOG="$RUNTIME_ROOT/client.log"
[[ -x "$SKYNET_ROOT/skynet" ]] || { printf '找不到 Skynet: %s\n' "$SKYNET_ROOT/skynet" >&2; exit 1; }
command -v node >/dev/null || { printf '%s\n' '需要 Node.js 22 或更高版本。' >&2; exit 1; }
node -e 'if (!globalThis.crypto?.subtle || (process.argv[1] === "websocket" && typeof WebSocket === "undefined")) process.exit(1)' "$mode" || {
    printf '%s\n' 'Node.js 需要提供 sample 所需的 Web Crypto 和 WebSocket。' >&2
    exit 1
}
[[ -s "$SERVER_ROOT/../shared/protocol/generated/server/lesson_03_frame_sync.pb" ]] || {
    printf '%s\n' '缺少 Lesson 3 descriptor；先运行 Server protocol build 脚本。' >&2
    exit 1
}
[[ -s "$SERVER_ROOT/lualib/gateway/protocol/protocol_registry_lesson_03_frame_sync.lua" ]] || {
    printf '%s\n' '缺少 Lesson 3 Gateway Registry；先运行 Server protocol build 脚本。' >&2
    exit 1
}
if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_gateway_crypto.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" gateway
fi
rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
export FLYWOW_GATEWAY_SAMPLE_PORT="$port"
export FLYWOW_GATEWAY_SAMPLE_MODE="$mode"
cd "$SERVER_ROOT"
"$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" >"$LOG" 2>&1 &
pid=$!
# EXIT trap 只回收本次启动的 Skynet PID；保留日志供失败诊断。
cleanup()
{
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
ready=0
for _ in $(seq 1 300); do
    if grep -q 'FLYWOW_GATEWAY_READY transport=' "$LOG"; then ready=1; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then cat "$LOG" >&2; exit 1; fi
    sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then
    cat "$LOG" >&2
    printf '%s\n' '等待 Gateway 就绪超时。' >&2
    exit 1
fi
case "$mode" in
    websocket)
        client_status=0
        node "$SCRIPT_DIR/gateway_client.mjs" "ws://127.0.0.1:$port" >"$CLIENT_LOG" 2>&1 || client_status=$?
        ;;
    protobuf)
        client_status=0
        node "$SCRIPT_DIR/tcp_protobuf/gateway_client.mjs" "$port" >"$CLIENT_LOG" 2>&1 || client_status=$?
        ;;
    binary)
        client_status=0
        node "$SCRIPT_DIR/tcp_binary/gateway_client.mjs" "$port" >"$CLIENT_LOG" 2>&1 || client_status=$?
        ;;
esac
if [[ "$client_status" -ne 0 ]]; then
    cat "$CLIENT_LOG" >&2
    cat "$LOG" >&2
    exit "$client_status"
fi
cat "$CLIENT_LOG"
status=0
for _ in $(seq 1 200); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" || status=$?; break; fi
    sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then
    cat "$LOG" >&2
    printf '%s\n' 'Gateway 清理超时。' >&2
    exit 1
fi
if [[ "$status" -ne 0 ]] ||
    ! grep -q "FLYWOW_GATEWAY_SAMPLE_OK mode=$mode" "$LOG" ||
    ! grep -q "FLYWOW_GATEWAY_SAMPLE_REQUEST_RECEIVED mode=$mode" "$LOG" ||
    ! grep -q "FLYWOW_GATEWAY_SAMPLE_PUSH_SENT mode=$mode" "$LOG"; then
    cat "$LOG" >&2
    exit 1
fi
cat "$LOG"
