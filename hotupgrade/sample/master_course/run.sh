#!/usr/bin/env bash
# 让系统通过 PATH 查找 Bash 来解释本文件；这样调用者不必写死 Bash 的安装路径。
# 运行本课程的一个独立实验；每次都会从 host_v1 重建运行目录。
set -euo pipefail
# -e：普通命令失败时立即退出；后面执行 Skynet 的管道会临时关闭它，以便读取退出码。
# -u：使用未设置的变量时立即报错，避免路径或参数为空后继续操作。
# -o pipefail：管道中任一命令失败，整个管道都视为失败；Skynet 与 tee 的状态另用 PIPESTATUS 区分。

# COURSE_DIR 最终保存本 run.sh 所在的 master_course 目录的绝对路径，不是启动脚本时的当前目录。
# $0 是 Bash 收到的脚本路径；若它是相对路径，dirname 的结果会相对于调用脚本时的当前目录解释。
# 例：从 FlyWow 根目录运行 bash hotupgrade/sample/master_course/run.sh ...，
# $0 是相对路径，dirname 得到 hotupgrade/sample/master_course，pwd 最终输出该目录的绝对路径。
# 若从 /tmp 用 run.sh 的绝对路径调用，dirname 直接得到绝对目录，最终 COURSE_DIR 仍是同一个目录。
# dirname -- 取出目录部分；-- 表示选项结束，避免以 - 开头的路径被误当成选项。
# cd 和 pwd 在 $(...) 命令替换的子 Shell 中执行；这里的 cd 不会改变主脚本后续命令的当前目录。
# && 是“前一个命令成功才继续”：只有 cd 成功，pwd 才执行，避免 cd 失败后输出错误目录。
COURSE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

# master_course 位于 FlyWow/hotupgrade/sample/master_course；向上三级得到 FlyWow 根目录。
# cd 后执行 pwd，后续路径就不依赖从哪个目录调用 run.sh。
FRAMEWORK_DIR="$(cd -- "$COURSE_DIR/../../.." && pwd)"

# 第一个位置参数 $1 必须提供 Skynet 根目录，例如 ./run.sh /opt/skynet v1 中的 /opt/skynet。
# ${1:?...} 是 Bash 参数展开：$1 未设置或为空时，打印用法中的错误信息并让本行失败。
# 双引号确保路径（即使含空格）整体作为一个参数；-- 告诉 realpath 后续内容不是它的选项。
# realpath 将输入路径解析为绝对路径；若 $1 是相对路径，则相对于启动脚本时的当前目录解析。
# 外层 $(...) 捕获 realpath 输出，赋给 SKYNET_ROOT；之后脚本统一使用这个绝对路径。
SKYNET_ROOT="$(realpath -- "${1:?用法: run.sh SKYNET_ROOT [v1|normal|queue|forward]}")"

# 第二个位置参数 $2 指定要运行的课程场景。
# ${2:-v1} 表示 $2 未设置或为空时使用默认值 v1。
SCENARIO="${2:-v1}"

# 本课程专用的生成目录；脚本会删除并重建它，不会清理课程源码目录。
RUNTIME_ROOT="$FRAMEWORK_DIR/build/hotupgrade-master-course"

# Skynet 的标准输出和标准错误会同时显示在终端并保存到这个日志文件。
LOG_FILE="$RUNTIME_ROOT/course.log"

# case 按场景名分支；竖线表示多个可接受的匹配值，右括号结束模式。
# 空分支体中的 ;; 表示该模式到此结束；*) 匹配所有未列出的场景。
case "$SCENARIO" in
    v1|normal|queue|forward) ;;
    # >&2 把错误说明写到标准错误；exit 2 以参数错误状态结束脚本。
    *) echo "未知实验: $SCENARIO" >&2; exit 2 ;;
esac

# [[ ... ]] 是 Bash 条件表达式；-x 检查路径是否为可执行文件。
# 若检查失败，|| 执行花括号中的命令组：输出错误并以状态码 1 退出。
[[ -x "$SKYNET_ROOT/skynet" ]] || { echo "找不到 Skynet 可执行文件" >&2; exit 1; }

# -s 检查文件存在且大小大于零；! 取反，所以缺失或空文件时才进入构建分支。
# 这里仅判断 Native 动态库是否存在且非空，不会判断它是否与当前源码版本一致。
# bash <脚本> <参数...> 用 Bash 执行构建脚本；后两个参数分别是 Skynet 根目录和目标 hotupgrade。
if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_hotupgrade_native.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" hotupgrade
fi

