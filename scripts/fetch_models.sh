#!/usr/bin/env bash
# Fetches the vendored sherpa-onnx inference library and the local wake-word
# model weights. These are not committed to git (see .gitignore) — only this
# script and the license/provenance notes under Vendor/sherpa-onnx/ are.
#
# Sources and licenses (see macos/FridayCompanion/Vendor/sherpa-onnx/THIRD_PARTY_NOTICES.md
# for the full, verified breakdown):
#   - sherpa-onnx v1.13.6 (Apache-2.0)        https://github.com/k2-fsa/sherpa-onnx
#   - ONNX Runtime, bundled in the same release artifact (MIT)
#   - sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 (Apache-2.0 per
#     publisher's model card)                https://github.com/k2-fsa/sherpa-onnx/releases/tag/kws-models

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/macos/FridayCompanion/Vendor/sherpa-onnx"
RESOURCES_DIR="$ROOT/macos/FridayCompanion/Sources/FridayCompanionKit/Resources/sherpa-onnx-kws-model"

SHERPA_VERSION="v1.13.6"
SHERPA_ARCHIVE="sherpa-onnx-${SHERPA_VERSION}-osx-arm64-shared-lib.tar.bz2"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/${SHERPA_ARCHIVE}"

KWS_ARCHIVE="sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2"
KWS_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/${KWS_ARCHIVE}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Fetching sherpa-onnx shared libraries (${SHERPA_VERSION})"
curl -L --fail -o "$tmp/$SHERPA_ARCHIVE" "$SHERPA_URL"
mkdir -p "$VENDOR_DIR/lib"
tar -xjf "$tmp/$SHERPA_ARCHIVE" -C "$tmp"
find "$tmp" -name "libsherpa-onnx-c-api.dylib" -exec cp {} "$VENDOR_DIR/lib/" \;
find "$tmp" -name "libonnxruntime.dylib" -exec cp {} "$VENDOR_DIR/lib/" \;

echo "==> Fetching the local wake-word model (gigaspeech-3.3M KWS, int8)"
curl -L --fail -o "$tmp/$KWS_ARCHIVE" "$KWS_URL"
mkdir -p "$RESOURCES_DIR"
tar -xjf "$tmp/$KWS_ARCHIVE" -C "$tmp"
model_dir="$(find "$tmp" -maxdepth 1 -type d -name "sherpa-onnx-kws-*")"
cp "$model_dir/encoder.int8.onnx" "$RESOURCES_DIR/"
cp "$model_dir/decoder.int8.onnx" "$RESOURCES_DIR/"
cp "$model_dir/joiner.int8.onnx" "$RESOURCES_DIR/"
cp "$model_dir/tokens.txt" "$RESOURCES_DIR/"

echo "==> Done. Vendored libraries are in $VENDOR_DIR/lib, model weights in $RESOURCES_DIR"
