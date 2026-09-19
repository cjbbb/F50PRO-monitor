#!/bin/bash
# 生成 App 图标：./scripts/make_icon.sh [A|B|C]
#   A 用量环（默认）  B 信号柱  C 随身路由
set -e
cd "$(dirname "$0")/.."
VARIANT="${1:-A}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O scripts/make_icon.swift -o "$WORK/make_icon"
"$WORK/make_icon" "$VARIANT" "$WORK/icon_1024.png" >/dev/null

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Sources/F50Monitor/AppIcon.icns
echo "✅ 已生成 Sources/F50Monitor/AppIcon.icns（方案 ${VARIANT}）"
