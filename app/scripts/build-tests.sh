#!/bin/bash
# Build the app's test resources on macOS; run from any directory.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/app/nvidia-card-control/nvidia-card-control/Tests"
[ "$(uname -s)" = Darwin ] || { echo 'build-tests: macOS with Xcode or command line tools is required' >&2; exit 1; }
CLANG=$(xcrun --find clang)
SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$OUT"
# Keep binaries extensionless so the synchronized Xcode folder treats them as resources.
for source in "$ROOT/tools/nvenc_matrix.m" "$ROOT/tools/nvenc_gpu_load.m" \
              "$ROOT/tools/encoder_bringup.m" "$ROOT/tools/gpu_compute_check.m" \
              "$ROOT"/tools/test_metal_*.m; do
  name=$(basename "$source" .m)
  echo "Building $name (x86_64)"
  "$CLANG" -arch x86_64 -isysroot "$SDK" -fobjc-arc -O1 "$source" -o "$OUT/$name" \
    -framework Foundation -framework Metal -framework VideoToolbox -framework CoreMedia -framework CoreVideo
  chmod 755 "$OUT/$name"
done
[ -r "$OUT/manifest.tsv" ] || { echo 'build-tests: manifest.tsv missing' >&2; exit 1; }
echo "Built test resources in $OUT"
