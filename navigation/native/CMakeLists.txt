# 职责：独立构建 FlyWow 地图、Grid 导航与可选 Lua Binding。
# 边界：Native Build；源码与 Skynet 路径显式分离，最终 Lua .so 统一写入 FlyWow/build/native。
# 输入：C++17 源码、可选 SKYNET_ROOT 和 FLYWOW_NATIVE_OUTPUT_DIR。
# 输出：CMake 中间文件、静态库、测试、Benchmark 和 Lua Native 模块。
# 不负责：不下载依赖、不加载游戏资产、不启动 Service。
cmake_minimum_required(VERSION 3.16)
project(flywow_navigation LANGUAGES CXX C)
enable_testing()
add_subdirectory(grid_map)
option(FLYWOW_NAVIGATION_LUA "构建与宿主 Skynet Lua ABI 一致的 Binding" OFF)
set(FLYWOW_NATIVE_OUTPUT_DIR "" CACHE PATH "FlyWow Lua Native .so 的统一输出目录")
if(FLYWOW_NAVIGATION_LUA)
    add_subdirectory(lua)
endif()
