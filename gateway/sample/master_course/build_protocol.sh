#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；所有内部路径从脚本位置推导。
# 示例：bash /absolute/path/to/checkout/server/third_party/skynet-flywow/gateway/sample/master_course/build_protocol.sh
# 职责：使用宿主锁定版本的 protoc 生成本课程 descriptor 和 Gateway Registry。
# 输入：仓库 shared/protocol/VERSIONS.env、随脚本提供的 proto 文件及固定版本 protoc。
# 输出：本脚本目录下 generated/world.pb 与 generated/world_registry.lua。
# Bash 语法说明：双引号保护路径中的空格；命令替换把命令输出作为字符串使用；&& 表示前一命令成功后才执行下一条。
# 双中括号执行 Bash 条件判断；-x 检查可执行文件，-s 检查非空文件；|| 在左侧失败时执行右侧错误处理。
# 大括号把多条错误处理命令组成一组；反斜杠续行让一个 protoc 命令跨多行书写。
set -euo pipefail

# 从脚本文件位置计算本课程目录；不要用调用者当前目录拼接项目路径。
COURSE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FLYWOW_ROOT="$(cd "$COURSE_DIR/../../.." && pwd)"
SERVER_ROOT="$(cd "$FLYWOW_ROOT/../.." && pwd)"
HOST_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"

# 使用宿主唯一版本清单；绝不调用系统中不明版本的 protoc。
# source 在当前 Bash 进程中读取版本变量，后续命令直接使用 PROTOC_VERSION。
source "$HOST_ROOT/shared/protocol/VERSIONS.env"
PROTOC="$SERVER_ROOT/third_party/protoc-$PROTOC_VERSION/bin/protoc"
[[ -x "$PROTOC" ]] || { echo "缺少固定 protoc：$PROTOC" >&2; exit 1; }
[[ "$($PROTOC --version)" == "libprotoc $PROTOC_VERSION" ]] || {
    echo "protoc 版本不匹配" >&2; exit 1;
}

# mkdir -p 在目录不存在时创建它；目录已存在时也不会报错。
mkdir -p "$COURSE_DIR/generated"
"$PROTOC" \
    -I "$COURSE_DIR/proto" \
    --include_imports \
    --descriptor_set_out="$COURSE_DIR/generated/world.pb" \
    "$COURSE_DIR/proto/wire_header.proto" \
    "$COURSE_DIR/proto/world.proto"

# 这里是第二步：调用 FlyWow Python 生成器创建 Lua Gateway Registry；它与上面的 protoc 分别运行。
# --proto 只传课程业务定义 world.proto。生成器从 package flywow.gateway.course 读取命名空间，
# 并自动把它加到 EnterWorldRequest、EnterWorldResponse 等消息的完整类型名上，因此无需另传 package。
# Envelope 不在 world.proto 中，而由宿主 shared/protocol/wire_header.proto 定义为 .battle.transport.v1.Envelope。
# 上面的 protoc 把两份 proto 都写入 descriptor；但 Registry 生成器只读取 --proto 指定的业务文件。
# 如果省略 --envelope-type，生成器会默认使用业务 package 下的 .flywow.gateway.course.Envelope，这里并没有该消息。
# 所以显式覆盖成共享 Envelope 的完整 Protobuf 类型名；生成器会把它写入 Registry 的 envelope_type 字段。
# 工具、输入和输出路径都由脚本推导为绝对路径，因此从其他工作目录启动也能定位正确。
python3 "$FLYWOW_ROOT/gateway/tools/generate_gateway_registry.py" \
    --proto "$COURSE_DIR/proto/world.proto" \
    --envelope-type ".battle.transport.v1.Envelope" \
    --output "$COURSE_DIR/generated/world_registry.lua"

test -s "$COURSE_DIR/generated/world.pb"
test -s "$COURSE_DIR/generated/world_registry.lua"
echo "COURSE_PROTOCOL_OK"