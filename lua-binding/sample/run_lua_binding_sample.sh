#!/usr/bin/env bash
# 通过固定 Skynet Lua ABI 编译并运行一个真实 LuaBinding 回调。
# 参数为已构建的 Skynet 根目录；先执行统一 ABI 回归，产物写入 FlyWow build/lua-binding-sample。
# 编译、运行或断言失败立即退出，不启动 Server，也不链接 Native 专用的 Skynet allocator。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?用法: run_lua_binding_sample.sh SKYNET_ROOT}")"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/lua-binding-sample"
LIBRARY="$FRAMEWORK_DIR/build/cmake/lua-binding/libflywow_lua_binding.a"
SKYNET_LUA="$SKYNET_ROOT/3rd/lua"

[[ -f "$SKYNET_LUA/lua.h" && -s "$SKYNET_LUA/liblua.a" ]] || {
    printf '缺少 Skynet 自带 Lua 头文件或 liblua.a: %s\n' "$SKYNET_LUA" >&2
    exit 1
}
bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" lua_binding
mkdir -p "$RUNTIME_ROOT"

"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror \
    -I"$FRAMEWORK_DIR/lua-binding" -I"$SKYNET_LUA" \
    "$SCRIPT_DIR/lua_binding_sample.cpp" "$LIBRARY" "$SKYNET_LUA/liblua.a" \
    -ldl -lm -pthread -o "$RUNTIME_ROOT/lua_binding_sample"
"$RUNTIME_ROOT/lua_binding_sample"
