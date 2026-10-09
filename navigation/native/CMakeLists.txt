# 职责：独立构建 FlyWow 地图、Grid 导航与可选 Lua Binding。
# 边界：Native Build；源码与 Skynet 路径显式分离，最终 Lua .so 统一写入 FlyWow/build/native。
# 输入：C++17 源码、可选 SKYNET_ROOT 和 FLYWOW_NATIVE_OUTPUT_DIR。
# 输出：CMake 中间文件、静态库、测试、Benchmark 和 Lua Native 模块。
# 不负责：不下载依赖、不加载游戏资产、不启动 Service。
cmake_minimum_required(VERSION 3.16)
project(flywow_navigation LANGUAGES CXX C)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
enable_testing()
add_subdirectory(grid_map)
option(FLYWOW_NAVIGATION_LUA "构建与宿主 Skynet Lua ABI 一致的 Binding" OFF)
set(FLYWOW_NATIVE_OUTPUT_DIR "" CACHE PATH "FlyWow Lua Native .so 的统一输出目录")
if(FLYWOW_NAVIGATION_LUA)
    # Binding 必须使用当前 Skynet 源码树中的 Lua ABI，不能偶然链接系统 Lua。
    set(SKYNET_ROOT "" CACHE PATH "宿主固定版本 Skynet 源码目录")
    set(SKYNET_LUA_DIR "${SKYNET_ROOT}/3rd/lua")
    if(NOT EXISTS "${SKYNET_LUA_DIR}/lua.h")
        message(FATAL_ERROR "Skynet bundled Lua headers not found: ${SKYNET_LUA_DIR}")
    endif()

    if(NOT TARGET flywow_lua_binding)
        add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../lua-binding"
                         "${CMAKE_BINARY_DIR}/lua-binding" EXCLUDE_FROM_ALL)
    endif()

    add_library(flywow_navigation_lua MODULE navigation_binding.cpp)
    target_include_directories(flywow_navigation_lua PRIVATE
        .
        grid_map
        "${SKYNET_LUA_DIR}"
    )
    target_link_libraries(flywow_navigation_lua PRIVATE grid_map_core flywow_lua_binding)
    target_compile_options(flywow_navigation_lua PRIVATE -Wall -Wextra -Wpedantic)
    # Lua Wrapper 使用 flywow_navigation；Native 使用独立名称，避免同名模块递归加载。
    # Lua 的 require "flywow_navigation_native" 会查找 .so 并调用 luaopen_flywow_navigation_native。
    set_target_properties(flywow_navigation_lua PROPERTIES
        PREFIX ""
        OUTPUT_NAME "flywow_navigation_native"
    )
    if(FLYWOW_NATIVE_OUTPUT_DIR)
        set_target_properties(flywow_navigation_lua PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}"
        )
    endif()
    target_sources(flywow_navigation_lua PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../common/native/skynet_allocator.cpp")
    # 在此 Native DSO 内绑定自定义 operator new/delete，避免被 libstdc++ 的实现抢先解析。
    set_property(TARGET flywow_navigation_lua APPEND_STRING PROPERTY LINK_FLAGS " -Wl,-Bsymbolic-functions")
endif()
