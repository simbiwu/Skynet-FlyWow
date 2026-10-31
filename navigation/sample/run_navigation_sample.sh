#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/third_party/skynet-flywow/navigation/sample/run_navigation_sample.sh [按本文件头部说明填写参数]
# 从 Unity golden fixture 准备地图后，在真实 Skynet Lua State 运行 Native API。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   [[ 条件 ]]执行 Bash 条件判断；-x检查可执行文件，-s检查非空文件，-e检查存在的路径。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   export 把变量加入子进程环境；普通赋值默认只在当前 Shell 中可见。
#   set +e 暂时关闭命令失败即退出；代码读取失败状态后再用 set -e 恢复。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"

# $# 表示收到的位置参数个数；少于 1 个时没有 Skynet 根目录，打印用法并退出。例：脚本后传 /opt/skynet 时 $# 至少为 1。
if [[ "$#" -lt 1 ]]; then printf '%s\n' '用法: run_navigation_sample.sh SKYNET_ROOT' >&2; exit 1; fi
SKYNET_ROOT="$(realpath -- "$1")"

RUNTIME_ROOT="$FRAMEWORK_DIR/build/navigation-sample"
LOG="$RUNTIME_ROOT/sample.log"
FIXTURE_DIR="$FRAMEWORK_DIR/navigation/unity/Tests/Editor/Fixtures"
[[ -x "$SKYNET_ROOT/skynet" ]] || { printf '找不到 Skynet: %s\n' "$SKYNET_ROOT/skynet" >&2; exit 1; }

if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_navigation_native.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" navigation
fi

rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT"
# python3 - 从标准输入读取 here-document 中的代码；两个位置参数分别是 fixture 源文件和目标 map 文件。
python3 - "$FIXTURE_DIR/bmap_v1.txt" "$RUNTIME_ROOT/map.bmap" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[2]).write_bytes(bytes.fromhex(Path(sys.argv[1]).read_text(encoding="ascii")))
PY

export FLYWOW_NAVIGATION_SAMPLE_MAP="$RUNTIME_ROOT/map.bmap"
cd "$SERVER_ROOT"

# 暂时允许 timeout/Skynet 失败以便保存退出状态；随后 set -e 恢复严格模式。
set +e
timeout --signal=TERM 15s "$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua" 2>&1 | tee "$LOG"
# $? 读取紧邻上一条命令/管道的退出状态；此处用于决定是否接受成功标记。
status=$?
set -e

if [[ "$status" -ne 0 ]] || ! grep -q '^FLYWOW_NAVIGATION_SAMPLE_OK$' "$LOG"; then
    printf 'Navigation 示例失败，日志位于 %s\n' "$LOG" >&2
    exit 1
fi
