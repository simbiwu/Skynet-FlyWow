#!/usr/bin/env bash
# 职责：按模块构建 FlyWow Native，并运行该模块配置的 CTest。
# 边界：负责构建编排与产物汇总；不启动业务 Server、不安装依赖、不生成运行时配置。
# 推荐完整构建：从 Server 根目录运行 ./scripts/linux/run_server.sh build。
# 单独构建模块：从 Server 根目录运行 bash third_party/skynet-flywow/scripts/build_flywow.sh third_party/skynet <模块>。
# 也可从 FlyWow 根目录运行 bash scripts/build_flywow.sh <Skynet目录> <模块>。
# 参数：第 1 个位置参数是 Skynet 根目录；第 2 个是模块名，省略时构建 all。
# 可选模块：gateway、navigation、logger、word_filter、hotupgrade、lua_binding、all。
# 环境变量：BUILD_TYPE 选择 CMake 构建类型，默认 RelWithDebInfo；CXX 在 Gateway 首次配置时选择编译器。
# 注意：CMake 缓存会保存首次选择的 CXX；更换编译器时为 Gateway 使用新的构建目录。
# 提醒：本文件中的 $NAME 是 Bash 展开；传给 CMake 的 -DNAME=VALUE 才会设置 CMake 变量。
# 输入：指定模块源码、Skynet 自带 Lua/Skynet 头文件及模块所需系统开发库。
# 输出：最终 .so 统一写入 build/native/；CMake 缓存和中间文件写入 build/cmake/<模块>/。
# 失败行为：参数、依赖、配置、编译或测试失败时立即返回非零状态。
# 修改指引：新增模块时同步更新用法、模块名校验、依赖检查和对应构建分支。
# 修改指引：新增 C++ 源文件时更新对应模块 CMakeLists.txt；Gateway 源文件清单位于 gateway/native/CMakeLists.txt。
# 修改指引：调整最终产物目录时改 NATIVE_DIR，并确认各模块的 FLYWOW_NATIVE_OUTPUT_DIR 与产物检查一致。
# 修改指引：改 Native 模块名或 .so 文件名时同步更新目标链接、产物检查及 Lua 加载名称。
# 示例：bash scripts/build_flywow.sh /path/to/skynet navigation
# 示例：BUILD_TYPE=Debug bash scripts/build_flywow.sh /path/to/skynet navigation
# 示例：bash scripts/build_flywow.sh /path/to/skynet all
# 示例：从 Server 根目录单独构建导航：bash third_party/skynet-flywow/scripts/build_flywow.sh third_party/skynet navigation
set -euo pipefail

# 以下是 Bash 变量，不是 CMake 变量；SCRIPT_DIR 从脚本文件位置计算，因此不依赖当前目录。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# FlyWow 仓库根目录；脚本位于 scripts/ 下，所以向上一级得到根目录。
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# 把第 1 个参数解析成绝对路径，后续依赖检查和 CMake 都使用同一个 Skynet 目录。
SKYNET_ROOT="$(realpath -- "${1:?用法: build_flywow.sh SKYNET_ROOT [gateway|navigation|logger|word_filter|hotupgrade|lua_binding|all]}")"
# 未提供第 2 个参数时构建全部模块；模块名必须与下面的 case 和构建分支一致。
MODULE="${2:-all}"
# 两个输出路径集中定义：修改这里可统一调整中间目录和最终 .so 目录。
BUILD_ROOT="$FRAMEWORK_DIR/build"
NATIVE_DIR="$BUILD_ROOT/native"
# BUILD_TYPE 可由调用命令前的环境变量覆盖，例如 BUILD_TYPE=Debug ...。
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"

# 入口参数白名单；新增模块时也要在此加入，否则脚本会提前拒绝。
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

