#!/usr/bin/env bash
# Aquabyte installer for macOS
set -eu
DIR="$HOME/aquabyte"
REPO="chaympress/aquabyte"
VERSION="v0.1.1"
TARBALL="https://github.com/$REPO/releases/download/$VERSION/aquabyte.tar.gz"

echo ""
echo "  🧴 Installing Aquabyte"
echo ""

if ! command -v python3 >/dev/null 2>&1; then
  echo "  ✗ python3 not found."
  echo "    Run this first:  xcode-select --install"
  exit 1
fi

echo "  · downloading..."
TMP=$(mktemp -d)
curl -fsSL "$TARBALL" -o "$TMP/a.tgz"
mkdir -p "$DIR"
tar xzf "$TMP/a.tgz" -C "$DIR" --strip-components=1
rm -rf "$TMP"

if ! command -v swiftc >/dev/null 2>&1; then
  echo ""
  echo "  ✗ swiftc (Swift compiler) not found."
  echo "    Run this to install the Command Line Tools (5-10 min):"
  echo ""
  echo "      xcode-select --install"
  echo ""
  echo "    Then run this installer again."
  exit 1
fi

echo "  · compiling the widget (10-20 seconds)..."
cd "$DIR"
if ! swiftc -O -framework Cocoa -framework WebKit swift/pet.swift -o aquabyte-pet 2>/tmp/aquabyte-build.log; then
  echo "  ✗ Build failed. Please copy the lines below and report them:"
  sed -n '1,20p' /tmp/aquabyte-build.log
  exit 1
fi

echo ""
echo "  ✓ Installed"
echo "    · The bottle appears in the bottom-right corner (frameless, always on top)"
echo "    · Move: drag the bottle"
echo "    · Close: hover, then click ✕"
echo "    · Stop: press Ctrl+C in this window"
echo ""
exec "$DIR/aquabyte-pet"
