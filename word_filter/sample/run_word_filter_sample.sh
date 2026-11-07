#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/third_party/skynet-flywow/word_filter/sample/run_word_filter_sample.sh /absolute/path/to/skynet
# 在真实 Skynet Lua State 中运行 WordFilter 的公开 Lua/Native API。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   $#表示参数个数，$1 表示传入的第一个参数。
#   [[ 条件 ]]执行 Bash 条件判断；-x 检查路径是否可执行。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   set +e 暂时关闭命令失败即退出；代码读取失败状态后再用 set -e 恢复。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# $# 表示收到的位置参数个数；少于 1 个时没有 Skynet 根目录，打印用法并退出。例：脚本后传 /opt/skynet 时 $# 至少为 1。
if [[ "$#" -lt 1 ]]; then printf '%s\n' '用法: run_word_filter_sample.sh SKYNET_ROOT' >&2; exit 1; fi
SKYNET_ROOT="$(realpath -- "$1")"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/word-filter-sample"
LOG="$RUNTIME_ROOT/sample.log"
[[ -x "$SKYNET_ROOT/skynet" ]] || { printf '找不到 Skynet: %s\n' "$SKYNET_ROOT/skynet" >&2; exit 1; }
# 增量构建会按传入的 Skynet 头文件重新配置，避免复用为其它 Skynet 构建的动态库。
bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" word_filter
mkdir -p "$RUNTIME_ROOT"
cd "$FRAMEWORK_DIR"
# export 让 Skynet 的配置加载器也能读取路径；两者分别定位运行依赖和本次 Native 产物。
export FLYWOW_WORD_FILTER_SKYNET_ROOT="$SKYNET_ROOT"
export FLYWOW_WORD_FILTER_NATIVE_DIR="$FRAMEWORK_DIR/build/native"
# 暂时不因管道失败立即退出，让下一行保存 Skynet/timeout 状态后再统一验收。
set +e
# timeout 在 15 秒后向 Skynet 发 TERM；tee 同时把输出打印到终端并覆盖旧日志。
timeout --signal=TERM 15s "$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" 2>&1 | tee "$LOG"
# $? 是上一条 timeout | tee 管道状态；启用 pipefail 时任一端失败都能反映出来。
status=$?
set -e
if [[ "$status" -ne 0 ]] || ! grep -q '^FLYWOW_WORD_FILTER_SAMPLE_OK$' "$LOG"; then
    printf 'WordFilter 示例失败，日志位于 %s\n' "$LOG" >&2
    exit 1
fi
