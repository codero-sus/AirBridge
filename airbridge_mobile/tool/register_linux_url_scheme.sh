#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /absolute/path/to/Airbridge-Linux-x86_64.AppImage" >&2
  exit 2
fi

if ! command -v xdg-mime >/dev/null 2>&1; then
  echo "xdg-mime is required (install the xdg-utils package)." >&2
  exit 1
fi

APPIMAGE="$(realpath "$1")"
if [[ ! -f "$APPIMAGE" || ! -x "$APPIMAGE" ]]; then
  echo "Executable AppImage not found: $APPIMAGE" >&2
  exit 1
fi

escape_desktop_exec() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APPLICATIONS_DIR/airbridge.desktop"
mkdir -p "$APPLICATIONS_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Airbridge
Comment=Discover and connect to Airbridge peers on your local network
Exec=$(escape_desktop_exec "$APPIMAGE") %u
Icon=airbridge
Terminal=false
Type=Application
Categories=Network;Utility;
MimeType=x-scheme-handler/airbridge;
StartupWMClass=airbridge_mobile
EOF

xdg-mime default airbridge.desktop x-scheme-handler/airbridge
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPLICATIONS_DIR"
fi

echo "Registered airbridge:// URLs to open with: $APPIMAGE"
echo "To undo: xdg-mime uninstall $DESKTOP_FILE"
