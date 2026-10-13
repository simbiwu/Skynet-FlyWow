# 职责：定义 Navigation C++ 核心、可选 Lua Binding、测试与 Benchmark。
# 调用方式：统一脚本传入 SKYNET_ROOT 与 Native 输出目录；C++ 宿主可 add_subdirectory 后链接 FlyWow::Navigation。
# CMake 变量：${NAME} 不是系统环境变量；SKYNET_ROOT 和 FLYWOW_NATIVE_OUTPUT_DIR 由 -D 传入。
# CMAKE_CURRENT_SOURCE_DIR 是 CMake 自动提供的本源码目录；构建输出目录由 -B 指定。
# 产物：静态核心 flywow_navigation_core；消费者别名 FlyWow::Navigation；可选 Lua 模块 flywow_navigation_native.so。
# 修改指引：新增核心 .cpp 更新核心源文件清单；测试和 Benchmark 更新各自可执行目标。
# 修改指引：新增系统依赖用 find_package 并链接到使用它的目标；改名同步统一脚本与 Lua Wrapper。
# 修改指引：改最终 .so 输出目录请改统一脚本的 NATIVE_DIR；本文件通过 FLYWOW_NATIVE_OUTPUT_DIR 接收。
cmake_minimum_required(VERSION 3.16)
project(flywow_navigation LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

enable_testing()
find_package(Threads REQUIRED)

# Navigation 只有一个静态核心目标；地图、寻路和运行时状态实现共同组成它。
# 新增核心 .cpp 在此目标列表登记；该 STATIC 库供 C++ 消费者和可选 Lua Binding 共用。
add_library(flywow_navigation_core STATIC
    air_asset.cpp
    air_navigation.cpp
    bmap_reader.cpp
    grid_map.cpp
    map_registry.cpp
    nav_result.cpp
    dynamic_occupancy.cpp
    navigation_context.cpp
    navigation_profile_registry.cpp
    grid_pathfinder.cpp
)

# 静态库还会链接进 Lua MODULE，因此 Linux 下需要位置无关的目标文件。
set_target_properties(flywow_navigation_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

# 对外头文件与 Navigation 实现同处 native；通过 PUBLIC 传递给消费者。
target_include_directories(flywow_navigation_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(flywow_navigation_core PUBLIC Threads::Threads)

# 给消费者稳定的模块级名称；ALIAS 不会生成第二份库文件。
# ALIAS 是消费者稳定名称，不生成第二份库；宿主用 FlyWow::Navigation 链接核心。
add_library(FlyWow::Navigation ALIAS flywow_navigation_core)

# 编译选项按工具链区分，保持同一 Navigation 核心可被 Linux Server 与 Windows 客户端宿主构建。
if(MSVC)
    target_compile_options(flywow_navigation_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(flywow_navigation_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

# 测试和 Benchmark 通过公开别名链接，验证的就是消费者看到的 Navigation 目标。
# 测试源文件登记到对应可执行目标，并通过 add_test 交给 CTest。
add_executable(grid_map_test tests/grid_map_test.cpp)
target_link_libraries(grid_map_test PRIVATE FlyWow::Navigation)
if(MSVC)
    target_compile_options(grid_map_test PRIVATE /UNDEBUG)
else()
    target_compile_options(grid_map_test PRIVATE -UNDEBUG)
endif()
add_test(NAME grid_map_test COMMAND grid_map_test)

add_executable(navigation_test tests/navigation_test.cpp)
target_link_libraries(navigation_test PRIVATE FlyWow::Navigation)
if(MSVC)
    target_compile_options(navigation_test PRIVATE /W4 /permissive- /UNDEBUG)
else()
    target_compile_options(navigation_test PRIVATE -Wall -Wextra -Wpedantic -UNDEBUG)
endif()
add_test(NAME navigation_test COMMAND navigation_test)

# Benchmark 只构建，不注册为自动测试，避免把性能采样混入正确性门禁。
add_executable(navigation_benchmark benchmark/navigation_benchmark.cpp)
target_link_libraries(navigation_benchmark PRIVATE FlyWow::Navigation)
if(MSVC)
    target_compile_options(navigation_benchmark PRIVATE /W4 /permissive-)
else()
    target_compile_options(navigation_benchmark PRIVATE -Wall -Wextra -Wpedantic)
endif()

# 默认只生成 C++ 核心；Skynet 构建入口打开此选项后才构建 Lua 动态模块。
option(FLYWOW_NAVIGATION_LUA "构建供 Skynet Lua 5.4.7 加载的 Native Binding" OFF)
set(FLYWOW_NATIVE_OUTPUT_DIR "" CACHE PATH "FlyWow Lua Native .so 的输出目录")

# 只有 Skynet Lua 宿主需要 Binding；Unity/C++ 消费者直接链接核心，不构建此分支。
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

    # MODULE 是 Lua 参数适配层；地图和寻路实现仍由上面的核心库负责。
    add_library(flywow_navigation_lua MODULE navigation_binding.cpp)
    target_include_directories(flywow_navigation_lua PRIVATE
        "${SKYNET_LUA_DIR}"
    )
    target_link_libraries(flywow_navigation_lua PRIVATE FlyWow::Navigation flywow_lua_binding)
    target_compile_options(flywow_navigation_lua PRIVATE -Wall -Wextra -Wpedantic)

    # Lua Wrapper 名称与 Native 模块名称不同，避免 require 递归加载 Wrapper 自身。
    # OUTPUT_NAME 决定 Lua 加载的文件名；改名同步 Wrapper require 与统一脚本产物检查。
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
add_executable(air_navigation_test tests/air_navigation_test.cpp)
target_link_libraries(air_navigation_test PRIVATE FlyWow::Navigation)
if(MSVC)
    target_compile_options(air_navigation_test PRIVATE /UNDEBUG)
else()
    target_compile_options(air_navigation_test PRIVATE -UNDEBUG)
endif()
add_test(NAME air_navigation_test COMMAND air_navigation_test)

target_compile_definitions(air_navigation_test PRIVATE FLYWOW_AIR_GOLDEN_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/../unity/Tests/Editor/Fixtures")

add_executable(air_navigation_benchmark benchmark/air_navigation_benchmark.cpp)
target_link_libraries(air_navigation_benchmark PRIVATE FlyWow::Navigation)
