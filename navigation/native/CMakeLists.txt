# 职责：定义完整 FlyWow Navigation Native 库、Lua Binding、测试与 Benchmark。
# 边界：Grid Map 是 Navigation 的内部实现；不单独构建或发布 Grid 库。
# 使用方式：
# - 同一 CMake 构建树中的 C++ 消费者通过 FlyWow::Navigation 链接静态库。
# - Skynet Lua 构建时设置 FLYWOW_NAVIGATION_LUA=ON，并提供 SKYNET_ROOT；
#   生成的 flywow_navigation_native.so 由 flywow_navigation.lua 加载。
# 产物：静态核心库、可选 Lua Native .so、测试与 Benchmark 可执行文件。
cmake_minimum_required(VERSION 3.16)
project(flywow_navigation LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

enable_testing()
find_package(Threads REQUIRED)

# 完整 Navigation 核心只有一个静态库目标；Grid Map 源码只是其中一部分。
add_library(flywow_navigation_core STATIC
    grid_map/bmap_reader.cpp
    grid_map/grid_map.cpp
    grid_map/map_registry.cpp
    grid_map/nav_result.cpp
    grid_map/dynamic_occupancy.cpp
    grid_map/navigation_context.cpp
    grid_map/navigation_profile_registry.cpp
    grid_map/grid_pathfinder.cpp
)

# 静态库还会链接进 Lua MODULE，因此 Linux 下需要位置无关的目标文件。
set_target_properties(flywow_navigation_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

# 对外头文件目前位于 grid_map；通过 PUBLIC 传递给链接 Navigation 的消费者。
target_include_directories(flywow_navigation_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/grid_map")
target_link_libraries(flywow_navigation_core PUBLIC Threads::Threads)

# 给消费者稳定的模块级名称；ALIAS 不会生成第二份库文件。
add_library(FlyWow::Navigation ALIAS flywow_navigation_core)

# 编译选项按工具链区分，保持同一 Navigation 核心可被 Linux Server 与 Windows 客户端宿主构建。
if(MSVC)
    target_compile_options(flywow_navigation_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(flywow_navigation_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

# 测试和 Benchmark 通过公开别名链接，验证的就是消费者看到的 Navigation 目标。
add_executable(grid_map_test grid_map/tests/grid_map_test.cpp)
target_link_libraries(grid_map_test PRIVATE FlyWow::Navigation)
if(MSVC)
    target_compile_options(grid_map_test PRIVATE /UNDEBUG)
else()
    target_compile_options(grid_map_test PRIVATE -UNDEBUG)
endif()
add_test(NAME grid_map_test COMMAND grid_map_test)

add_executable(navigation_test grid_map/tests/navigation_test.cpp)
target_link_libraries(navigation_test PRIVATE FlyWow::Navigation)
if(MSVC)
    target_compile_options(navigation_test PRIVATE /W4 /permissive- /UNDEBUG)
else()
    target_compile_options(navigation_test PRIVATE -Wall -Wextra -Wpedantic -UNDEBUG)
endif()
add_test(NAME navigation_test COMMAND navigation_test)

# Benchmark 只构建，不注册为自动测试，避免把性能采样混入正确性门禁。
add_executable(navigation_benchmark grid_map/benchmark/navigation_benchmark.cpp)
target_link_libraries(navigation_benchmark PRIVATE FlyWow::Navigation)
if(MSVC)
    target_compile_options(navigation_benchmark PRIVATE /W4 /permissive-)
else()
    target_compile_options(navigation_benchmark PRIVATE -Wall -Wextra -Wpedantic)
endif()

option(FLYWOW_NAVIGATION_LUA "构建供 Skynet Lua 5.4.7 加载的 Native Binding" OFF)
set(FLYWOW_NATIVE_OUTPUT_DIR "" CACHE PATH "FlyWow Lua Native .so 的输出目录")

if(FLYWOW_NAVIGATION_LUA)
    # 该 Binding 使用 Linux Skynet ABI 和 ELF 链接选项；Windows Unity 只构建静态核心依赖。
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
        message(FATAL_ERROR "FLYWOW_NAVIGATION_LUA requires Linux and the host Skynet Lua ABI")
    endif()

    # 必须使用宿主固定版本 Skynet 自带的 Lua 头文件，不能意外链接系统 Lua。
    set(SKYNET_ROOT "" CACHE PATH "宿主固定版本 Skynet 源码目录")
    set(SKYNET_LUA_DIR "${SKYNET_ROOT}/3rd/lua")
    if(NOT EXISTS "${SKYNET_LUA_DIR}/lua.h")
        message(FATAL_ERROR "Skynet bundled Lua headers not found: ${SKYNET_LUA_DIR}")
    endif()

    # 复用 FlyWow 通用 Lua Binding 支持库；Navigation 自己只实现领域 API 适配。
    if(NOT TARGET flywow_lua_binding)
        add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../lua-binding"
                         "${CMAKE_BINARY_DIR}/lua-binding" EXCLUDE_FROM_ALL)
    endif()

    add_library(flywow_navigation_lua MODULE navigation_binding.cpp)
    target_include_directories(flywow_navigation_lua PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/grid_map"
        "${SKYNET_LUA_DIR}"
    )
    target_link_libraries(flywow_navigation_lua PRIVATE FlyWow::Navigation flywow_lua_binding)
    target_compile_options(flywow_navigation_lua PRIVATE -Wall -Wextra -Wpedantic)

    # Lua Wrapper 名称与 Native 模块名称不同，避免 require 递归加载 Wrapper 自身。
    set_target_properties(flywow_navigation_lua PROPERTIES
        PREFIX ""
        OUTPUT_NAME "flywow_navigation_native"
    )
    if(FLYWOW_NATIVE_OUTPUT_DIR)
        set_target_properties(flywow_navigation_lua PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}"
        )
    endif()

    # 自定义 allocator 必须进入同一 DSO，避免其符号被其它模块实现抢先解析。
    target_sources(flywow_navigation_lua PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/../../common/native/skynet_allocator.cpp"
    )
    target_link_options(flywow_navigation_lua PRIVATE "-Wl,-Bsymbolic-functions")
endif()
