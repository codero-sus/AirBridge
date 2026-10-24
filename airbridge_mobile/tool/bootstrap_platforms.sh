#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter 3.27+ is required. Install Flutter and add it to PATH." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
SCAFFOLD="$TEMP_DIR/airbridge_mobile"

# Generate native host projects outside this source tree so flutter create
# cannot replace our hand-written lib/ or pubspec.yaml.
flutter create \
  --no-pub \
  --platforms=android,ios,linux,macos,windows \
  --org com.coderosus \
  --project-name airbridge_mobile \
  "$SCAFFOLD"

for platform in android ios linux macos windows; do
  if [[ ! -d "$ROOT/$platform" ]]; then
    cp -R "$SCAFFOLD/$platform" "$ROOT/$platform"
  fi
done
if [[ ! -f "$ROOT/.metadata" && -f "$SCAFFOLD/.metadata" ]]; then
  cp "$SCAFFOLD/.metadata" "$ROOT/.metadata"
fi

python3 tool/configure_platforms.py
flutter pub get
dart run flutter_launcher_icons
# Some Flutter/plugin combinations generate the Podfile during dependency resolution.
python3 tool/configure_platforms.py
