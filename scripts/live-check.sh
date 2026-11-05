#!/bin/zsh
# usage: SDM_HOST=<monitor ip> SDM_TOKEN=<token> scripts/live-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/live-check; mkdir -p "$OUT"
swiftc -parse-as-library -swift-version 6 -module-name DisplayMateCore -emit-module -emit-library -o "$OUT/libDisplayMateCore.dylib" -emit-module-path "$OUT/DisplayMateCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libDisplayMateCore.dylib Sources/Core/*.swift
swiftc -parse-as-library -swift-version 6 -I "$OUT" -L "$OUT" -lDisplayMateCore -Xlinker -rpath -Xlinker "$PWD/$OUT" Tools/LiveCheck.swift -o "$OUT/live-check"
"$OUT/live-check"
