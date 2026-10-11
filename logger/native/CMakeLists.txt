# 职责：构建 Skynet Native Logger、隔离探针和文件测试；不启动业务进程。
# 调用方式：统一脚本用 -S logger/native、-B build/cmake/logger 配置。
# CMake 变量：${NAME} 不是系统环境变量；SKYNET_ROOT 和 FLYWOW_NATIVE_OUTPUT_DIR 由统一脚本通过 -D 传入。
# 输出：正式 Logger 进入 build/native；测试程序留在 build/cmake/logger。
# 修改指引：新增 Logger 源文件加到 flywow_logger；测试源文件加到对应 add_executable。
# 修改指引：改最终输出目录请改统一脚本的 NATIVE_DIR；本文件读取 FLYWOW_NATIVE_OUTPUT_DIR。
# 修改指引：新依赖先 find_package，再链接到使用它的目标；改 .so 名称时同步运行时加载名。
cmake_minimum_required(VERSION 3.10)
project(flywow_logger LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT EXISTS "${SKYNET_ROOT}/skynet-src/skynet.h")
    message(FATAL_ERROR "缺少固定版本 Skynet 头文件")
endif()
# MODULE 是运行时加载的 Logger；生产源文件集中列在这个目标。
add_library(flywow_logger MODULE service_logger.cpp log_sink.cpp)
target_include_directories(flywow_logger PRIVATE . "${SKYNET_ROOT}/skynet-src")
target_compile_options(flywow_logger PRIVATE -Wall -Wextra -Werror)
# 目标名供 target_* 命令引用；PREFIX 为空时生成 flywow_logger.so，目录由统一脚本的 -D 参数传入。
set_target_properties(flywow_logger PROPERTIES PREFIX "" LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}")
# 下面注册的测试由 CTest 执行，不会自动启动完整业务 Server。
enable_testing()
add_executable(flywow_logger_sink_test ../tests/log_sink_test.cpp log_sink.cpp)
target_include_directories(flywow_logger_sink_test PRIVATE .)
target_compile_options(flywow_logger_sink_test PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME flywow_logger_sink COMMAND flywow_logger_sink_test)

# Probe 是测试专用 Service，用于验证加载边界；产物留在 CMake 目录，不发布到运行时 Native 目录。
add_library(flywow_logger_probe_native MODULE ../tests/native_probe.cpp)
target_include_directories(flywow_logger_probe_native PRIVATE . "${SKYNET_ROOT}/skynet-src")
target_compile_options(flywow_logger_probe_native PRIVATE -Wall -Wextra -Werror)
set_target_properties(flywow_logger_probe_native PROPERTIES PREFIX "")
target_sources(flywow_logger PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../common/native/skynet_allocator.cpp")
# 在此 Native DSO 内绑定自定义 operator new/delete，避免被 libstdc++ 的实现抢先解析。
target_sources(flywow_logger_probe_native PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../common/native/skynet_allocator.cpp")
set_property(TARGET flywow_logger_probe_native APPEND_STRING PROPERTY LINK_FLAGS " -Wl,-Bsymbolic-functions")
set_property(TARGET flywow_logger APPEND_STRING PROPERTY LINK_FLAGS " -Wl,-Bsymbolic-functions")
