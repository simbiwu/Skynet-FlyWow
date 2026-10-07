#!/usr/bin/env bash
# 职责：按选择构建 FlyWow Native 模块与 Lua Binding 静态库，并执行对应测试。
# 边界：只编译和测试指定模块；不启动 Server、不安装依赖、不生成运行时配置。
# 调用者：宿主构建脚本或 FlyWow 开发者。
# 参数：$1=Skynet 根目录；$2=gateway/navigation/logger/word_filter/hotupgrade/lua_binding/all，省略时为 all。
# 环境变量：BUILD_TYPE 可选，默认 RelWithDebInfo；CXX 可选，仅用于 Gateway 编译。
# 输入：指定模块源码、Skynet 头文件及该模块需要的系统开发库。
# 产物：build/native/*.so；CMake 中间文件位于 build/cmake/<module>/。
# 失败行为：参数、依赖、编译或测试失败时返回非零状态，不宣称产物可用。
# 示例：bash scripts/build_flywow.sh /path/to/skynet word_filter
# 示例：bash scripts/build_flywow.sh /path/to/skynet logger
# 示例：bash scripts/build_flywow.sh /path/to/skynet all
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?用法: build_flywow.sh SKYNET_ROOT [gateway|navigation|logger|word_filter|hotupgrade|lua_binding|all]}")"
MODULE="${2:-all}"
BUILD_ROOT="$FRAMEWORK_DIR/build"
NATIVE_DIR="$BUILD_ROOT/native"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"

case "$MODULE" in
    gateway|navigation|logger|word_filter|hotupgrade|lua_binding|all) ;;
    *)
        printf '不支持的模块: %s（可选 gateway、navigation、logger、word_filter、hotupgrade、lua_binding、all）\n' "$MODULE" >&2
        exit 1
        ;;
esac

case "$BUILD_TYPE" in
    Debug|Release|RelWithDebInfo|MinSizeRel) ;;
    *)
        printf '不支持的 BUILD_TYPE: %s\n' "$BUILD_TYPE" >&2
        exit 1
        ;;
esac

if [[ "$MODULE" == gateway || "$MODULE" == all ]]; then
    [[ -f "$SKYNET_ROOT/3rd/lua/lua.h" ]] || {
        printf '%s\n' 'Gateway 需要 Skynet 自带的 Lua 头文件' >&2
        exit 1
    }
    [[ "$(pkg-config --modversion libcrypto)" == 3.* ]] || {
        printf '%s\n' 'Gateway Crypto 要求 OpenSSL 3 libcrypto 开发文件' >&2
        exit 1
    }
fi

if [[ "$MODULE" == navigation || "$MODULE" == all ]]; then
    [[ -f "$SKYNET_ROOT/3rd/lua/lua.h" ]] || {
        printf '%s\n' 'Navigation Lua Binding 需要 Skynet 自带的 Lua 头文件' >&2
        exit 1
    }
fi

if [[ "$MODULE" == logger || "$MODULE" == all ]]; then
    [[ -f "$SKYNET_ROOT/skynet-src/skynet.h" ]] || {
        printf '%s\n' 'Logger 需要 Skynet 头文件' >&2
        exit 1
    }
fi

mkdir -p "$NATIVE_DIR"

if [[ "$MODULE" == lua_binding || "$MODULE" == navigation || "$MODULE" == all ]]; then
    # 使用已经构建的宿主 Lua 静态库运行真实 ABI 测试；静态封装不生成独立 .so。
    [[ -f "$SKYNET_ROOT/3rd/lua/liblua.a" ]] || {
        printf '%s\n' 'Lua Binding 测试需要先构建宿主 Skynet 的 liblua.a' >&2
        exit 1
    }
    cmake -S "$FRAMEWORK_DIR/lua-binding" -B "$BUILD_ROOT/cmake/lua-binding" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DFLYWOW_LUA_BINDING_TESTS=ON \
        -DSKYNET_LUA_DIR="$SKYNET_ROOT/3rd/lua" \
        -DSKYNET_LUA_LIBRARY="$SKYNET_ROOT/3rd/lua/liblua.a"
    cmake --build "$BUILD_ROOT/cmake/lua-binding" -j"$(nproc)"
    ctest --test-dir "$BUILD_ROOT/cmake/lua-binding" --output-on-failure
