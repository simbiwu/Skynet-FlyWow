#!/usr/bin/env bash
# 从 FlyWow 根目录调用：bash hotupgrade/scripts/run_hotupgrade_tests.sh <Skynet根目录>。
# 只重建本测试拥有的 Patch 和宿主夹具，运行 Lua 合同与无业务端口的独立 Skynet。
# Native 由 scripts/build_flywow.sh <Skynet目录> hotupgrade 预先构建；日志保存在 build/hotupgrade-tests。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?需要 Skynet 根目录}")"
cd "$FRAMEWORK_DIR"
export LUA_PATH="$FRAMEWORK_DIR/hotupgrade/lualib/?.lua;$FRAMEWORK_DIR/hotupgrade/tests/?.lua;;"
export LUA_CPATH="$FRAMEWORK_DIR/build/native/?.so;;"
rm -rf build/hotupgrade-tests/patches build/hotupgrade-tests/host build/hotupgrade-tests/host-original
mkdir -p build/hotupgrade-tests/patches
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/prepare_test_packages.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_foundation.lua
CONTROLLER_LOG="$FRAMEWORK_DIR/build/hotupgrade-tests/controller.log"
: > "$CONTROLLER_LOG"
for scenario in lifecycle interleaved matching combined paths custom_paths unique resources; do
    "$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_controller.lua "$scenario" \
        2>&1 | tee -a "$CONTROLLER_LOG"
done
test "$(grep -c HOTUPGRADE_CONTROLLER_SCENARIO_OK "$CONTROLLER_LOG")" -eq 8
cp -a build/hotupgrade-tests/host build/hotupgrade-tests/host-original
cd "$FRAMEWORK_DIR/../.."
LOG="$FRAMEWORK_DIR/build/hotupgrade-tests/skynet.log"
: > "$LOG"
for group in deployment deploy_failure service_file lifecycle preload host_paths custom_paths patch_match identity_queue registration_missing prepare_false prepare_error optional_service declaration bad_functions stage_failure activation_after_failure activation_custom_failure activation_custom_success activation_custom_success_failure multiple_targets partial abort recovery_restore recovery_module; do
    rm -rf -- "$FRAMEWORK_DIR/build/hotupgrade-tests/host"
    cp -a "$FRAMEWORK_DIR/build/hotupgrade-tests/host-original" "$FRAMEWORK_DIR/build/hotupgrade-tests/host"
    HOTUPGRADE_TEST_GROUP="$group" timeout 45 "$SKYNET_ROOT/skynet" \
        ./third_party/skynet-flywow/hotupgrade/tests/skynet_config.lua \
        2>&1 | tee -a "$LOG"
done
test "$(grep -c HOTUPGRADE_SKYNET_GROUP_OK "$LOG")" -eq 25
# 每个真实 Skynet 进程都应执行 Native 文件扫描与路径测试。
test "$(grep -c HOTUPGRADE_FILES_OK "$LOG")" -eq 25
if grep -q HOTUPGRADE_SKYNET_FAILED "$LOG"; then
    exit 1
fi
