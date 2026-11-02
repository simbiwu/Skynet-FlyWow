# 职责：构建供 FlyWow Native 模块静态链接的 Lua C API 支持库及可选 ABI 测试。
# 调用方式：统一脚本配置；Navigation/WordFilter 也可通过 add_subdirectory 引入。
# CMake 变量：${NAME} 不是系统环境变量；SKYNET_LUA_DIR 和 SKYNET_LUA_LIBRARY 由调用脚本/父项目传入。
# 输出：静态库和测试程序位于 CMake 构建目录，另外生成可直接 require 的 NativeData 模块。
# 修改指引：新增实现文件更新 flywow_lua_binding；新增测试更新测试目标并用 add_test 注册。
# 修改指引：新增依赖同步目标链接项；不自动搜索或链接系统 Lua。
# 修改指引：改静态目标名时同步更新所有链接它的 Gateway、Navigation、WordFilter 和 HotUpgrade 目标。
cmake_minimum_required(VERSION 3.16)
project(flywow_lua_binding LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT EXISTS "${SKYNET_LUA_DIR}/lua.h")
    message(FATAL_ERROR "SKYNET_LUA_DIR must point to bundled Skynet Lua headers")
endif()
# STATIC 表示各 Native 模块把它链接进自己的 .so；新增库实现文件在此登记。
add_library(flywow_lua_binding STATIC lua_binding.cpp lua_table.cpp lua_native_data.cpp)
target_compile_features(flywow_lua_binding PUBLIC cxx_std_17)
target_include_directories(flywow_lua_binding PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}" "${SKYNET_LUA_DIR}")
target_compile_options(flywow_lua_binding PRIVATE -Wall -Wextra -Wpedantic)
set_target_properties(flywow_lua_binding PROPERTIES POSITION_INDEPENDENT_CODE ON
    CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
# NativeData 的 Lua 入口只链接静态核心；不链接另一套 Lua，由宿主提供 Lua 符号。
set(FLYWOW_NATIVE_OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/native" CACHE PATH
    "FlyWow Native 模块输出目录")
add_library(flywow_native_data MODULE lua_native_data_module.cpp)
target_link_libraries(flywow_native_data PRIVATE flywow_lua_binding)
set_target_properties(flywow_native_data PROPERTIES PREFIX "" OUTPUT_NAME flywow_native_data
    LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}")

target_compile_options(flywow_native_data PRIVATE -Wall -Wextra -Wpedantic)

# 统一脚本在需要真实 Lua ABI 回归时显式打开测试开关。
option(FLYWOW_LUA_BINDING_TESTS "Build real Lua ABI tests" OFF)
if(FLYWOW_LUA_BINDING_TESTS)
    enable_testing()
    if(NOT EXISTS "${SKYNET_LUA_LIBRARY}")
        message(FATAL_ERROR "Tests require explicit bundled SKYNET_LUA_LIBRARY")
    endif()
    # 测试链接调用者指定的 Skynet Lua 静态库，避免验证到另一套系统 Lua ABI。
    # 只在 ABI 测试中编译宿主现有 sharetable 实现，验证非 OOM 的共享表写入错误；源码保持只读。
    enable_language(C)
    add_executable(flywow_lua_binding_test tests/lua_binding_test.cpp
        "${SKYNET_LUA_DIR}/../../lualib-src/lua-sharetable.c")
    find_package(Threads REQUIRED)
    target_link_libraries(flywow_lua_binding_test PRIVATE flywow_lua_binding
        "${SKYNET_LUA_LIBRARY}" dl m Threads::Threads)
    target_compile_options(flywow_lua_binding_test PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME flywow_lua_binding_test COMMAND flywow_lua_binding_test)
    # 两个独立 .so 分别静态链接 Binding，通过同一 Lua State 验证具名类型互操作。
    foreach(peer IN ITEMS a b)
        add_library(native_data_peer_${peer} MODULE tests/lua_native_data_test.cpp)
        target_compile_definitions(native_data_peer_${peer} PRIVATE NATIVE_DATA_PEER_${peer})
        target_link_libraries(native_data_peer_${peer} PRIVATE flywow_lua_binding)
        target_compile_options(native_data_peer_${peer} PRIVATE -Wall -Wextra -Wpedantic)
        set_target_properties(native_data_peer_${peer} PROPERTIES PREFIX "")
    endforeach()
    add_executable(lua_native_data_test tests/lua_native_data_test.cpp)
    target_link_libraries(lua_native_data_test PRIVATE flywow_lua_binding
        "${SKYNET_LUA_LIBRARY}" dl m Threads::Threads)
    # 导出静态 Lua 符号，供 dlopen 的真实 Native 模块解析；测试使用同一宿主 ABI。
    target_link_options(lua_native_data_test PRIVATE -Wl,--export-dynamic)
    target_compile_options(lua_native_data_test PRIVATE -Wall -Wextra -Wpedantic)
    add_dependencies(lua_native_data_test flywow_native_data native_data_peer_a native_data_peer_b)
    add_test(NAME lua_native_data_test COMMAND lua_native_data_test
        "$<TARGET_FILE_DIR:flywow_native_data>" "$<TARGET_FILE_DIR:native_data_peer_a>")
endif()