# 只清理本课程专用的 build 目录；不会删除课程源码或其它工程文件。
# rm -r 递归删除目录，-f 表示目标不存在时不报错，-- 后面的内容都按路径处理。
# 变量加双引号，避免路径中的空格被拆成多个参数，也避免通配符展开。
rm -rf -- "$RUNTIME_ROOT"

# -p 表示父目录不存在时一并创建；这里同时准备正式宿主文件目录和 Patch 目录。
mkdir -p "$RUNTIME_ROOT/host" "$RUNTIME_ROOT/patches"

# 将 host_v1 目录中的全部内容复制到运行目录 host/ 下。
# 源路径末尾的 /. 表示复制目录内容（包括隐藏项），而不是额外套一层 host_v1。
# -a 递归复制并尽可能保留文件属性和符号链接。
cp -a "$COURSE_DIR/host_v1/." "$RUNTIME_ROOT/host/"

# 如果课程 patches 目录存在，才复制其中的全部内容；-d 检查目录是否存在。
# 这样 V1 阶段尚未创建 patches 时也能运行脚本。
if [[ -d "$COURSE_DIR/patches" ]]; then
    cp -a "$COURSE_DIR/patches/." "$RUNTIME_ROOT/patches/"
fi

# export 将变量放入进程环境，使随后启动的 Skynet 和它创建的 Service 都能读取。
# Skynet 配置从这些绝对路径构造 Lua、Service 和 Native 模块搜索路径。
export FLYWOW_MASTER_SKYNET_ROOT="$SKYNET_ROOT"
export FLYWOW_MASTER_FRAMEWORK_ROOT="$FRAMEWORK_DIR"
export FLYWOW_MASTER_COURSE_ROOT="$COURSE_DIR"
export FLYWOW_MASTER_RUNTIME_ROOT="$RUNTIME_ROOT"

# 同样把本次选择的场景名传给 Skynet 子进程；脚本最后也用它检查对应的成功标记。
export FLYWOW_MASTER_SCENARIO="$SCENARIO"

# 配置中的 Lua、Native 和 Service 搜索路径由 skynet_config.lua 基于上面的绝对路径构造。
# 切到 Skynet 根目录后再启动；Skynet 运行时可能使用相对路径，因此工作目录仍有意义。
cd "$SKYNET_ROOT"

# 暂时关闭 -e：即使管道返回非零，也先读取 PIPESTATUS；脚本随后统一检查 Skynet 状态和成功标记。
set +e

# timeout 计时 90 秒；到时发送 TERM 信号请求 Skynet 退出，不在这里额外发送强制终止信号。
# 后两个参数依次是 Skynet 可执行文件和本课程配置文件的绝对路径。
# 2>&1 把标准错误合并到标准输出，再通过管道交给 tee；tee 同时打印输出并写入日志。
timeout --signal=TERM 90s "$SKYNET_ROOT/skynet" "$COURSE_DIR/skynet_config.lua" 2>&1 | tee "$LOG_FILE"

# PIPESTATUS 是 Bash 的特殊数组，记录上一条管道中每个命令各自的退出码。
# [0] 是第一个命令 timeout 的退出码；正常结束时它转交 Skynet 的退出码，超时则返回 timeout 的状态码。
# 必须紧接管道读取，因为执行其它命令后 PIPESTATUS 会被更新。
result=${PIPESTATUS[0]}

# 恢复 -e；后续非条件位置上的命令失败时，脚本会按严格模式退出。
set -e

# ${SCENARIO^^} 是 Bash 的大写转换展开，例如 normal 变成 NORMAL。
# 教学 main.lua 应在成功完成所选场景后打印对应的 MASTER_<场景>_OK 标记。
expected="MASTER_${SCENARIO^^}_OK"

# -ne 做整数不等比较；grep -q 静默查找，-x 要求整行完全匹配成功标记。
# 只要 Skynet 退出码非零，或日志里没有预期标记，就进入失败分支。
if [[ "$result" -ne 0 ]] || ! grep -qx "$expected" "$LOG_FILE"; then
    # 把失败摘要写到标准错误，并指出完整运行日志的位置。
    echo "实验失败：$SCENARIO，检查 $LOG_FILE" >&2
    # 统一以 1 表示课程实验验收失败。
    exit 1
fi
