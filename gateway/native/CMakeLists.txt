# 职责：仅构建供 Skynet Lua require 加载的 flywow_gateway_crypto.so。
# 边界：不构建 Gateway Lua Service、客户端 SDK 或协议工具；Native 模块由 Skynet 宿主加载。
# 调用：FlyWow scripts/build_flywow.sh 配置本文件；SKYNET_ROOT 与 FLYWOW_NATIVE_OUTPUT_DIR 通过 -D 传入。
# 输入：Skynet 固定 Lua 头文件、FlyWow Lua Binding、OpenSSL 3 Crypto 及下列 C++ 源码。
# 输出：中间文件留在 CMake 构建目录；链接成功后原子发布到 build/native/flywow_gateway_crypto.so。
# 修改：改源码列表更新 add_library；改依赖同步更新 find_package/target_link_libraries。
# 修改：改 .so 名称/目录时检查 build_flywow.sh、Gateway lua_cpath 和 Lua require 名称。
cmake_minimum_required(VERSION 3.16)
project(flywow_gateway_crypto LANGUAGES CXX)

# project() 初始化工具链后才检查目标平台；本模块使用 Linux Skynet Lua ABI 和 ELF 选项。
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "flywow_gateway_crypto requires Linux and the Skynet Lua ABI")
endif()

# 使用标准 C++17，关闭编译器扩展。
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# 固定使用宿主 Skynet 子模块自带的 Lua 头文件，避免系统 Lua ABI 混入。
if(NOT DEFINED SKYNET_ROOT OR SKYNET_ROOT STREQUAL "")
    message(FATAL_ERROR "SKYNET_ROOT must point to the host Skynet source directory")
endif()
set(SKYNET_LUA_DIR "${SKYNET_ROOT}/3rd/lua")
if(NOT EXISTS "${SKYNET_LUA_DIR}/lua.h")
    message(FATAL_ERROR "Skynet bundled Lua headers not found: ${SKYNET_LUA_DIR}")
endif()

# 握手算法使用 OpenSSL EVP；Crypto 组件提供 OpenSSL::Crypto 链接目标。
find_package(OpenSSL 3.0 REQUIRED COMPONENTS Crypto)

# 统一入口传入 Lua 运行时搜索的正式产物目录；要求绝对路径，避免依赖调用目录。
if(NOT DEFINED FLYWOW_NATIVE_OUTPUT_DIR OR FLYWOW_NATIVE_OUTPUT_DIR STREQUAL "")
    message(FATAL_ERROR "FLYWOW_NATIVE_OUTPUT_DIR must name the final Native output directory")
endif()
if(NOT IS_ABSOLUTE "${FLYWOW_NATIVE_OUTPUT_DIR}")
    message(FATAL_ERROR "FLYWOW_NATIVE_OUTPUT_DIR must be an absolute path")
endif()
file(MAKE_DIRECTORY "${FLYWOW_NATIVE_OUTPUT_DIR}")

# Lua C API 封装由静态目标提供，不在 Gateway 目标中重复列举 Binding 源文件。
# EXCLUDE_FROM_ALL 阻止其作为无关顶层目标单独构建；链接依赖仍会构建该静态库。
add_subdirectory(
    "${CMAKE_CURRENT_LIST_DIR}/../../lua-binding"
    "${CMAKE_CURRENT_BINARY_DIR}/flywow_lua_binding"
    EXCLUDE_FROM_ALL
)

# MODULE 生成 Lua 可加载的共享模块，不是服务进程或可执行程序。
# allocator 按既有 ABI 合同编入同一 DSO；Binding 源码由上面的静态目标提供。
add_library(flywow_gateway_crypto MODULE
    gateway_crypto/gateway_crypto.cpp
    "${CMAKE_CURRENT_LIST_DIR}/../../common/native/skynet_allocator.cpp"
)

# Binding 的头文件目录由链接目标传递；密码学实现链接 OpenSSL Crypto。
target_link_libraries(flywow_gateway_crypto PRIVATE
    flywow_lua_binding
    OpenSSL::Crypto
)

# 使用 C++17，并将 GCC/Clang 编译警告视为错误。
target_compile_features(flywow_gateway_crypto PRIVATE cxx_std_17)
target_compile_options(flywow_gateway_crypto PRIVATE -Wall -Wextra -Werror)

# 在本 DSO 内解析 allocator 符号，避免 ELF 加载时被进程中的同名实现抢先绑定。
target_link_options(flywow_gateway_crypto PRIVATE "-Wl,-Bsymbolic-functions")

# 输出名不带 lib 前缀，符合 Lua require 模块名；先写入构建目录的中间位置。
set(FLYWOW_GATEWAY_MODULE_DIR "${CMAKE_CURRENT_BINARY_DIR}/module")
set_target_properties(flywow_gateway_crypto PROPERTIES
    PREFIX ""
    OUTPUT_NAME "flywow_gateway_crypto"
    LIBRARY_OUTPUT_DIRECTORY "${FLYWOW_GATEWAY_MODULE_DIR}"
)

# 不同 CMake 构建目录生成不同临时发布名，避免独立构建争用同一个暂存文件。
string(SHA256 FLYWOW_GATEWAY_BUILD_HASH "${CMAKE_BINARY_DIR}")
string(SUBSTRING "${FLYWOW_GATEWAY_BUILD_HASH}" 0 12 FLYWOW_GATEWAY_BUILD_TOKEN)
set(FLYWOW_GATEWAY_FINAL_OUTPUT "${FLYWOW_NATIVE_OUTPUT_DIR}/flywow_gateway_crypto.so")
set(FLYWOW_GATEWAY_TEMP_OUTPUT
    "${FLYWOW_NATIVE_OUTPUT_DIR}/.flywow_gateway_crypto.${FLYWOW_GATEWAY_BUILD_TOKEN}.tmp")

# 默认构建先完整链接模块，再复制到同目录临时文件并重命名为正式产物。
# 新文件准备完成前保留旧文件，避免服务进程读到写到一半的 .so。
add_custom_target(flywow_gateway_publish ALL
    COMMAND "${CMAKE_COMMAND}" -E copy
            "$<TARGET_FILE:flywow_gateway_crypto>" "${FLYWOW_GATEWAY_TEMP_OUTPUT}"
    COMMAND "${CMAKE_COMMAND}" -E rename
            "${FLYWOW_GATEWAY_TEMP_OUTPUT}" "${FLYWOW_GATEWAY_FINAL_OUTPUT}"
    DEPENDS flywow_gateway_crypto
    COMMENT "Publishing flywow_gateway_crypto.so to the FlyWow Native directory"
    VERBATIM
)
