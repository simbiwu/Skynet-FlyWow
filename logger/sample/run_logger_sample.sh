#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/third_party/skynet-flywow/logger/sample/run_logger_sample.sh [按本文件头部说明填写参数]
# 日志和临时启动产物均限定在本示例 build 目录。
set -euo pipefail

# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:?错误说明展开：必需变量未设置或为空时显示说明并以非零状态失败。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   [[ 条件 ]]执行 Bash 条件判断；-x检查可执行文件，-s检查非空文件，-e检查存在的路径。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   PIPESTATUS 按顺序保存上一条管道中各命令的退出码；必须紧接管道读取。
#   set +e 暂时关闭命令失败即退出；代码读取失败状态后再用 set -e 恢复。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"
# $1 必须提供 Skynet 根目录；缺失或为空时 ${1:?说明} 立即报错。例：传 /opt/skynet 后，realpath 解析并规范化路径。
SKYNET_ROOT="$(realpath -- "${1:?用法: run_logger_sample.sh SKYNET_ROOT}")"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/logger-sample"
LOG="$RUNTIME_ROOT/sample.log"

# 运行前确认调用者给出的 Skynet 可执行文件存在；条件不成立时错误分支会退出。
[[ -x "$SKYNET_ROOT/skynet" ]] || {
    printf '找不到 Skynet 可执行文件: %s\n' "$SKYNET_ROOT/skynet" >&2
    exit 1
}
if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_logger.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" logger
fi

# 重建本 sample 专属运行目录，避免上次运行日志使这次检查误通过。
rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT/logs"
cd "$SERVER_ROOT"

# 让下一条管道即使失败也能返回状态值；保存后用 set -e 恢复立即失败行为。
set +e
timeout --signal=TERM 30s "$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" 2>&1 | tee "$LOG"
# PIPESTATUS[0] 保存刚结束管道中第一个命令的退出码；必须紧接管道读取。
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
