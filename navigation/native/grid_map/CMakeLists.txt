# 职责：构建 grid_map_core 和独立 Native 导航回归测试。
# 边界：Server Native Build；不下载依赖，不构建 Skynet 本体。
# 输入/输出：本目录 C++ 源码 -> 静态库、测试可执行文件和 CTest 用例。
# 运行时机：Native 代码变化后，由 scripts/build_flywow.sh 驱动。
# 不负责：不下载依赖、不加载 Unity Scene、不启动 BattleWorker、不生成 BMAP。
cmake_minimum_required(VERSION 3.16)
project(flywow_grid_map LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# 先构建共享的 Native 核心，再分别链接测试与 Benchmark；三者复用同一份实现。
# Lua Binding 在自己的 CMake 中链接该核心，不能在这里引入 Lua/Skynet 运行依赖。
add_library(grid_map_core STATIC
    src/bmap_reader.cpp
    src/grid_map.cpp
    src/map_registry.cpp
    src/nav_result.cpp
    src/dynamic_occupancy.cpp
    src/navigation_context.cpp
    src/grid_pathfinder.cpp
)
# grid_map_core 也会被链接进 Lua 动态模块，因此其目标文件必须可用于共享库。
set_target_properties(grid_map_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

target_include_directories(grid_map_core PUBLIC include)
target_compile_options(grid_map_core PRIVATE -Wall -Wextra -Wpedantic)

add_executable(grid_map_test tests/grid_map_test.cpp)
target_link_libraries(grid_map_test PRIVATE grid_map_core pthread)
target_compile_options(grid_map_test PRIVATE -UNDEBUG)

add_executable(navigation_test tests/navigation_test.cpp)
target_link_libraries(navigation_test PRIVATE grid_map_core pthread)
target_compile_options(navigation_test PRIVATE -Wall -Wextra -Wpedantic -UNDEBUG)

# 独立记录性能，不混入 CTest 正确性门禁；运行条件由操作者随结果保存。
add_executable(navigation_benchmark benchmark/navigation_benchmark.cpp)
target_link_libraries(navigation_benchmark PRIVATE grid_map_core pthread)
target_compile_options(navigation_benchmark PRIVATE -Wall -Wextra -Wpedantic)

enable_testing()
# 两个测试登记到 CTest；Benchmark 仅构建不自动跑，避免把耗时统计当正确性门禁。
add_test(NAME grid_map_test COMMAND grid_map_test)
add_test(NAME navigation_test COMMAND navigation_test)
