#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/third_party/skynet-flywow/lua-binding/sample/run_lua_binding_sample.sh [按本文件头部说明填写参数]
# 通过固定 Skynet Lua ABI 编译并运行一个真实 LuaBinding 回调。
# 参数为已构建的 Skynet 根目录；先执行统一 ABI 回归，产物写入 FlyWow build/lua-binding-sample。
# 编译、运行或断言失败立即退出，不启动 Server，也不链接 Native 专用的 Skynet allocator。
set -euo pipefail

# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   NAME:?错误说明展开：必需变量未设置或为空时显示说明并以非零状态失败。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   [[ 条件 ]]执行 Bash 条件判断；-f检查普通文件，-s检查非空文件。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# $1 必须提供 Skynet 根目录；缺失或为空时 ${1:?说明} 立即报错。例：传 /opt/skynet 后，realpath 解析并规范化路径。
SKYNET_ROOT="$(realpath -- "${1:?用法: run_lua_binding_sample.sh SKYNET_ROOT}")"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/lua-binding-sample"
LIBRARY="$FRAMEWORK_DIR/build/cmake/lua-binding/libflywow_lua_binding.a"
SKYNET_LUA="$SKYNET_ROOT/3rd/lua"

# 编译前核对宿主 Lua ABI 的头文件和静态库；缺任一项就停止，避免链接到系统 Lua。
[[ -f "$SKYNET_LUA/lua.h" && -s "$SKYNET_LUA/liblua.a" ]] || {
    printf '缺少 Skynet 自带 Lua 头文件或 liblua.a: %s\n' "$SKYNET_LUA" >&2
    exit 1
}
# 调用 FlyWow 唯一公开构建入口；Skynet 路径已经转换成绝对路径。
bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" lua_binding
mkdir -p "$RUNTIME_ROOT"

"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror \
# -I 给 C++ 编译器追加头文件搜索目录；后续每个 -I 分别对应模块和宿主 Lua 头文件。
    -I"$FRAMEWORK_DIR/lua-binding" -I"$SKYNET_LUA" \
    "$SCRIPT_DIR/lua_binding_sample.cpp" "$LIBRARY" "$SKYNET_LUA/liblua.a" \
    -ldl -lm -pthread -o "$RUNTIME_ROOT/lua_binding_sample"
"$RUNTIME_ROOT/lua_binding_sample"
