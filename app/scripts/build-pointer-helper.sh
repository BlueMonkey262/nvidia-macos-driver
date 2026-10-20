#!/bin/bash
# Build gpucontrol-pointerhelper (x86_64) for Intel macOS 15.0+.
# Nothing here runs on Linux — needs swiftc and the macOS SDK.
#
# Usage (from the resumed-driver worktree root, on macOS):
#   ./app/scripts/build-pointer-helper.sh
#   ./app/scripts/build-pointer-helper.sh /path/to/gpucontrol-pointerhelper
#
# Exact compile (also what this script runs):
#   swiftc -parse-as-library -O -target x86_64-apple-macosx15.0 \
#     -framework Foundation -framework CoreGraphics -framework ApplicationServices \
#     app/nvidia-card-control/nvidia-card-control/PointerNudgeLogic.swift \
#     app/pointer-helper/main.swift \
#     -o gpucontrol-pointerhelper
#
# Then copy into the app target folder next to nvmtlctl (File System Synchronized Root Group):
#   cp gpucontrol-pointerhelper app/nvidia-card-control/nvidia-card-control/gpucontrol-pointerhelper
#
# Copyright (c) 2026 BlueMonkey
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

LOGIC="$ROOT/app/nvidia-card-control/nvidia-card-control/PointerNudgeLogic.swift"
MAIN="$ROOT/app/pointer-helper/main.swift"
OUT=${1:-"$ROOT/app/pointer-helper/gpucontrol-pointerhelper"}
mkdir -p "$(dirname "$OUT")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "build-pointer-helper: swiftc not found (macOS SDK required)" >&2
  exit 2
fi

swiftc -parse-as-library -O -target x86_64-apple-macosx15.0 \
  -framework Foundation -framework CoreGraphics -framework ApplicationServices \
  "$LOGIC" \
  "$MAIN" \
  -o "$OUT"

chmod +x "$OUT"
echo "built $OUT (x86_64, macosx15.0); copy next to nvmtlctl in the app bundle Resources folder"