fi

if [[ "$MODULE" == gateway || "$MODULE" == all ]]; then
    # Gateway Crypto 直接生成临时文件，成功后再替换正式产物。
    read -r -a CRYPTO_FLAGS <<< "$(pkg-config --cflags --libs libcrypto)"
    TEMP_OUTPUT="$(mktemp "$NATIVE_DIR/.gateway_crypto.XXXXXX")"
    trap 'rm -f -- "$TEMP_OUTPUT"' EXIT
    "${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -fPIC -shared \
        -I"$SKYNET_ROOT/3rd/lua" \
        -I"$FRAMEWORK_DIR/lua-binding" \
        "$FRAMEWORK_DIR/gateway/native/gateway_crypto/gateway_crypto.cpp" \
        "$FRAMEWORK_DIR/lua-binding/lua_binding.cpp" \
        "$FRAMEWORK_DIR/lua-binding/lua_table.cpp" \
        "${CRYPTO_FLAGS[@]}" -o "$TEMP_OUTPUT"
    chmod 755 "$TEMP_OUTPUT"
    mv -f "$TEMP_OUTPUT" "$NATIVE_DIR/flywow_gateway_crypto.so"
    trap - EXIT
fi

if [[ "$MODULE" == navigation || "$MODULE" == all ]]; then
    cmake -S "$FRAMEWORK_DIR/navigation/native" -B "$BUILD_ROOT/cmake/navigation" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DFLYWOW_NAVIGATION_LUA=ON \
        -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR" -DSKYNET_ROOT="$SKYNET_ROOT"
    cmake --build "$BUILD_ROOT/cmake/navigation" -j"$(nproc)"
    ctest --test-dir "$BUILD_ROOT/cmake/navigation" --output-on-failure
    test -s "$NATIVE_DIR/flywow_navigation_native.so"
fi

if [[ "$MODULE" == logger || "$MODULE" == all ]]; then
    cmake -S "$FRAMEWORK_DIR/logger/native" -B "$BUILD_ROOT/cmake/logger" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DSKYNET_ROOT="$SKYNET_ROOT" \
        -DSKYNET_LUA_DIR="$SKYNET_ROOT/3rd/lua" \
        -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR"
    cmake --build "$BUILD_ROOT/cmake/logger" -j"$(nproc)"
    ctest --test-dir "$BUILD_ROOT/cmake/logger" --output-on-failure
    test -s "$NATIVE_DIR/flywow_logger.so"
fi

if [[ "$MODULE" == word_filter || "$MODULE" == all ]]; then
    # 独立缓存保存本模块中间文件，最终 .so 仍进入共用 native 目录。
    # CTest 验证核心及已有 Lua/Skynet 运行器；模块缺失运行器时不宣称集成已验证。
    cmake -S "$FRAMEWORK_DIR/word_filter/native" -B "$BUILD_ROOT/cmake/word_filter" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DSKYNET_ROOT="$SKYNET_ROOT" \
        -DSKYNET_LUA_DIR="$SKYNET_ROOT/3rd/lua" \
        -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR"
    cmake --build "$BUILD_ROOT/cmake/word_filter" -j"$(nproc)"
    ctest --test-dir "$BUILD_ROOT/cmake/word_filter" --output-on-failure
    test -s "$NATIVE_DIR/flywow_word_filter_native.so"
fi

if [[ "$MODULE" == hotupgrade || "$MODULE" == all ]]; then
    # 仅构建 Native；真实 Service 测试由模块测试入口显式启动。
    cmake -S "$FRAMEWORK_DIR/hotupgrade/native" -B "$BUILD_ROOT/cmake/hotupgrade" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DSKYNET_ROOT="$SKYNET_ROOT" \
        -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR"
    cmake --build "$BUILD_ROOT/cmake/hotupgrade" -j"$(nproc)"
    test -s "$NATIVE_DIR/flywow_hotupgrade_native.so"
fi

printf 'FLYWOW_BUILD_OK module=%s native_dir=%s build_type=%s\n' "$MODULE" "$NATIVE_DIR" "$BUILD_TYPE"
