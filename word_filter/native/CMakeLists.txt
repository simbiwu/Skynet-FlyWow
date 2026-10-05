# 职责：构建 WordFilter 核心、Lua Binding 与测试；不安装依赖、不启动业务 Server。
# 输入：本模块源码、SKYNET_ROOT 自带 Lua 头文件及可选测试运行器。
# 产物：静态核心、FLYWOW_NATIVE_OUTPUT_DIR 下的 Native .so、当前 CMake 目录下的测试程序。
# 调用：统一入口 scripts/build_flywow.sh SKYNET_ROOT word_filter。
cmake_minimum_required(VERSION 3.16)
project(flywow_word_filter LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
enable_testing()
find_package(Threads REQUIRED)

# 核心不依赖 Lua/Skynet；PIC 允许静态核心链接进 Native .so。
add_library(flywow_word_filter_core STATIC word_filter.cpp)
set_target_properties(flywow_word_filter_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(flywow_word_filter_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_options(flywow_word_filter_core PRIVATE -Wall -Wextra -Werror)

# 固定使用 Skynet 自带 Lua ABI；不链接系统 Lua，由加载进程提供 Lua 符号。
if(NOT EXISTS "${SKYNET_ROOT}/3rd/lua/lua.h")
    message(FATAL_ERROR "word_filter 需要 Skynet 自带 Lua 头文件")
endif()

add_library(flywow_word_filter_native MODULE lua_word_filter.cpp)
target_include_directories(flywow_word_filter_native PRIVATE "${SKYNET_ROOT}/3rd/lua")
target_link_libraries(flywow_word_filter_native PRIVATE flywow_word_filter_core)
target_compile_options(flywow_word_filter_native PRIVATE -Wall -Wextra -Werror)
set_target_properties(flywow_word_filter_native PROPERTIES
    PREFIX ""
    LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}")

# C++ 回归与只读并发测试始终可执行，不需要启动 Skynet。
add_executable(flywow_word_filter_test ../tests/test_word_filter.cpp)
target_link_libraries(flywow_word_filter_test PRIVATE flywow_word_filter_core Threads::Threads)
add_test(NAME flywow_word_filter_core COMMAND flywow_word_filter_test)

# Lua 运行器存在时，测试公开 Wrapper -> Native 链路；缺少运行器不表示此项已验证。
if(EXISTS "${SKYNET_ROOT}/3rd/lua/lua")
    add_test(NAME flywow_word_filter_lua
        COMMAND "${SKYNET_ROOT}/3rd/lua/lua"
        "${CMAKE_CURRENT_SOURCE_DIR}/../tests/test_word_filter.lua"
        "${CMAKE_CURRENT_SOURCE_DIR}/../lualib"
        "${FLYWOW_NATIVE_OUTPUT_DIR}")
endif()

# 当前真实集成宿主为主仓库 server/；测试配置的相对路径以此目录为基准。
# Skynet 会正常 ABORT 退出，成功/失败标记与超时共同判断结果。
get_filename_component(FLYWOW_SERVER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." ABSOLUTE)
if(EXISTS "${SKYNET_ROOT}/skynet")
    add_test(NAME flywow_word_filter_skynet
        COMMAND "${SKYNET_ROOT}/skynet" "./third_party/skynet-flywow/word_filter/tests/skynet_config.lua")
    set_tests_properties(flywow_word_filter_skynet PROPERTIES
        WORKING_DIRECTORY "${FLYWOW_SERVER_DIR}"
        PASS_REGULAR_EXPRESSION "FLYWOW_WORD_FILTER_SKYNET_OK"
        FAIL_REGULAR_EXPRESSION "FLYWOW_WORD_FILTER_SKYNET_FAIL"
        TIMEOUT 20)
endif()
