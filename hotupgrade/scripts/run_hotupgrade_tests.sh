#!/usr/bin/env bash
# 职责：运行 HotUpgrade Lua、文件系统和独立 Skynet 集成测试；本脚本不编译 Native。
# 调用方式：从 FlyWow 根目录运行 bash hotupgrade/scripts/run_hotupgrade_tests.sh <Skynet目录>。
# 此测试由开发者显式运行，不会因 Native 编译自动启动。
# 参数：第 1 个位置参数是固定版本 Skynet 根目录。
# 输出：测试日志和生成夹具位于 FlyWow build/hotupgrade-tests/。
# 副作用：重建 build/hotupgrade-tests/patches 下的夹具并启动独立 Skynet；失败返回非零。
# 修改指引：新增 Lua 用例加到 Lua 测试命令区；日志标记改变时同步末尾检查。
# 修改指引：调整测试目录时同步检查夹具创建/清理路径、LUA_PATH、LUA_CPATH 和日志位置。
# 示例：bash hotupgrade/scripts/run_hotupgrade_tests.sh /path/to/skynet
set -euo pipefail

# Bash 路径变量从脚本位置和第 1 个参数计算，不依赖调用者当前目录。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?需要 Skynet 根目录}")"
# 切到 FlyWow 根目录后设置 Lua 搜索路径；末尾的 ;; 保留 Skynet 默认搜索路径。
cd "$FRAMEWORK_DIR"
export LUA_PATH="$FRAMEWORK_DIR/hotupgrade/lualib/?.lua;$FRAMEWORK_DIR/hotupgrade/tests/?.lua;;"
export LUA_CPATH="$FRAMEWORK_DIR/build/native/?.so;;"
# 仅清理由本脚本生成的测试夹具；不删除整个 build/hotupgrade-tests 或其它构建产物。
rm -rf build/hotupgrade-tests/patches
mkdir -p build/hotupgrade-tests/patches/{module,migrate,drain,dry,failed_candidate,busy_candidate,rollback}
mkdir -p build/hotupgrade-tests/patches/{module,migrate,drain,dry,failed_candidate,busy_candidate,rollback}/{modules,services/worker,migrations/worker}
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_foundation.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/prepare_test_packages.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_files.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_router.lua
# 集成配置使用相对 Server 路径，所以从 FlyWow 根目录回到宿主 Server 根目录。
cd "$FRAMEWORK_DIR/../.."
# 限制集成测试时长，并保存完整日志供最后的标记检查。
timeout 45 "$SKYNET_ROOT/skynet" ./third_party/skynet-flywow/hotupgrade/tests/skynet_config.lua \
    2>&1 | tee ./third_party/skynet-flywow/build/hotupgrade-tests/skynet.log
grep -q HOTUPGRADE_SKYNET_RESTART_FAIL_CLOSED_OK ./third_party/skynet-flywow/build/hotupgrade-tests/skynet.log
