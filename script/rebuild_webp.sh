#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
curl -fL https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz -o "$BUILD_DIR/source.tar.gz"
EXPECTED_SHA="e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
ACTUAL_SHA="$(shasum -a 256 "$BUILD_DIR/source.tar.gz" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || { echo 'WebP source checksum mismatch' >&2; exit 1; }
tar -xzf "$BUILD_DIR/source.tar.gz" -C "$BUILD_DIR"
cmake -S "$BUILD_DIR/libwebp-1.6.0" -B "$BUILD_DIR/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
cmake --build "$BUILD_DIR/build" --target webpdecoder webpdemux --parallel 4
chmod u+w "$ROOT_DIR"/Vendor/WebP/lib/*.a
cp "$BUILD_DIR/build/libwebpdecoder.a" "$BUILD_DIR/build/libwebpdemux.a" "$ROOT_DIR/Vendor/WebP/lib/"
cp "$BUILD_DIR/libwebp-1.6.0"/src/webp/{decode,demux,mux_types,types}.h "$ROOT_DIR/Vendor/WebP/include/webp/"
cp "$BUILD_DIR/libwebp-1.6.0/COPYING" "$ROOT_DIR/Resources/WebP-LICENSE.txt"
