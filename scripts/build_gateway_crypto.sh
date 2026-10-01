#!/usr/bin/env bash
# 职责：把框架握手EVP绑定构建到宿主指定的luaclib目录。
# 边界：Build；参数为Skynet根和输出目录，要求OpenSSL 3 libcrypto开发文件、C++14编译器与pkg-config。
# 生命周期：生成一个.so；不下载、不升级依赖、不启动Server。
# 不负责：调用方指定固定Skynet；部署镜像固定OpenSSL包版本，不能静默使用其他Lua头。
set -euo pipefail
FRAMEWORK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SKYNET_ROOT="${1:?用法: build_gateway_crypto.sh SKYNET_ROOT OUTPUT_DIR}"
OUTPUT_DIR="${2:?缺少OUTPUT_DIR}"
[[ -f "$SKYNET_ROOT/3rd/lua/lua.h" ]] || { printf '缺少Skynet Lua头\n' >&2; exit 1; }
[[ "$(pkg-config --modversion libcrypto)" == 3.* ]] || { printf '要求OpenSSL 3 libcrypto\n' >&2; exit 1; }
mkdir -p -- "$OUTPUT_DIR"
BUILD_OUTPUT="$(mktemp "$OUTPUT_DIR/.gateway_crypto.XXXXXX")"
trap 'rm -f -- "$BUILD_OUTPUT"' EXIT
# 只选密码库libcrypto，不引入libssl；数组避免路径空格破坏显式目录参数。
read -r -a CRYPTO_FLAGS <<< "$(pkg-config --cflags --libs libcrypto)"
"${CXX:-c++}" -std=c++14 -O2 -Wall -Wextra -Werror -fPIC -shared \
    -I"$SKYNET_ROOT/3rd/lua" "$FRAMEWORK_ROOT/native/gateway_crypto/gateway_crypto.cpp" \
    "${CRYPTO_FLAGS[@]}" -o "$BUILD_OUTPUT"
chmod 755 "$BUILD_OUTPUT"
mv -f -- "$BUILD_OUTPUT" "$OUTPUT_DIR/flywow_gateway_crypto.so"
printf 'FLYWOW_GATEWAY_CRYPTO_BUILT libcrypto=%s\n' "$(pkg-config --modversion libcrypto)"
