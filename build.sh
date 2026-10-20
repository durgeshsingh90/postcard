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

# Runs on macOS 13 (Ventura) and later; the compiler rejects anything newer that isn't guarded.
MIN_MACOS=13.0

mkdir -p "$ROOT/build"
xcrun swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos$MIN_MACOS" \
  -framework AppKit \
  -framework CoreLocation \
  -framework MapKit \
  -o "$ROOT/build/postcard" \
  "$ROOT/Sources/main.swift"

echo "Built $ROOT/build/postcard"
