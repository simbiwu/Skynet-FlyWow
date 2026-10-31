#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/third_party/skynet-flywow/hotupgrade/scripts/run_hotupgrade_tests.sh [按本文件头部说明填写参数]
# 调用：可从任意目录运行 bash /path/to/skynet-flywow/hotupgrade/scripts/run_hotupgrade_tests.sh /absolute/path/to/skynet。
# 只重建本测试拥有的 Patch 和宿主夹具，运行 Lua 合同与无业务端口的独立 Skynet。
# Native 由 scripts/build_flywow.sh <Skynet目录> hotupgrade 预先构建；日志保存在 build/hotupgrade-tests。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:?错误说明展开：必需变量未设置或为空时显示说明并以非零状态失败。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   for/while ... do ... done 重复执行循环体；列表或条件决定循环何时结束。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   export 把变量加入子进程环境；普通赋值默认只在当前 Shell 中可见。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# $1 必须是 Skynet 根目录；${1:?说明} 在缺失或为空时由 Bash 报错退出。例：run_hotupgrade_tests.sh /opt/skynet 将该路径规范化后用于后续启动。
SKYNET_ROOT="$(realpath -- "${1:?需要 Skynet 根目录}")"
# 固定后续所有相对文件名的工作目录为 FlyWow 根目录。
cd "$FRAMEWORK_DIR"
export LUA_PATH="$FRAMEWORK_DIR/common/lualib/?.lua;$FRAMEWORK_DIR/hotupgrade/lualib/?.lua;$FRAMEWORK_DIR/hotupgrade/tests/?.lua;;"
export LUA_CPATH="$FRAMEWORK_DIR/build/native/?.so;;"
# 删除和重建的仅是本测试拥有的临时 host/Patch 夹具。
rm -rf build/hotupgrade-tests/patches build/hotupgrade-tests/host build/hotupgrade-tests/host-original
mkdir -p build/hotupgrade-tests/patches
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/prepare_test_packages.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_foundation.lua
"$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_module_reference_contract.lua
# for 按列表逐项执行 Lua 测试；set -e 让首个失败场景停止整组验收。
for scenario in controller module service management_abort diagnostic; do
    "$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_failure_continuation.lua "$scenario"
done
# 每个业务接收器场景拥有独立 Lua State，不为测试向生产模块增加 reset 接口。
# 每个状态场景在独立 Lua State 中运行，避免测试为生产模块新增 reset API。
for scenario in shared custom nested_shared cycles old_alias types empty direct_fields expansion depth depth_boundary field_boundary snapshot_size abort recovery recovery_retry custom_recovery partial_throw bad_state_callback; do
    "$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_service_state.lua "$scenario"
done
CONTROLLER_LOG="$FRAMEWORK_DIR/build/hotupgrade-tests/controller.log"
: > "$CONTROLLER_LOG"
# 控制器场景输出追加到同一日志；后续 grep -c 用成功标记总数检查循环是否完整。
for scenario in lifecycle interleaved creation_returned matching combined paths custom_paths unique resources draining drain_abort_rejected drain_unsupported drain_new_failure; do
    "$SKYNET_ROOT/3rd/lua/lua" hotupgrade/tests/test_controller.lua "$scenario" \
        2>&1 | tee -a "$CONTROLLER_LOG"
done
test "$(grep -c HOTUPGRADE_CONTROLLER_SCENARIO_OK "$CONTROLLER_LOG")" -eq 13
cp -a build/hotupgrade-tests/host build/hotupgrade-tests/host-original
cd "$FRAMEWORK_DIR/../.."
LOG="$FRAMEWORK_DIR/build/hotupgrade-tests/skynet.log"
: > "$LOG"
# 每轮恢复 host 原始夹具，再以环境变量传入一个场景启动 Skynet。
for group in source_headers kill_prepare kill_update kill_finish monitor_occupied exit_module_load exit_prepare exit_update exit_finish drain_creation drain_queue drain_modules drain_late_module drain_new_failure drain_update_failure deployment deploy_failure service_file lifecycle preload host_paths custom_paths patch_match identity_queue registration_missing prepare_false prepare_error optional_service state_shared state_shared_failure declaration bad_functions stage_failure activation_after_failure activation_custom_failure activation_custom_success activation_custom_success_failure multiple_targets partial new_modules new_modules_concurrent_conflict new_modules_candidate_undeclared new_modules_candidate_caught_error new_modules_failure management_abort recovery_restore recovery_module; do
    rm -rf -- "$FRAMEWORK_DIR/build/hotupgrade-tests/host"
    cp -a "$FRAMEWORK_DIR/build/hotupgrade-tests/host-original" "$FRAMEWORK_DIR/build/hotupgrade-tests/host"
    HOTUPGRADE_TEST_GROUP="$group" timeout 45 "$SKYNET_ROOT/skynet" \
        ./third_party/skynet-flywow/hotupgrade/tests/skynet_config.lua \
        2>&1 | tee -a "$LOG"
done
# grep -c 统计成功标记，命令替换把数字交给 test；固定数量不符即失败。
test "$(grep -c HOTUPGRADE_SKYNET_GROUP_OK "$LOG")" -eq 47
# 每个真实 Skynet 进程都应执行 Native 文件扫描与路径测试。
test "$(grep -c HOTUPGRADE_FILES_OK "$LOG")" -eq 47
if grep -q HOTUPGRADE_SKYNET_FAILED "$LOG"; then
    exit 1
fi
