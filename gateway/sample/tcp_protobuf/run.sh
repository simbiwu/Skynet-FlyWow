#!/usr/bin/env bash
# 将 Skynet 根目录参数原样传给统一样例入口；exec 让退出码和信号由该入口负责。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
exec bash "$SCRIPT_DIR/../run_gateway_sample.sh" protobuf "$@"
