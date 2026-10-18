# 职责：构建 HotUpgrade Native Binding；它只提供 Patch 路径校验、文件枚举和审计同步，不替换业务 Native。
# 调用方式：统一脚本通过 -D 传入 SKYNET_ROOT 与 FLYWOW_NATIVE_OUTPUT_DIR，通常无需手工调用。
# CMake 变量：${NAME} 不是系统环境变量；SKYNET_ROOT 和 FLYWOW_NATIVE_OUTPUT_DIR 由统一脚本通过 -D 传入。
# 修改指引：新增编译文件放进 add_library 源文件列表；新依赖配套 find_package 与 target_link_libraries。
# 修改指引：改目标名或 .so 名称时同步更新本文件、统一脚本产物检查和 Lua 加载名。
# 修改指引：改最终输出目录请改统一脚本的 NATIVE_DIR；本文件通过 FLYWOW_NATIVE_OUTPUT_DIR 接收。
cmake_minimum_required(VERSION 3.16)
project(flywow_hotupgrade LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT EXISTS "${SKYNET_ROOT}/3rd/lua/lua.h")
    message(FATAL_ERROR "HotUpgrade 需要固定 Skynet 自带 Lua 头文件")
endif()
if(NOT TARGET flywow_lua_binding)
    set(SKYNET_LUA_DIR "${SKYNET_ROOT}/3rd/lua")
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../lua-binding
        ${CMAKE_BINARY_DIR}/lua-binding EXCLUDE_FROM_ALL)
endif()
# MODULE 生成 Lua 可加载的共享库；新增本模块 .cpp 源文件在此登记。
add_library(flywow_hotupgrade_native MODULE hotupgrade_native.cpp)
target_include_directories(flywow_hotupgrade_native PRIVATE "${SKYNET_ROOT}/3rd/lua")
target_include_directories(flywow_hotupgrade_native PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../lua-binding)
# 此目标使用 FlyWow Lua Binding；新增链接库时先声明依赖，再加到这里。
target_link_libraries(flywow_hotupgrade_native PRIVATE flywow_lua_binding)
target_compile_options(flywow_hotupgrade_native PRIVATE -Wall -Wextra -Wpedantic -Werror)
# CMake 目标名供 target_* 命令引用；PREFIX 控制文件前缀，输出目录由统一脚本传入。
set_target_properties(flywow_hotupgrade_native PROPERTIES
    PREFIX ""
    LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}"
)
target_sources(flywow_hotupgrade_native PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../common/native/skynet_allocator.cpp")
# 在此 Native DSO 内绑定自定义 operator new/delete，避免被 libstdc++ 的实现抢先解析。
set_property(TARGET flywow_hotupgrade_native APPEND_STRING PROPERTY LINK_FLAGS " -Wl,-Bsymbolic-functions")
