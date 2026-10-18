#!/bin/bash
# Build the macOS measurement tools in this directory. Does not install anything.
# usage: ./build_all.sh
#   Binaries land in ./out/. Each one is also wrapped as ./out/<name>.app,
#   ad-hoc signed, so TCC can grant Screen Recording and `open -a` runs it in
#   the GUI session. An ssh-launched bare binary has no such grant.
# macOS only (clang, codesign). This script is not runnable on Linux.
set -eu
cd "$(dirname "$0")"
OUT=out
mkdir -p "$OUT"

# wrap_app <name> [capture]
# capture=1 adds the Screen Recording usage string. The bundle id is local.vmbench.<name>.
wrap_app() {
  local name="$1" cap="${2:-0}"
  local app="$OUT/$name.app" extra=""
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$OUT/$name" "$app/Contents/MacOS/$name"
  if [ "$cap" = 1 ]; then
    extra="  <key>NSScreenCaptureUsageDescription</key>
  <string>Measures how the display is captured. Frames stay on this machine.</string>
"
  fi
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>local.vmbench.${name}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.3</string>
${extra}</dict>
</plist>
EOF
  codesign -f -s - "$app"
}

clang -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/cadence" cadence.c
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dgl" dgl.m -framework Cocoa -framework OpenGL
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dpres" dpres.m -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dcap" dcap.m -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework QuartzCore
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dlat" dlat.m -framework Cocoa -framework AVFoundation -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreMedia
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dlat2" dlat2.m -framework Cocoa -framework AVFoundation -framework ScreenCaptureKit -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreMedia
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dsck" dsck.m -framework Cocoa -framework ScreenCaptureKit -framework QuartzCore -framework CoreMedia -framework CoreVideo
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/aaedge" aaedge.m -framework Foundation -framework Metal
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/minify" minify.m -framework Foundation -framework Metal -framework MetalPerformanceShaders
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/cilanczos" cilanczos.m -framework Foundation -framework CoreImage -framework Metal -framework CoreGraphics
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/fcon" fcon.m -framework Foundation -framework Metal
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/skylib" skylib.m -framework Foundation -framework Metal
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/skymip" skymip.m -framework Foundation -framework Metal
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/encq" encq.m -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/qualprobe" qualprobe.m -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal -framework ImageIO -framework CoreGraphics
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dnoise" dnoise.m -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dscale" dscale.m -framework Cocoa -framework QuartzCore -framework CoreGraphics
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dlink" dlink.m -framework Foundation -framework CoreVideo -framework CoreGraphics
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dshot" dshot.m -framework Cocoa -framework ScreenCaptureKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/cpuicon" cpuicon.m -framework Cocoa
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/dbar" dbar.m -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/blendbench" blendbench.m -framework Foundation -framework Metal
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/tearpng" tearpng.m -framework Foundation -framework ImageIO -framework CoreGraphics
TEAR_FW="-framework Cocoa -framework Metal -framework QuartzCore -framework OpenGL -framework ScreenCaptureKit -framework CoreVideo -framework CoreMedia"
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/tearscan" tearscan.m $TEAR_FW
# The same program as a dylib that capture-host loads: macOS ties the Screen Recording grant to the host binary, so the
# experiment can be rebuilt without granting again.
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -Dmain=probe_main -dynamiclib -o "$OUT/probe.dylib" tearscan.m $TEAR_FW
clang -O2 -Wall -Wno-deprecated-declarations -DGL_SILENCE_DEPRECATION -o "$OUT/capture-host" probehost.c

wrap_app cadence
wrap_app dgl
wrap_app dpres
wrap_app dcap 1
wrap_app dlat 1
wrap_app dlat2 1
wrap_app dsck 1
wrap_app aaedge
wrap_app minify
wrap_app cilanczos
wrap_app fcon
wrap_app skylib
wrap_app skymip
wrap_app encq
wrap_app qualprobe
wrap_app dnoise
wrap_app dscale
wrap_app dlink
wrap_app dshot 1
wrap_app cpuicon
wrap_app dbar
wrap_app blendbench
wrap_app tearscan 1
wrap_app capture-host 1

echo "built $OUT/*.app"
