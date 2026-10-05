#!/usr/bin/env bash
# 职责：独立配置、编译并验证 Navigation；不推断宿主工程位置。
# 边界：Build/Test；输入为固定 Skynet 根和构建目录，输出归调用方拥有。
# 生命周期：短命构建进程；失败立即停止，不启动 Server、不下载依赖。
set -euo pipefail
MODULE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SKYNET_ROOT="${1:?用法: build.sh SKYNET_ROOT BUILD_DIR}"
BUILD_DIR="${2:?缺少 BUILD_DIR}"
# 宿主可以显式覆盖；默认 Debug 保留 Native 测试的 assert 检查。
BUILD_TYPE="${BUILD_TYPE:-Debug}"
case "$BUILD_TYPE" in
    Debug|Release|RelWithDebInfo|MinSizeRel) ;;
    *) printf '%s\n' "不支持的 BUILD_TYPE: $BUILD_TYPE" >&2; exit 1 ;;
esac
cmake -S "$MODULE_ROOT/native" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DFLYWOW_NAVIGATION_LUA=ON \
    -DSKYNET_ROOT="$SKYNET_ROOT"
cmake --build "$BUILD_DIR" -j"$(nproc)"
ctest --test-dir "$BUILD_DIR" --output-on-failure
