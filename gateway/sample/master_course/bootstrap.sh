#!/usr/bin/env bash
# 用途：准备 Master Course Gateway Sample 的固定运行依赖。
# 工作目录：可从任意目录启动；脚本按自身位置定位 FlyWow、Server 和课程目录。
# 调用：bash /absolute/path/to/skynet-flywow/gateway/sample/master_course/bootstrap.sh
# 输入：Server 的版本清单、Skynet/Lua protobuf 固定源码版本及 FlyWow Gateway Native 源码。
# 输出：Skynet 可执行文件、protoc、lua-protobuf pb.so 和 Gateway Crypto Native 运行产物。
# 过程：只在对应产物缺失时编译；固定源码准备脚本负责版本核对，版本冲突时明确失败。
# 不负责：不安装系统软件、不启动 Gateway、不修改 Skynet 或其他第三方源码。
# Bash 语法：$0 是当前脚本路径；dirname 取脚本目录；命令替换 $(...) 把 pwd 输出作为路径文本。
# Bash 语法：[[ -x 文件 ]] 判断文件可执行，[[ -s 文件 ]] 判断文件存在且非空；! 表示条件取反。
# Bash 语法：&& 要求左边成功后再执行右边；|| 在左边失败时执行右边；set -euo pipefail 让未处理的失败尽早终止。
set -euo pipefail

# 由脚本所在位置推导各仓库根目录，因此从其他目录调用也使用同一套依赖路径。
COURSE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FLYWOW_ROOT="$(cd -- "$COURSE_DIR/../../.." && pwd)"
SERVER_ROOT="$(cd -- "$FLYWOW_ROOT/../.." && pwd)"
SKYNET_ROOT="$SERVER_ROOT/third_party/skynet"

# for 会把列表中的工具名逐个放进 tool；例如第一轮 tool=curl、下一轮 tool=python3。
# command -v 在 PATH 中查找该命令；重定向丢弃探测输出，只保留成功或失败状态。
# 检查本课程后续会直接使用的构建和运行命令。
for tool in bash curl python3 tar cmake make cc c++ node timeout; do
    # if ! 表示“命令找不到”；这时打印当前缺少的工具并以失败状态退出。
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '缺少必需工具：%s\n' "$tool" >&2
        exit 1
    fi
done

# 固定版本 Bootstrap 会验证已准备的源码；若源码不存在，则下载锁定版本快照。
bash "$SERVER_ROOT/scripts/linux/bootstrap_skynet.sh"
bash "$SERVER_ROOT/scripts/linux/bootstrap_protocol_tools.sh"

# Skynet 的 bundled Lua ABI 是 pb.so 的编译依据；仅在可执行文件缺失时构建 Skynet。
if [[ ! -x "$SKYNET_ROOT/skynet" || ! -s "$SKYNET_ROOT/3rd/lua/lua.h" ]]; then
    bash "$SERVER_ROOT/scripts/linux/build_skynet.sh"
fi

# lua-protobuf 需要匹配刚检查的 Skynet Lua 头文件；只在运行库缺失时编译。
if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then
    bash "$SERVER_ROOT/scripts/linux/build_lua_protobuf.sh"
fi

# Gateway Crypto 由 FlyWow 已有统一构建脚本生成；限定 gateway 模块避免构建无关 Native。
if [[ ! -s "$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" ]]; then
    bash "$FLYWOW_ROOT/scripts/build_flywow.sh" "$SKYNET_ROOT" gateway
fi

# 再检查所有本课程运行时会加载的产物；失败时指出应当存在的具体文件。
if [[ ! -x "$SKYNET_ROOT/skynet" || ! -s "$SKYNET_ROOT/3rd/lua/lua.h" ]]; then
    printf 'Skynet 构建后仍不可执行：%s/skynet\n' "$SKYNET_ROOT" >&2
    exit 1
fi
if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then
    printf 'lua-protobuf 构建产物缺失：%s\n' "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" >&2
    exit 1
fi
if [[ ! -s "$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" ]]; then
    printf 'Gateway Crypto 构建产物缺失：%s\n' "$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" >&2
    exit 1
fi

printf 'GATEWAY_MASTER_COURSE_PREPARE_OK\n'