# 按模块检查前置依赖；新增模块时只检查它实际需要的头文件或系统库。
if [[ "$MODULE" == gateway || "$MODULE" == all ]]; then
    [[ -f "$SKYNET_ROOT/3rd/lua/lua.h" ]] || {
        printf '%s\n' 'Gateway 需要 Skynet 自带的 Lua 头文件' >&2
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

# 所有最终动态库共用此目录；CMake 中间文件仍按模块隔离。
mkdir -p "$NATIVE_DIR"

# Lua Binding 是 Navigation 的构建依赖，也可单独选择；它只产出静态库。
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

# Gateway 分支只构建握手 Native .so；Lua Service、客户端 SDK 和协议工具不属于这个目标。
# 源码、OpenSSL 3、链接选项与原子发布规则集中在 gateway/native/CMakeLists.txt。
if [[ "$MODULE" == gateway || "$MODULE" == all ]]; then
    # -S 选择 Gateway Native 源码；-B 隔离此模块 CMake 缓存。
    # CXX 仅在首次配置缓存时选编译器；Skynet 路径固定 Lua ABI，输出路径匹配 Gateway lua_cpath。
    cmake -S "$FRAMEWORK_DIR/gateway/native" -B "$BUILD_ROOT/cmake/gateway" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DCMAKE_CXX_COMPILER="${CXX:-c++}" \
        -DSKYNET_ROOT="$SKYNET_ROOT" \
        -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR"

    # 默认构建会编译模块及发布目标；仅在链接成功后替换正式 .so。
    cmake --build "$BUILD_ROOT/cmake/gateway" -j"$(nproc)"

    # 确认 Lua require 搜索目录中存在非空正式产物。
    test -s "$NATIVE_DIR/flywow_gateway_crypto.so"
fi

# CMake 参数：-S 指源码目录，-B 指生成/中间目录，-DNAME=VALUE 向 CMake 传配置变量。
# Navigation 源文件清单见 navigation/native/CMakeLists.txt；最终 .so 目录由 NATIVE_DIR 传入。
if [[ "$MODULE" == navigation || "$MODULE" == all ]]; then
    cmake -S "$FRAMEWORK_DIR/navigation/native" -B "$BUILD_ROOT/cmake/navigation" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DFLYWOW_NAVIGATION_LUA=ON \
        -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR" -DSKYNET_ROOT="$SKYNET_ROOT"
    cmake --build "$BUILD_ROOT/cmake/navigation" -j"$(nproc)"
    ctest --test-dir "$BUILD_ROOT/cmake/navigation" --output-on-failure
    test -s "$NATIVE_DIR/flywow_navigation_native.so"
fi

# Logger 源文件清单和目标名见 logger/native/CMakeLists.txt；此处分配独立中间目录。
if [[ "$MODULE" == logger || "$MODULE" == all ]]; then
    cmake -S "$FRAMEWORK_DIR/logger/native" -B "$BUILD_ROOT/cmake/logger" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DSKYNET_ROOT="$SKYNET_ROOT" \
        -DSKYNET_LUA_DIR="$SKYNET_ROOT/3rd/lua" \
        -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR"
    cmake --build "$BUILD_ROOT/cmake/logger" -j"$(nproc)"
    ctest --test-dir "$BUILD_ROOT/cmake/logger" --output-on-failure
    test -s "$NATIVE_DIR/flywow_logger.so"
fi

# WordFilter 的目标和源文件由 word_filter/native/CMakeLists.txt 管理。
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

# HotUpgrade Native 由 CMake 构建；Service 集成测试由专用脚本显式启动。
if [[ "$MODULE" == hotupgrade || "$MODULE" == all ]]; then
    # 不在通用构建入口里隐式启动测试 Skynet 进程。
    cmake -S "$FRAMEWORK_DIR/hotupgrade/native" -B "$BUILD_ROOT/cmake/hotupgrade" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DSKYNET_ROOT="$SKYNET_ROOT" \
        -DFLYWOW_NATIVE_OUTPUT_DIR="$NATIVE_DIR"
    cmake --build "$BUILD_ROOT/cmake/hotupgrade" -j"$(nproc)"
    test -s "$NATIVE_DIR/flywow_hotupgrade_native.so"
fi

printf 'FLYWOW_BUILD_OK module=%s native_dir=%s build_type=%s\n' "$MODULE" "$NATIVE_DIR" "$BUILD_TYPE"
