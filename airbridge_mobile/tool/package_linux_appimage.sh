#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local status=$?
  local line="${1:-unknown}"
  local command="${2:-unknown command}"
  printf '::error::Linux AppImage packaging failed at line %s: %s (exit %s)\n' "$line" "$command" "$status" >&2
  exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output-directory>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE="$PROJECT_ROOT/build/linux/x64/release/bundle"
LOGO="$PROJECT_ROOT/assets/airbridge_logo.png"
OUTPUT_DIR="$1"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [[ ! -x "$BUNDLE/airbridge_mobile" ]]; then
  echo "Flutter Linux release executable not found: $BUNDLE/airbridge_mobile" >&2
  echo "Run 'flutter build linux --release' from airbridge_mobile first." >&2
  exit 1
fi
if [[ ! -s "$LOGO" ]]; then
  echo "Official Airbridge logo not found: $LOGO" >&2
  exit 1
fi

# Pin the packager and verify its digest so a moved release asset cannot silently
# replace the tool used to assemble user-facing binaries.
LINUXDEPLOY_VERSION="1-alpha-20251107-1"
LINUXDEPLOY_SHA256="c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT
APPDIR="$TEMP_ROOT/Airbridge.AppDir"
WORK_DIR="$TEMP_ROOT/package-output"
LINUXDEPLOY="$TEMP_ROOT/linuxdeploy-x86_64.AppImage"
mkdir -p "$APPDIR/usr/bin" "$WORK_DIR"

curl --fail --location --silent --show-error --retry 3 \
  --output "$LINUXDEPLOY" \
  "https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_VERSION}/linuxdeploy-x86_64.AppImage"
printf '%s  %s\n' "$LINUXDEPLOY_SHA256" "$LINUXDEPLOY" | sha256sum --check
chmod +x "$LINUXDEPLOY"
echo "linuxdeploy version:"
APPIMAGE_EXTRACT_AND_RUN=1 "$LINUXDEPLOY" --version
echo "linuxdeploy plugins:"
APPIMAGE_EXTRACT_AND_RUN=1 "$LINUXDEPLOY" --list-plugins

# Flutter locates its engine and data relative to the executable, so preserve
# the entire release bundle together under usr/bin (never ship only the runner).
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"
cp "$LOGO" "$APPDIR/airbridge.png"
ln -s usr/bin/airbridge_mobile "$APPDIR/airbridge_mobile"
cat > "$APPDIR/airbridge.desktop" <<'EOF'
[Desktop Entry]
Name=Airbridge
Comment=Discover and connect to Airbridge peers on your local network
Exec=airbridge_mobile
Icon=airbridge
Terminal=false
Type=Application
Categories=Network;Utility;
StartupWMClass=airbridge_mobile
EOF

# linuxdeploy collects the executable's shared-library dependencies and builds
# an AppImage. Extract-and-run avoids requiring FUSE on GitHub-hosted runners.
LINUXDEPLOY_LOG="$TEMP_ROOT/linuxdeploy.log"
if (
  trap - ERR
  cd "$WORK_DIR"
  APPIMAGE_EXTRACT_AND_RUN=1 "$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/airbridge_mobile" \
    --desktop-file "$APPDIR/airbridge.desktop" \
    --icon-file "$APPDIR/airbridge.png" \
    --output appimage
) >"$LINUXDEPLOY_LOG" 2>&1; then
  LINUXDEPLOY_STATUS=0
else
  LINUXDEPLOY_STATUS=$?
fi
cat "$LINUXDEPLOY_LOG"
if [[ "$LINUXDEPLOY_STATUS" -ne 0 ]]; then
  diagnostics="$(tail -n 8 "$LINUXDEPLOY_LOG" | tr '\n' ' ')"
  diagnostics="${diagnostics//'%'/'%25'}"
  diagnostics="${diagnostics//$'\r'/'%0D'}"
  diagnostics="${diagnostics//$'\n'/'%0A'}"
  printf '::error::linuxdeploy exited %s: %s\n' "$LINUXDEPLOY_STATUS" "$diagnostics"
  exit "$LINUXDEPLOY_STATUS"
fi

mapfile -t generated_images < <(find "$WORK_DIR" -maxdepth 1 -type f -name '*.AppImage' -print)
if [[ ${#generated_images[@]} -ne 1 ]]; then
  echo "Expected linuxdeploy to create exactly one AppImage; found ${#generated_images[@]}." >&2
  find "$WORK_DIR" -maxdepth 1 -type f -print >&2
  exit 1
fi

OUTPUT="$OUTPUT_DIR/Airbridge-Linux-x86_64.AppImage"
install -m 0755 "${generated_images[0]}" "$OUTPUT"
test -s "$OUTPUT"
echo "Created executable AppImage: $OUTPUT"
