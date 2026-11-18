#!/bin/sh
# Copyright (c) 2025-2026 Artem Bobkin.
# SPDX-License-Identifier: MIT
#
# Builds the map page into Web/map/build/: the ImmersiveMapWebMap module for
# WebAssembly (the slim build, release, its debug information stripped), the
# shader bundle, and the engine's resources (the text atlases, the overview
# archive, the tree model) with their list. Then open the page through a
# local server, for a browser fetches nothing from a file:// page:
#
#   Web/map/build.sh
#   python3 -m http.server --directory Web 8000
#   open http://localhost:8000/map/
#
# The page reads the engine's own tile archive unless `?archive=<url>` names
# another. The archive's host must allow the page's origin (CORS): send
# Access-Control-Allow-Origin, and expose ETag and Content-Range for the
# client's checks (Access-Control-Expose-Headers). Where it does not, serve
# the archive from the page's own site and name it by path, which needs no
# permission:
#
#   cp planet.pmtiles Web/
#   open http://localhost:8000/map/?archive=/planet.pmtiles
#
# The page says when the archive's requests fail. Needs a Swift
# toolchain with the WebAssembly SDK named by WASM_SDK, and `npm ci` once in
# Tools/WGSLCheck.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
sdk=${WASM_SDK:-swift-6.4.2-RELEASE_wasm}
scratch=${SCRATCH_PATH:-$root/.build-wasm-map}
output=$root/Web/map/build
engine=$root/Sources/ImmersiveMap

mkdir -p "$output/resources"
IMMERSIVE_MAP_SLIM=1 swift build --package-path "$root" --build-system native --manifest-cache none --swift-sdk "$sdk" -c release \
    --product ImmersiveMapWebMap --scratch-path "$scratch"
module=$(find "$scratch" -name ImmersiveMapWebMap.wasm -ipath '*release*' | head -n 1)
if [ -z "$module" ]; then
    echo "error: no ImmersiveMapWebMap.wasm under $scratch" >&2
    exit 1
fi
# The toolchain's objcopy, beside swift or on the path. Without one the
# module keeps its debug information, larger but the same program.
objcopy=$(dirname "$(command -v swift)")/llvm-objcopy
[ -x "$objcopy" ] || objcopy=$(command -v llvm-objcopy || true)
if [ -n "$objcopy" ]; then
    "$objcopy" --strip-debug "$module" "$output/ImmersiveMapWebMap.wasm"
else
    echo "warning: no llvm-objcopy, the module keeps its debug information" >&2
    cp "$module" "$output/ImmersiveMapWebMap.wasm"
fi
node "$root/Tools/WGSLCheck/bundle.mjs" "$output/shaders.json"

# The resources, flat, as the engine looks them up by name.
cp "$engine"/Text/Resources/* "$engine/Tile/Overview/Resources/overview.pmtiles" \
    "$engine/Tile/Trees/Resources/tree_broadleaf.immtree" "$output/resources/"
(cd "$output/resources" && ls | grep -v '^resources.json$' \
    | awk 'BEGIN { printf "[" } { printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 } END { print "]" }' > resources.json)
echo "built $output"
