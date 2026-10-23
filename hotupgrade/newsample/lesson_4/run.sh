#!/usr/bin/env bash
# 使用当前环境中可找到的 Bash 执行本脚本。
set -euo pipefail
# -e：未被条件语句接管的命令失败时立即退出，避免继续使用不完整的运行目录。
# -u：读取未定义变量时立即报错，例如遗漏必需的 Skynet 根目录参数。
# -o pipefail：若以后使用管道，任一环节失败都会让整个管道失败。

# $0 是启动脚本时使用的名称或路径，不保证本身就是绝对路径。
# dirname 取出其中的目录部分；若它是相对路径，就以调用者当前目录为基准。
# cd 进入该目录后，pwd 将脚本目录解析为绝对路径，因此后续定位不依赖调用位置。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

# lesson_4 位于 FlyWow/hotupgrade/newsample/lesson_4；向上三级得到 FlyWow 根目录。
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

# FlyWow 位于 server/third_party/skynet-flywow；向上两级得到宿主 server 根目录。
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"

# 必须提供第一个位置参数：Skynet 根目录（其中应有 skynet 可执行文件）。
# ${1:?...} 在参数缺失时输出提示并终止；realpath 将参数解析为绝对路径。
# 参数中的相对路径按运行本脚本时的当前目录解析，而不是按脚本所在目录解析。
SKYNET_ROOT="$(realpath -- "${1:?请传入 Skynet 根目录}")"

# 示例本次生成的宿主文件和 Patch 的运行目录；配置文件也使用这个目录。
RUNTIME_ROOT="$FRAMEWORK_DIR/build/hotupgrade-newsample/lesson_4"

# 删除本示例上次生成的整个运行目录，再重新准备干净目录。
# 注意：该目录中的现有内容都会被永久删除；不要在其中保存需要保留的文件。
rm -rf -- "$RUNTIME_ROOT"

# -p 表示父目录不存在时一并创建；同时创建宿主文件目录和 Patch 目录。
mkdir -p "$RUNTIME_ROOT/host" "$RUNTIME_ROOT/patches"

# 将 host_v1 目录中的全部内容复制到运行目录的 host/ 下。
# 源路径末尾的 /. 表示复制目录内容（包括隐藏项），而不是额外套一层 host_v1。
# -a 递归复制并尽可能保留文件属性和符号链接。
cp -a "$SCRIPT_DIR/host_v1/." "$RUNTIME_ROOT/host/"

# 同样把 newsample/patches 中的 Patch 文件复制到本次运行目录。
cp -a "$SCRIPT_DIR/patches/." "$RUNTIME_ROOT/patches/"

# 让当前 Shell 及其启动的 Skynet 子进程都能读取示例运行根目录。
# newsample/main.lua 使用此变量构造 HotUpgrade 的 patch_path 和 root_path。
export HOTUPGRADE_LESSON_ROOT="$RUNTIME_ROOT"

# 配置文件中的 ./third_party/... 都是相对路径，预期从宿主 server 根目录解析。
# 因此先切换工作目录；这与 Skynet 可执行文件本身位于哪里是两回事。
cd "$SERVER_ROOT"

# 从指定的 Skynet 根目录运行 Skynet，并传入本脚本目录下的配置文件。
# 配置文件使用绝对路径；而配置内部的相对路径仍以当前工作目录 SERVER_ROOT 为基准。
"$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua"
