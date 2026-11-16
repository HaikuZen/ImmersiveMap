#!/bin/sh
# Copyright (c) 2025-2026 ImmersiveMap contributors.
# SPDX-License-Identifier: MIT
#
# Builds the browser probe into Web/probe/build/: the ImmersiveMapWebProbe
# module for WebAssembly (the slim build, release, its debug information
# stripped) and the shader bundle. Then open the page through a local server,
# for a browser fetches nothing from a file:// page:
#
#   Web/probe/build.sh
#   python3 -m http.server --directory Web 8000
#   open http://localhost:8000/probe/
#
# Needs a Swift toolchain with the WebAssembly SDK named by WASM_SDK, and
# `npm ci` once in Tools/WGSLCheck.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
sdk=${WASM_SDK:-swift-6.4.2-RELEASE_wasm}
scratch=${SCRATCH_PATH:-$root/.build-wasm-probe}
output=$root/Web/probe/build

mkdir -p "$output"
IMMERSIVE_MAP_SLIM=1 swift build --package-path "$root" --build-system native --manifest-cache none --swift-sdk "$sdk" -c release \
    --product ImmersiveMapWebProbe --scratch-path "$scratch"
module=$(find "$scratch" -name ImmersiveMapWebProbe.wasm -ipath '*release*' | head -n 1)
if [ -z "$module" ]; then
    echo "error: no ImmersiveMapWebProbe.wasm under $scratch" >&2
    exit 1
fi
toolchain=$(dirname "$(command -v swift)")
"$toolchain/llvm-objcopy" --strip-debug "$module" "$output/ImmersiveMapWebProbe.wasm"
node "$root/Tools/WGSLCheck/bundle.mjs" "$output/shaders.json"
echo "built $output"
