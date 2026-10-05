#!/usr/bin/env bash
# 职责：FlyWow 唯一公开 Native 构建入口，构建 Gateway Crypto、Navigation 和 Logger。
# 边界：仅编译/测试 FlyWow Native 模块；不启动 Server、不生成运行时路径配置、不安装依赖。
# 调用者：宿主 run_server.sh build，或 FlyWow 开发者；源码、Skynet ABI 或依赖变化后运行。
# 参数：$1=Skynet 根目录（包含 3rd/lua 和 skynet-src）；BUILD_TYPE 可选，默认 RelWithDebInfo。
# 输入：本仓库三个模块的源码、固定 Skynet 头文件及 OpenSSL 3 libcrypto。
# 产物：build/native/*.so；CMake 中间文件位于 build/cmake/<module>/；失败以非零退出。
# 示例：bash scripts/build_flywow.sh /path/to/server/third_party/skynet
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?用法: build_flywow.sh SKYNET_ROOT}")"
BUILD_ROOT="$FRAMEWORK_DIR/build"
NATIVE_DIR="$BUILD_ROOT/native"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"

case "$BUILD_TYPE" in
    Debug|Release|RelWithDebInfo|MinSizeRel) ;;
    *) printf '不支持的 BUILD_TYPE: %s\n' "$BUILD_TYPE" >&2; exit 1 ;;
esac
[[ -f "$SKYNET_ROOT/3rd/lua/lua.h" && -f "$SKYNET_ROOT/skynet-src/skynet.h" ]] || {
    printf '%s\n' 'Skynet 根目录缺少 Lua/Skynet 头文件' >&2
    exit 1
}
[[ "$(pkg-config --modversion libcrypto)" == 3.* ]] || {
    printf '%s\n' 'Gateway Crypto 要求 OpenSSL 3 libcrypto 开发文件' >&2
    exit 1
}
mkdir -p "$NATIVE_DIR"

# Gateway Crypto 是小型 Lua C 模块，先写临时文件再替换，避免失败留下伪产物。
read -r -a CRYPTO_FLAGS <<< "$(pkg-config --cflags --libs libcrypto)"
TEMP_OUTPUT="$(mktemp "$NATIVE_DIR/.gateway_crypto.XXXXXX")"
trap 'rm -f -- "$TEMP_OUTPUT"' EXIT
"${CXX:-c++}" -std=c++14 -O2 -Wall -Wextra -Werror -fPIC -shared \
    -I"$SKYNET_ROOT/3rd/lua" \
    "$FRAMEWORK_DIR/gateway/native/gateway_crypto/gateway_crypto.cpp" \
    "${CRYPTO_FLAGS[@]}" -o "$TEMP_OUTPUT"
chmod 755 "$TEMP_OUTPUT"
mv -f "$TEMP_OUTPUT" "$NATIVE_DIR/flywow_gateway_crypto.so"
trap - EXIT

# 两个 CMake 模块共享最终 Native 目录，各自保留独立缓存与测试边界。
cmake -S "$FRAMEWORK_DIR/navigation/native" -B "$BUILD_ROOT/cmake/navigation" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DFLYWOW_NAVIGATION_LUA=ON \
    -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR" -DSKYNET_ROOT="$SKYNET_ROOT"
cmake --build "$BUILD_ROOT/cmake/navigation" -j"$(nproc)"
ctest --test-dir "$BUILD_ROOT/cmake/navigation" --output-on-failure
test -s "$NATIVE_DIR/flywow_navigation_native.so"

cmake -S "$FRAMEWORK_DIR/logger/native" -B "$BUILD_ROOT/cmake/logger" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DSKYNET_ROOT="$SKYNET_ROOT" \
    -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR"
cmake --build "$BUILD_ROOT/cmake/logger" -j"$(nproc)"
ctest --test-dir "$BUILD_ROOT/cmake/logger" --output-on-failure
test -s "$NATIVE_DIR/flywow_logger.so"

printf 'FLYWOW_BUILD_OK native_dir=%s build_type=%s\n' "$NATIVE_DIR" "$BUILD_TYPE"
