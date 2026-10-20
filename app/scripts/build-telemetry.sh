#!/bin/bash
# Build tools/gpu_telemetry (x86_64) against NVIDIA open-gpu-kernel-modules 610.57.04 headers.
# The helper must sit next to nvmtlctl (CLI resolves "$(dirname "$0")/gpu_telemetry").
#
# Usage (from the resumed-driver worktree root):
#   R=/path/to/NVIDIA-open-gpu-kernel-modules-<prefix> ./app/scripts/build-telemetry.sh
#   ./app/scripts/build-telemetry.sh   # uses $R, or .scratch/telemetry/NVIDIA-open-gpu-kernel-modules-* if present
#
# Fetch headers once (same as the telemetry research report):
#   mkdir -p .scratch/telemetry
#   gh api repos/NVIDIA/open-gpu-kernel-modules/tarball/610.57.04 > .scratch/telemetry/r610.tar.gz
#   tar -xzf .scratch/telemetry/r610.tar.gz -C .scratch/telemetry
#   R="$PWD/.scratch/telemetry/NVIDIA-open-gpu-kernel-modules-8d90872"
#
# Exact compile (also what this script runs):
#   clang -fobjc-arc -Wall -Wextra -arch x86_64 \
#     -framework Foundation -framework IOKit \
#     -I"$R/src/common/sdk/nvidia/inc" \
#     -I"$R/src/nvidia/arch/nvalloc/unix/include" \
#     tools/gpu_telemetry.m -o tools/gpu_telemetry
#
# Then copy into the app target folder next to nvmtlctl (File System Synchronized Root Group picks it up):
#   cp tools/gpu_telemetry app/nvidia-card-control/nvidia-card-control/gpu_telemetry
#   cp tools/nvmtlctl app/nvidia-card-control/nvidia-card-control/nvmtlctl   # keep byte-identical
#
# Copyright (c) 2026 BlueMonkey
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

if [ -z "${R:-}" ]; then
  for candidate in "$ROOT"/.scratch/telemetry/NVIDIA-open-gpu-kernel-modules-*; do
    if [ -d "$candidate/src/common/sdk/nvidia/inc" ]; then
      R=$candidate
      break
    fi
  done
fi

[ -n "${R:-}" ] || {
  echo "build-telemetry: set R to an NVIDIA open-gpu-kernel-modules 610.57.04 source root" >&2
  exit 2
}
[ -d "$R/src/common/sdk/nvidia/inc" ] || {
  echo "build-telemetry: missing headers under $R/src/common/sdk/nvidia/inc" >&2
  exit 2
}

OUT=${1:-"$ROOT/tools/gpu_telemetry"}
mkdir -p "$(dirname "$OUT")"

clang -fobjc-arc -Wall -Wextra -arch x86_64 \
  -framework Foundation -framework IOKit \
  -I"$R/src/common/sdk/nvidia/inc" \
  -I"$R/src/nvidia/arch/nvalloc/unix/include" \
  "$ROOT/tools/gpu_telemetry.m" -o "$OUT"

echo "built $OUT (x86_64); copy next to nvmtlctl in the app bundle Resources folder"
