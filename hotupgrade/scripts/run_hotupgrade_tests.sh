#!/usr/bin/env bash
# 职责：热更独立测试入口；由构建脚本或开发者在编译 Native 后运行。
# 参数：$1 固定 Skynet 根目录。产物仅在 FlyWow build/hotupgrade-tests。
# 副作用：生成/覆盖测试夹具和测试审计，启动独立 Skynet；失败返回非零。
# 示例：bash hotupgrade/scripts/run_hotupgrade_tests.sh ../skynet
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?需要 Skynet 根目录}")"
cd "$FRAMEWORK_DIR"
export LUA_PATH="$FRAMEWORK_DIR/hotupgrade/lualib/?.lua;$FRAMEWORK_DIR/hotupgrade/tests/?.lua;;"
export LUA_CPATH="$FRAMEWORK_DIR/build/native/?.so;;"
rm -rf build/hotupgrade-tests/patches
mkdir -p build/hotupgrade-tests/patches/{module,migrate,drain,dry,failed_candidate,busy_candidate,rollback}
mkdir -p build/hotupgrade-tests/patches/{module,migrate,drain,dry,failed_candidate,busy_candidate,rollback}/{modules,services/worker,migrations/worker}
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_foundation.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/prepare_test_packages.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_files.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_router.lua
cd "$FRAMEWORK_DIR/../.."
timeout 45 "$SKYNET_ROOT/skynet" ./third_party/skynet-flywow/hotupgrade/tests/skynet_config.lua \
    2>&1 | tee ./third_party/skynet-flywow/build/hotupgrade-tests/skynet.log
grep -q HOTUPGRADE_SKYNET_RESTART_FAIL_CLOSED_OK ./third_party/skynet-flywow/build/hotupgrade-tests/skynet.log
