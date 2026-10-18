#!/usr/bin/env bash
# 从 FlyWow 根目录调用：bash hotupgrade/scripts/run_hotupgrade_tests.sh <Skynet根目录>。
# 只重建本测试拥有的 patches 夹具，运行 Lua 合同与无业务端口的独立 Skynet。
# Native 由 scripts/build_flywow.sh <Skynet目录> hotupgrade 预先构建；日志保存在 build/hotupgrade-tests。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?需要 Skynet 根目录}")"
cd "$FRAMEWORK_DIR"
export LUA_PATH="$FRAMEWORK_DIR/hotupgrade/lualib/?.lua;$FRAMEWORK_DIR/hotupgrade/tests/?.lua;;"
export LUA_CPATH="$FRAMEWORK_DIR/build/native/?.so;;"
rm -rf build/hotupgrade-tests/patches
mkdir -p build/hotupgrade-tests/patches
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/prepare_test_packages.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_foundation.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_controller.lua
cd "$FRAMEWORK_DIR/../.."
timeout 45 "$SKYNET_ROOT/skynet" ./third_party/skynet-flywow/hotupgrade/tests/skynet_config.lua \
    2>&1 | tee ./third_party/skynet-flywow/build/hotupgrade-tests/skynet.log
grep -q HOTUPGRADE_SKYNET_ALL_OK ./third_party/skynet-flywow/build/hotupgrade-tests/skynet.log
if grep -q HOTUPGRADE_SKYNET_FAILED ./third_party/skynet-flywow/build/hotupgrade-tests/skynet.log; then
    exit 1
fi
