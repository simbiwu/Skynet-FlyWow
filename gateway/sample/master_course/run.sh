#!/usr/bin/env bash
# 用途：构建 Gateway 课程协议并启动服务端，或启动客户端完成一次 WebSocket/TCP 示例。
# 工作目录：可从任意目录运行；脚本根据自身位置查找 FlyWow、Server 和 Skynet，不依赖调用者当前目录。
# 参数：prepare 独立准备依赖；运行模式下第一个参数是 websocket/tcp（默认 websocket），第二个是 client/server（默认 client）。
# 示例：bash /path/to/skynet-flywow/gateway/sample/master_course/run.sh prepare
# 示例：bash /path/to/skynet-flywow/gateway/sample/master_course/run.sh websocket client
# 示例：bash gateway/sample/master_course/run.sh tcp server
# 前置条件：固定 Skynet、宿主 lua-protobuf、FlyWow Gateway Native 和 Node.js 均已构建/安装。
# 行为：client 模式会启动临时服务、运行客户端并在退出时清理服务；server 模式以前台方式运行服务。
# Bash 语法：变量用 "$NAME" 引用；双引号保护空格；# 开头是注释；本脚本用缩进展示 if/for 函数块。
# Bash 语法：[[ ... ]] 是条件判断；&& 表示前项成功后继续；|| 表示前项失败时执行后项。
# Bash 语法：$(命令) 捕获命令输出；${变量:-默认值} 在变量未设置时采用默认值；for 循环中的 _ 表示本脚本不需要循环序号。
# Bash 语法：>&2 把错误信息写到标准错误；> 与 2>&1 分别重定向标准输出和标准错误。
# Bash 语法：& 将进程放到后台；$! 是最近后台进程的 PID；trap 在脚本退出时执行清理函数；exec 用程序替换当前脚本进程。
set -euo pipefail

# 计算脚本和依赖仓库的绝对路径。dirname "$0" 取得脚本所在目录；cd 后用 pwd 得到绝对路径。
# -- 结束 cd 的选项解析，避免路径以短横线开头时被当成选项。
COURSE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FLYWOW_ROOT="$(cd "$COURSE_DIR/../../.." && pwd)"
SERVER_ROOT="$(cd "$FLYWOW_ROOT/../.." && pwd)"
SKYNET_ROOT="$SERVER_ROOT/third_party/skynet"

