#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?用法: run_gateway_sample.sh SKYNET_ROOT}")"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/gateway-sample"
LOG="$RUNTIME_ROOT/skynet.log"
CLIENT_LOG="$RUNTIME_ROOT/client.log"
[[ -x "$SKYNET_ROOT/skynet" ]] || { printf '找不到 Skynet: %s\n' "$SKYNET_ROOT/skynet" >&2; exit 1; }
command -v node >/dev/null || { printf '%s\n' '需要 Node.js 22 或更高版本。' >&2; exit 1; }
node -e 'if (typeof WebSocket === "undefined" || !globalThis.crypto?.subtle) process.exit(1)' || {
    printf '%s\n' 'Node.js 需要提供内置 WebSocket 和 Web Crypto。' >&2
    exit 1
}
[[ -s "$SERVER_ROOT/../shared/protocol/generated/server/lesson_03_frame_sync.pb" ]] || {
    printf '%s\n' '缺少 Lesson 3 descriptor；先运行 Server protocol build 脚本。' >&2; exit 1;
}
[[ -s "$SERVER_ROOT/lualib/gateway/protocol/protocol_registry_lesson_03_frame_sync.lua" ]] || {
    printf '%s\n' '缺少 Lesson 3 Gateway Registry；先运行 Server protocol build 脚本。' >&2; exit 1;
}
if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_gateway_crypto.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" gateway
fi
rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
export FLYWOW_GATEWAY_SAMPLE_PORT="$port"
cd "$SERVER_ROOT"
"$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" >"$LOG" 2>&1 &
pid=$!
cleanup()
{
    if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
ready=0
for _ in $(seq 1 300); do
    if grep -q 'FLYWOW_GATEWAY_READY transport=' "$LOG"; then ready=1; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then cat "$LOG" >&2; exit 1; fi
    sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then cat "$LOG" >&2; printf '%s\n' '等待 Gateway 就绪超时。' >&2; exit 1; fi
if ! node "$SCRIPT_DIR/gateway_client.mjs" "ws://127.0.0.1:$port" >"$CLIENT_LOG" 2>&1; then
    cat "$CLIENT_LOG" >&2; cat "$LOG" >&2; exit 1
fi
cat "$CLIENT_LOG"
status=0
for _ in $(seq 1 200); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" || status=$?; break; fi
    sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then cat "$LOG" >&2; printf '%s\n' 'Gateway 清理超时。' >&2; exit 1; fi
if [[ "$status" -ne 0 ]] || ! grep -q '^FLYWOW_GATEWAY_SAMPLE_OK$' "$LOG" ||
    ! grep -q 'FLYWOW_GATEWAY_SAMPLE_REQUEST_RECEIVED' "$LOG"; then cat "$LOG" >&2; exit 1; fi
cat "$LOG"
