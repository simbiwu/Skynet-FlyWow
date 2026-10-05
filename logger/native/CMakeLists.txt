# 职责：构建 C++14 Skynet Native Logger 与可注入时钟的文件测试；不启动业务进程。
# 输入固定 SKYNET_ROOT 与 FLYWOW_NATIVE_OUTPUT_DIR；中间产物归调用者指定构建目录。
cmake_minimum_required(VERSION 3.10)
project(flywow_logger LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT EXISTS "${SKYNET_ROOT}/skynet-src/skynet.h")
    message(FATAL_ERROR "缺少固定版本 Skynet 头文件")
endif()
add_library(flywow_logger MODULE src/service_logger.cpp src/log_sink.cpp)
target_include_directories(flywow_logger PRIVATE include "${SKYNET_ROOT}/skynet-src")
target_compile_options(flywow_logger PRIVATE -Wall -Wextra -Werror)
set_target_properties(flywow_logger PROPERTIES PREFIX "" LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}")
enable_testing()
add_executable(flywow_logger_sink_test ../tests/log_sink_test.cpp src/log_sink.cpp)
target_include_directories(flywow_logger_sink_test PRIVATE include)
target_compile_options(flywow_logger_sink_test PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME flywow_logger_sink COMMAND flywow_logger_sink_test)

# 测试 Service 仅输出到 CMake 目录，不能作为运行时模块发布。
add_library(flywow_logger_probe_native MODULE ../tests/native_probe.cpp)
target_include_directories(flywow_logger_probe_native PRIVATE include "${SKYNET_ROOT}/skynet-src")
target_compile_options(flywow_logger_probe_native PRIVATE -Wall -Wextra -Werror)
set_target_properties(flywow_logger_probe_native PROPERTIES PREFIX "")
