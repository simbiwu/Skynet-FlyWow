# 职责：构建供 FlyWow Native 模块静态链接的 Lua C API 支持库及可选 ABI 测试。
# 调用方式：统一脚本配置；Navigation/WordFilter 也可通过 add_subdirectory 引入。
# CMake 变量：${NAME} 不是系统环境变量；SKYNET_LUA_DIR 和 SKYNET_LUA_LIBRARY 由调用脚本/父项目传入。
# 输出：静态库和测试程序位于 CMake 构建目录，不生成独立运行时 .so。
# 修改指引：新增实现文件更新 flywow_lua_binding；新增测试更新测试目标并用 add_test 注册。
# 修改指引：新增依赖同步目标链接项；不自动搜索或链接系统 Lua。
# 修改指引：改静态目标名时同步更新所有链接它的 Navigation、WordFilter 和 HotUpgrade 目标。
cmake_minimum_required(VERSION 3.16)
project(flywow_lua_binding LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT EXISTS "${SKYNET_LUA_DIR}/lua.h")
    message(FATAL_ERROR "SKYNET_LUA_DIR must point to bundled Skynet Lua headers")
endif()
# STATIC 表示各 Native 模块把它链接进自己的 .so；新增库实现文件在此登记。
add_library(flywow_lua_binding STATIC lua_binding.cpp lua_table.cpp)
target_compile_features(flywow_lua_binding PUBLIC cxx_std_17)
target_include_directories(flywow_lua_binding PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}" "${SKYNET_LUA_DIR}")
target_compile_options(flywow_lua_binding PRIVATE -Wall -Wextra -Wpedantic)
set_target_properties(flywow_lua_binding PROPERTIES POSITION_INDEPENDENT_CODE ON
    CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
# 默认只构建支持库；统一脚本在需要真实 Lua ABI 回归时显式打开此开关。
option(FLYWOW_LUA_BINDING_TESTS "Build real Lua ABI tests" OFF)
if(FLYWOW_LUA_BINDING_TESTS)
    enable_testing()
    if(NOT EXISTS "${SKYNET_LUA_LIBRARY}")
        message(FATAL_ERROR "Tests require explicit bundled SKYNET_LUA_LIBRARY")
    endif()
    # 测试链接调用者指定的 Skynet Lua 静态库，避免验证到另一套系统 Lua ABI。
    add_executable(flywow_lua_binding_test tests/lua_binding_test.cpp)
    find_package(Threads REQUIRED)
    target_link_libraries(flywow_lua_binding_test PRIVATE flywow_lua_binding
        "${SKYNET_LUA_LIBRARY}" dl m Threads::Threads)
    target_compile_options(flywow_lua_binding_test PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME flywow_lua_binding_test COMMAND flywow_lua_binding_test)
endif()
