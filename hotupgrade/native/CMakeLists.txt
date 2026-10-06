# 职责：构建热更所需的小型文件/hash工具，不编译或替换业务 Native。
cmake_minimum_required(VERSION 3.16)
project(flywow_hotupgrade LANGUAGES C)
find_package(OpenSSL 3 REQUIRED COMPONENTS Crypto)
if(NOT EXISTS "${SKYNET_ROOT}/3rd/lua/lua.h")
    message(FATAL_ERROR "HotUpgrade 需要固定 Skynet 自带 Lua 头文件")
endif()
add_library(flywow_hotupgrade_native MODULE hotupgrade_native.c)
target_include_directories(flywow_hotupgrade_native PRIVATE "${SKYNET_ROOT}/3rd/lua")
target_link_libraries(flywow_hotupgrade_native PRIVATE OpenSSL::Crypto)
target_compile_options(flywow_hotupgrade_native PRIVATE -Wall -Wextra -Werror)
set_target_properties(flywow_hotupgrade_native PROPERTIES
    PREFIX ""
    LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}"
)
