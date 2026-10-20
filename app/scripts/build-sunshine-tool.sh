#!/bin/bash
# Build gpucontrol-sunshine-tool (x86_64) for Intel macOS 15.0+.
# Nothing here runs on Linux — needs swiftc and the macOS SDK.
#
# Usage (from the resumed-driver worktree root, on macOS):
#   ./app/scripts/build-sunshine-tool.sh
#   ./app/scripts/build-sunshine-tool.sh /path/to/gpucontrol-sunshine-tool
#
# Exact compile (also what this script runs):
#   swiftc -parse-as-library -O -target x86_64-apple-macosx15.0 \
#     -framework Foundation -framework AppKit -framework CoreGraphics \
#     app/nvidia-card-control/nvidia-card-control/SunshineConfig.swift \
#     app/nvidia-card-control/nvidia-card-control/SunshineOptions.swift \
#     app/nvidia-card-control/nvidia-card-control/SunshineDisplays.swift \
#     app/sunshine-tool/main.swift \
#     -o gpucontrol-sunshine-tool
#
# Then copy into the app target folder next to nvmtlctl (File System Synchronized Root Group):
#   cp gpucontrol-sunshine-tool app/nvidia-card-control/nvidia-card-control/gpucontrol-sunshine-tool
#
# Copyright (c) 2026 BlueMonkey
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

CONFIG="$ROOT/app/nvidia-card-control/nvidia-card-control/SunshineConfig.swift"
OPTIONS="$ROOT/app/nvidia-card-control/nvidia-card-control/SunshineOptions.swift"
DISPLAYS="$ROOT/app/nvidia-card-control/nvidia-card-control/SunshineDisplays.swift"
MAIN="$ROOT/app/sunshine-tool/main.swift"
OUT=${1:-"$ROOT/app/sunshine-tool/gpucontrol-sunshine-tool"}
mkdir -p "$(dirname "$OUT")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "build-sunshine-tool: swiftc not found (macOS SDK required)" >&2
  exit 2
fi

swiftc -parse-as-library -O -target x86_64-apple-macosx15.0 \
  -framework Foundation -framework AppKit -framework CoreGraphics \
  "$CONFIG" \
  "$OPTIONS" \
  "$DISPLAYS" \
  "$MAIN" \
  -o "$OUT"

chmod +x "$OUT"
echo "built $OUT (x86_64, macosx15.0); copy next to nvmtlctl in the app bundle Resources folder"
