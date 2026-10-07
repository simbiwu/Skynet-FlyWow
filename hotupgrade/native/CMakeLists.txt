# 职责：构建热更所需的小型文件/hash工具，不编译或替换业务 Native。
cmake_minimum_required(VERSION 3.16)
project(flywow_hotupgrade LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
find_package(OpenSSL 3 REQUIRED COMPONENTS Crypto)
if(NOT EXISTS "${SKYNET_ROOT}/3rd/lua/lua.h")
    message(FATAL_ERROR "HotUpgrade 需要固定 Skynet 自带 Lua 头文件")
endif()
if(NOT TARGET flywow_lua_binding)
    set(SKYNET_LUA_DIR "${SKYNET_ROOT}/3rd/lua")
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../lua-binding
        ${CMAKE_BINARY_DIR}/lua-binding EXCLUDE_FROM_ALL)
endif()
add_library(flywow_hotupgrade_native MODULE hotupgrade_native.cpp)
target_include_directories(flywow_hotupgrade_native PRIVATE "${SKYNET_ROOT}/3rd/lua")
target_include_directories(flywow_hotupgrade_native PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../lua-binding)
target_link_libraries(flywow_hotupgrade_native PRIVATE flywow_lua_binding OpenSSL::Crypto)
target_compile_options(flywow_hotupgrade_native PRIVATE -Wall -Wextra -Wpedantic -Werror)
set_target_properties(flywow_hotupgrade_native PROPERTIES
    PREFIX ""
    LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}"
)
target_sources(flywow_hotupgrade_native PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../common/native/skynet_allocator.cpp")
# 在此 Native DSO 内绑定自定义 operator new/delete，避免被 libstdc++ 的实现抢先解析。
set_property(TARGET flywow_hotupgrade_native APPEND_STRING PROPERTY LINK_FLAGS " -Wl,-Bsymbolic-functions")
