#!/usr/bin/env bash
# ==========================================================================
#  Granule launcher for Linux
#    ./run-linux.sh            run the game (installs LOVE if it's missing)
#    ./run-linux.sh build      make dist/granule.love (runs anywhere LOVE is installed)
#    ./run-linux.sh --software force software OpenGL (old GPUs / VMs)
# ==========================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME="$DIR/game"
RT="$DIR/runtime"
LOVE_VER="11.5"
APPIMAGE_URL="https://github.com/love2d/love/releases/download/${LOVE_VER}/love-${LOVE_VER}-x86_64.AppImage"

if [ "${1:-}" = "build" ]; then
  mkdir -p "$DIR/dist"
  rm -f "$DIR/dist/granule.love"
  if command -v zip >/dev/null; then
    (cd "$GAME" && zip -9 -q -r "$DIR/dist/granule.love" .)
  else
    python3 - "$GAME" "$DIR/dist/granule.love" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
  fi
  echo "Built: $DIR/dist/granule.love   (run with: love granule.love)"
  exit 0
fi

if [ "${1:-}" = "--software" ]; then export LIBGL_ALWAYS_SOFTWARE=1; fi

love_ok() {  # need LOVE 11.3+ (for ImageData:getFFIPointer)
  local v
  v="$("$@" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
  [ -n "$v" ] || return 1
  local major="${v%%.*}" minor="${v#*.}"
  [ "$major" -gt 11 ] || { [ "$major" -eq 11 ] && [ "$minor" -ge 3 ]; }
}

find_love() {
  if [ -x "$RT/squashfs-root/AppRun" ]; then echo "$RT/squashfs-root/AppRun"; return 0; fi
  if command -v love >/dev/null && love_ok love; then command -v love; return 0; fi
  return 1
}

install_with_pm() {
  echo "Trying to install LOVE with your package manager (sudo may ask for your password)..."
  if   command -v apt-get >/dev/null; then sudo apt-get update && sudo apt-get install -y love
  elif command -v dnf     >/dev/null; then sudo dnf install -y love
  elif command -v pacman  >/dev/null; then sudo pacman -S --needed --noconfirm love
  elif command -v zypper  >/dev/null; then sudo zypper --non-interactive install love
  else return 1; fi
}

install_appimage() {
  [ "$(uname -m)" = "x86_64" ] || { echo "The LOVE AppImage is x86_64 only."; return 1; }
  echo "Downloading portable LOVE ${LOVE_VER} AppImage..."
  mkdir -p "$RT"
  if command -v curl >/dev/null; then curl -fL -o "$RT/love.AppImage" "$APPIMAGE_URL" || return 1
  elif command -v wget >/dev/null; then wget -O "$RT/love.AppImage" "$APPIMAGE_URL" || return 1
  else echo "Need curl or wget."; return 1; fi
  chmod +x "$RT/love.AppImage"
  # extract once so FUSE isn't required
  (cd "$RT" && ./love.AppImage --appimage-extract >/dev/null) || return 1
  rm -f "$RT/love.AppImage"
}

LOVE="$(find_love)" || {
  install_with_pm || true
  LOVE="$(find_love)" || { install_appimage && LOVE="$(find_love)"; } || {
    echo "Could not get LOVE 11.3+. Install it from https://love2d.org and run this again."
    exit 1
  }
}

echo "Starting Granule with $LOVE"
exec "$LOVE" "$GAME"
