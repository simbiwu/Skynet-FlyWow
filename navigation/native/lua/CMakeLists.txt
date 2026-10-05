# 职责：构建 Skynet Lua 可加载的 flywow_navigation_lua Native 模块。
# 边界：Server Native Build；复用 grid_map_core 和 Skynet 自带的 Lua 头文件。
# 输入/输出：Binding C++ 源码 -> 无 lib 前缀的共享模块。
# 运行时机：独立配置本目录时，同时引入 grid_map_core 的构建定义。
# 不负责：不安装系统 Lua，不构建或启动 Skynet，不加载 BMAP。
cmake_minimum_required(VERSION 3.16)
project(flywow_navigation_lua LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Binding 必须使用当前 Skynet 源码树中的 Lua ABI，不能偶然链接系统 Lua。
set(SKYNET_ROOT "" CACHE PATH "宿主固定版本 Skynet 源码目录")
set(SKYNET_LUA_DIR "${SKYNET_ROOT}/3rd/lua")
if(NOT EXISTS "${SKYNET_LUA_DIR}/lua.h")
    message(FATAL_ERROR "Skynet bundled Lua headers not found: ${SKYNET_LUA_DIR}")
endif()

# 允许本目录独立执行 cmake -S；EXCLUDE_FROM_ALL 避免顺带构建 Grid 测试程序。
if(NOT TARGET grid_map_core)
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../grid_map"
                     "${CMAKE_BINARY_DIR}/grid_map" EXCLUDE_FROM_ALL)
endif()

add_library(flywow_navigation_lua MODULE src/lua_navigation.cpp)
target_include_directories(flywow_navigation_lua PRIVATE
    include
    ../grid_map/include
    "${SKYNET_LUA_DIR}"
)
target_link_libraries(flywow_navigation_lua PRIVATE grid_map_core)
target_compile_options(flywow_navigation_lua PRIVATE -Wall -Wextra -Wpedantic)
# Lua 的 require "flywow_navigation" 按约定查找 flywow_navigation.so 和 luaopen_flywow_navigation。
set_target_properties(flywow_navigation_lua PROPERTIES PREFIX "" OUTPUT_NAME "flywow_navigation")