# ${1:-} 在没有第一个参数时展开为空；只有第一个参数恰好是 prepare 才进入准备分支。
# 例如 run.sh prepare 调用 bootstrap；不带参数会继续使用默认 websocket/client 运行模式。
# $# 表示位置参数个数；此分支只接受一个参数。exec 用 bootstrap 替换当前 Shell，并沿用其退出状态。
if [[ "${1:-}" == "prepare" ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo "prepare 不接受其他参数；用法：bash run.sh prepare" >&2
        exit 2
    fi
    exec bash "$COURSE_DIR/bootstrap.sh"
fi

# Bash 把脚本名后面的参数按顺序编号：$1 是第一个参数（传输方式），$2 是第二个参数（启动方式）。
# ${1:-websocket} 的意思是：如果没有给第一个参数，或第一个参数是空字符串，就把 MODE 设为 websocket；否则使用第一个参数原值。
# 例如：run.sh tcp client 会令 MODE=tcp；只运行 run.sh 会令 MODE=websocket。
MODE="${1:-websocket}"

# ${2:-client} 同理：没有给第二个参数或它为空时，ACTION 取 client；否则取第二个参数原值。
# 例如：run.sh tcp server 会令 ACTION=server；run.sh websocket 或只运行 run.sh 都会令 ACTION=client。
ACTION="${2:-client}"

# 只接受本课程支持的两种传输和两种启动方式；错误时打印用法并以状态码 2 结束。
if [[ "$MODE" != websocket && "$MODE" != tcp ]]; then
    echo "第一个参数只能是 websocket 或 tcp" >&2
    echo "用法：bash run.sh [websocket|tcp] [client|server]" >&2
    exit 2
fi
if [[ "$ACTION" != server && "$ACTION" != client ]]; then
    echo "第二个参数只能是 client 或 server" >&2
    echo "用法：bash run.sh [websocket|tcp] [client|server]" >&2
    exit 2
fi

# -x 检查 Skynet 文件存在且可执行；-s 检查依赖文件存在且大小大于零。
# 缺少构建产物时提前退出，避免启动到一半才出现加载错误；首次使用请运行 `bash run.sh prepare`。
if [[ ! -x "$SKYNET_ROOT/skynet" ]]; then
    echo "请先构建固定 Skynet：$SKYNET_ROOT/skynet" >&2
    exit 1
fi
if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then
    echo "请先构建宿主 lua-protobuf：$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" >&2
    exit 1
fi
if [[ ! -s "$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" ]]; then
    echo "请先构建 Gateway Native：$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" >&2
    exit 1
fi

# 先用课程目录中的脚本生成 Descriptor 和 Registry；bash 显式调用它，不要求它有可执行权限。
bash "$COURSE_DIR/build_protocol.sh"

# export 让新启动的 Skynet Service 也能读取传输类型和端口环境变量。
# 若调用者已设置端口则沿用，否则使用课程默认端口 19221。
export GATEWAY_COURSE_TRANSPORT="$MODE"
# 端口环境变量未设置或为空时使用 19221；例如 GATEWAY_COURSE_PORT=19300 会让服务端和客户端都使用 19300。
export GATEWAY_COURSE_PORT="${GATEWAY_COURSE_PORT:-19221}"

# Skynet 配置中的相对路径以 Server 根目录为基准，所以启动前切换到该目录。
cd "$SERVER_ROOT"

# server 模式将当前 Bash 进程替换为 Skynet，并以前台方式运行。
# exec 后脚本不会继续执行，下面 client 模式的后台进程和 cleanup 逻辑都不会参与；按 Ctrl+C 可停止前台 Skynet。
if [[ "$ACTION" == server ]]; then
    exec "$SKYNET_ROOT/skynet" "$COURSE_DIR/skynet_config.lua"
fi

# client 模式把服务端日志写到 FlyWow build 目录，按传输方式分开保存。
# mkdir -p 会在目录不存在时创建它，目录已存在时不会报错。
LOG_DIR="$FLYWOW_ROOT/build/gateway-master-course/$MODE"
mkdir -p "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"

# client 模式需要同时运行服务端和客户端：Skynet 放在后台，Node 客户端稍后在前台运行。
# > 将服务端标准输出写入日志，2>&1 再把标准错误接到同一个日志；末尾的 & 让 Bash 不等待 Skynet 结束。
# $! 是刚刚启动的后台 Skynet 进程号，之后用它判断服务是否仍在运行并负责清理。
"$SKYNET_ROOT/skynet" "$COURSE_DIR/skynet_config.lua" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# cleanup 由当前 Bash Shell 调用，专门结束本脚本刚启动的 Skynet，不会按名称查找或关闭其他服务。
cleanup() {
    # kill -0 只探测进程是否存在，不发送信号；进程还活着时才发送 TERM 请求它退出。
    # 若进程已自行退出，跳过 kill，避免把正常完成报告成清理失败。
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
    fi

    # wait 回收这个后台子进程。这里忽略其退出状态，避免清理阶段覆盖脚本原本的失败原因。
    wait "$SERVER_PID" 2>/dev/null || true
}

# trap 把 cleanup 注册为当前 Bash 的 EXIT 钩子；Bash 正常结束或因 set -e 遇到未处理错误退出时都会调用它。
# 这不是 Skynet 或 Node 调用 cleanup；它们结束后只是让 Bash 继续或退出，最终由 Bash 执行钩子。
trap cleanup EXIT

# 等待服务在日志中报告就绪，最多 200 次，每次间隔 0.1 秒，合计约 20 秒。
# ready=0 表示目前还没找到就绪标记；找到后改为 1 并结束循环。
ready=0
for _ in $(seq 1 200); do
    if grep -q 'COURSE_GATEWAY_READY transport=' "$SERVER_LOG"; then
        ready=1
        break
    fi

    # 服务进程提前退出时打印完整日志，帮助定位启动错误，然后以失败状态结束。
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        cat "$SERVER_LOG" >&2
        exit 1
    fi

    sleep 0.1
done

# [[ ... ]] 在这里要求 ready 必须等于 1；否则报告启动超时并输出服务端日志。
if [[ "$ready" != 1 ]]; then
    cat "$SERVER_LOG" >&2
    echo "Gateway 就绪超时" >&2
    exit 1
fi

# 启动与传输模式对应的 Node 客户端。该命令没有 &，所以客户端在前台运行，Bash 会等它结束后才执行下面的代码。
# timeout 最多允许运行 20 秒；超时或客户端失败会产生非零退出状态，set -e 会结束脚本并触发上面的 EXIT 清理钩子。
# 端口作为客户端的第一个位置参数；客户端正常完成后进程退出，控制权回到当前 Bash。
if [[ "$MODE" == websocket ]]; then
    timeout 20s node "$COURSE_DIR/client/websocket_client.mjs" "$GATEWAY_COURSE_PORT"
else
    timeout 20s node "$COURSE_DIR/client/tcp_client.mjs" "$GATEWAY_COURSE_PORT"
fi

# 客户端完成后，WorldService 会在 disconnect 事件处理完后停止服务。
# 最多等 100 次、每次 0.1 秒；如果服务没有自行退出，则打印日志并报超时。
finished=0
for _ in $(seq 1 100); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        finished=1
        break
    fi
    sleep 0.1
done
if [[ "$finished" != 1 ]]; then
    cat "$SERVER_LOG" >&2
    echo "服务器退出超时" >&2
    exit 1
fi

# 服务端已从上面的进程检查中确认退出；wait 负责回收后台进程并取得其退出状态。
# Skynet 非零退出时，set -e 会让脚本失败并触发 cleanup；成功退出后继续核对课程完成标记。
wait "$SERVER_PID"
grep -q 'COURSE_GATEWAY_OK' "$SERVER_LOG"

# 输出完整服务端日志。此命令结束后 Bash 正常退出，仍会执行 EXIT 钩子；此时服务端已结束，cleanup 不会再发 TERM。
cat "$SERVER_LOG"
