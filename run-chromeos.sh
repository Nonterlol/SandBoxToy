#!/usr/bin/env bash
# ==========================================================================
#  Granule launcher for ChromeOS (Chromebooks)
#
#  ChromeOS runs Linux apps in its built-in Linux container ("Crostini").
#  One-time setup:  Settings > About ChromeOS > Developers >
#                   Linux development environment > Turn on
#  Then, in the Files app, move the Granule folder into "Linux files",
#  open the Terminal app and run:
#
#     bash ~/granule/run-chromeos.sh
#
#  The first run installs LOVE and adds Granule to your app launcher.
#  Options:  --software   force software rendering if the window is black/crashes
# ==========================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME="$DIR/game"

if [ ! -e /dev/.cros_milestone ] && [ "$(hostname)" != "penguin" ]; then
  echo "Note: this doesn't look like the ChromeOS Linux container; continuing anyway."
fi
if ! command -v apt-get >/dev/null; then
  echo "apt-get not found. This script expects the default Debian-based ChromeOS Linux container."
  exit 1
fi

if ! command -v love >/dev/null; then
  echo "Installing LOVE (one time, sudo needs no password in the ChromeOS container)..."
  sudo apt-get update && sudo apt-get install -y love || {
    echo "Installing LOVE failed. Check that Linux has network access and try again."; exit 1; }
fi

# Add a launcher icon so Granule shows up in the ChromeOS app list.
APPS="$HOME/.local/share/applications"
DESKTOP="$APPS/granule.desktop"
if [ ! -f "$DESKTOP" ]; then
  mkdir -p "$APPS"
  cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Granule
Comment=Falling sand sandbox
Exec=bash "$DIR/run-chromeos.sh"
Terminal=false
Categories=Game;
EOF
  echo "Added 'Granule' to your ChromeOS launcher (Linux apps folder)."
fi

if [ "${1:-}" = "--software" ]; then export LIBGL_ALWAYS_SOFTWARE=1; fi
exec love "$GAME"
