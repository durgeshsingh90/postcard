#!/usr/bin/env bash
# Builds ./build/postcard with the Xcode Command Line Tools Swift compiler.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This builds a macOS binary; run it on your Mac." >&2; exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the Command Line Tools first:  xcode-select --install" >&2
  exit 1
fi

mkdir -p "$ROOT/build"
xcrun swiftc -O -swift-version 5 \
  -framework AppKit \
  -o "$ROOT/build/postcard" \
  "$ROOT/Sources/main.swift"

echo "Built $ROOT/build/postcard"
