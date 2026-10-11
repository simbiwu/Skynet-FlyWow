# 职责：构建 WordFilter 核心、Lua Binding、单元测试及可选 Skynet 集成测试。
# 调用方式：scripts/build_flywow.sh <Skynet目录> word_filter 会传入此文件的配置。
# CMake 变量：${NAME} 不是系统环境变量；SKYNET_ROOT 和 FLYWOW_NATIVE_OUTPUT_DIR 由统一脚本通过 -D 传入。
# 输出：静态库和测试程序留在构建树；运行时 Native 进入统一 build/native。
# 修改指引：新增核心源文件更新 flywow_word_filter_core；新增 Binding 源文件更新 Native 目标。
# 修改指引：新增依赖先检查/声明，再链接到使用它的目标；改名同步脚本产物检查和 Lua 加载名。
# 修改指引：改最终 .so 输出目录请改统一脚本的 NATIVE_DIR；本文件通过 FLYWOW_NATIVE_OUTPUT_DIR 接收。
cmake_minimum_required(VERSION 3.16)
project(flywow_word_filter LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
enable_testing()
find_package(Threads REQUIRED)

# 核心不依赖 Lua/Skynet；新增核心 .cpp 在此登记，PIC 允许静态库链接进 Native .so。
add_library(flywow_word_filter_core STATIC word_filter.cpp)
set_target_properties(flywow_word_filter_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(flywow_word_filter_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_options(flywow_word_filter_core PRIVATE -Wall -Wextra -Werror)

# 固定使用 Skynet 自带 Lua ABI；不链接系统 Lua，由加载进程提供 Lua 符号。
if(NOT EXISTS "${SKYNET_ROOT}/3rd/lua/lua.h")
    message(FATAL_ERROR "word_filter 需要 Skynet 自带 Lua 头文件")
endif()
set(SKYNET_LUA_DIR "${SKYNET_ROOT}/3rd/lua")

# MODULE 是 Lua 动态适配层；业务过滤逻辑仍由静态核心实现。
add_library(flywow_word_filter_native MODULE lua_word_filter.cpp)
target_include_directories(flywow_word_filter_native PRIVATE "${SKYNET_ROOT}/3rd/lua")
if(NOT TARGET flywow_lua_binding)
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../lua-binding"
                     "${CMAKE_BINARY_DIR}/lua-binding" EXCLUDE_FROM_ALL)
endif()
target_link_libraries(flywow_word_filter_native PRIVATE flywow_word_filter_core flywow_lua_binding)
target_compile_options(flywow_word_filter_native PRIVATE -Wall -Wextra -Werror)
# PREFIX 和目标名共同决定 .so 名称；输出目录来自统一脚本的 -D 参数。
set_target_properties(flywow_word_filter_native PROPERTIES
    PREFIX ""
    LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}")

# 单元测试直接回归核心与只读并发，不需加载 Lua 或启动 Skynet。
add_executable(flywow_word_filter_test ../tests/test_word_filter.cpp)
target_link_libraries(flywow_word_filter_test PRIVATE flywow_word_filter_core Threads::Threads)
add_test(NAME flywow_word_filter_core COMMAND flywow_word_filter_test)


# 当前真实集成宿主为主仓库 server/；测试配置的相对路径以此目录为基准。
# Skynet 会正常 ABORT 退出，成功/失败标记与超时共同判断结果。
# 找到宿主 Skynet 才注册集成测试；配置中的相对路径以 Server 根目录为工作目录。
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
target_sources(flywow_word_filter_native PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../common/native/skynet_allocator.cpp")
# 在此 Native DSO 内绑定自定义 operator new/delete，避免被 libstdc++ 的实现抢先解析。
set_property(TARGET flywow_word_filter_native APPEND_STRING PROPERTY LINK_FLAGS " -Wl,-Bsymbolic-functions")
