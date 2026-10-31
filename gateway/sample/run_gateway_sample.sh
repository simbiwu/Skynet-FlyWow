#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/third_party/skynet-flywow/gateway/sample/run_gateway_sample.sh [按本文件头部说明填写参数]
# 从脚本目录定位宿主 Server；参数为模式及固定 Skynet 根目录。
# 运行会重建 build/gateway-sample/<模式> 日志目录，启动一个 Skynet 子进程并在退出时回收。
# 缺少 Native 时调用统一构建入口；本脚本自身不生成宿主协议产物。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   shift 丢弃第一个位置参数，其余参数向前移动一位。
#   [[ 条件 ]]执行 Bash 条件判断；-x检查可执行文件，-s检查非空文件，-e检查存在的路径。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   name() { ...; }定义函数；调用函数名即可执行函数体。
#   for/while ... do ... done 重复执行循环体；列表或条件决定循环何时结束。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   trap 登记退出或信号时执行的清理动作；单引号使变量在事件发生时再展开。
#   命令末尾的 & 在后台启动进程；$!取得最近后台进程 PID，wait 等待它并收取退出码。
#   export 把变量加入子进程环境；普通赋值默认只在当前 Shell 中可见。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)" # 脚本真实目录；用于定位 sample 配置与客户端入口。
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)" # FlyWow 子模块根目录；构建与运行时产物都在此目录下。
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)" # 宿主 Server 根目录；作为 Skynet 工作目录。
# mode 默认选择 WebSocket；首个参数只有匹配 websocket/protobuf/binary 时才被 shift 消耗为模式。
mode=websocket # 未显式指定模式时运行 WebSocket sample。
if [[ $# -gt 0 ]]; then
    case "$1" in
        websocket|protobuf|binary) mode="$1"; shift ;;
    esac
fi
if [[ $# -lt 1 ]]; then
    printf '%s\n' '用法: run_gateway_sample.sh [websocket|protobuf|binary] SKYNET_ROOT' >&2
    exit 2
fi
# SKYNET_ROOT 来自调用者必填参数；realpath 规范成绝对路径，相对输入按启动命令所在目录解释。
SKYNET_ROOT="$(realpath -- "$1")" # 调用方提供的固定 Skynet checkout，后续校验并启动其二进制。
RUNTIME_ROOT="$FRAMEWORK_DIR/build/gateway-sample/$mode" # 本模式独立日志目录；每次运行前重建。
LOG="$RUNTIME_ROOT/skynet.log" # 本次 Skynet 进程输出，供失败诊断和成功标记检查。
CLIENT_LOG="$RUNTIME_ROOT/client.log" # 当前 Node 客户端输出，失败时回显。
[[ -x "$SKYNET_ROOT/skynet" ]] || { printf '找不到 Skynet: %s\n' "$SKYNET_ROOT/skynet" >&2; exit 1; }
command -v node >/dev/null || { printf '%s\n' '需要 Node.js 22 或更高版本。' >&2; exit 1; }
# Node 的 -e 会执行紧随其后的 JavaScript 检查；0 代表能力可用，非零由 || 分支输出统一错误。
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
# 只清除本 sample 自己的运行目录，移除旧日志和旧成功标记后再开始本次运行。
rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')" # 由系统分配的临时 loopback 端口，避免固定端口冲突。
export FLYWOW_GATEWAY_SAMPLE_PORT="$port"
export FLYWOW_GATEWAY_SAMPLE_MODE="$mode"
# Skynet 使用相对模块搜索路径，因此启动前切换到由脚本位置计算出的 Server 根目录。
cd "$SERVER_ROOT"
"$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" >"$LOG" 2>&1 &
pid=$! # 只回收此脚本启动的 Skynet 子进程。
# EXIT trap 只回收本次启动的 Skynet PID；保留日志供失败诊断。
cleanup()
{
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}
# 将 cleanup 登记为 EXIT 动作；正常结束和错误退出都会尝试回收本脚本创建的 Skynet 进程。
trap cleanup EXIT
ready=0 # Gateway 就绪标记；等待循环最多运行 30 秒。
# 每次 sleep 0.1 秒，最多 300 轮即 30 秒；_ 是未使用的循环计数值。
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
        client_status=0 # 当前模式客户端退出码；非零时保留并回显诊断日志。
        node "$SCRIPT_DIR/gateway_client.mjs" "ws://127.0.0.1:$port" >"$CLIENT_LOG" 2>&1 || client_status=$?
        ;;
    protobuf)
        client_status=0 # 当前模式客户端退出码；非零时保留并回显诊断日志。
        node "$SCRIPT_DIR/tcp_protobuf/gateway_client.mjs" "$port" >"$CLIENT_LOG" 2>&1 || client_status=$?
        ;;
    binary)
        client_status=0 # 当前模式客户端退出码；非零时保留并回显诊断日志。
        node "$SCRIPT_DIR/tcp_binary/gateway_client.mjs" "$port" >"$CLIENT_LOG" 2>&1 || client_status=$?
        ;;
esac
if [[ "$client_status" -ne 0 ]]; then
    cat "$CLIENT_LOG" >&2
    cat "$LOG" >&2
    exit "$client_status"
fi
cat "$CLIENT_LOG"
status=0 # Skynet 子进程实际退出码，后续与 sample 成功标记一起判定结果。
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
