#!/usr/bin/env python3
"""Create a ZIP of the native downloads and optional unsigned iOS CI archive.

The ZIP is intended for short-lived GitHub Actions artifacts only. Native
GitHub Release assets remain separate installers/packages.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


FIXED_ASSETS = {
    "Airbridge-Android.apk",
    "Airbridge-Linux-x86_64.AppImage",
    "Airbridge-macOS.dmg",
}
WINDOWS_PREFIX = "Airbridge-Windows-Setup-"
OPTIONAL_ASSETS = {"Airbridge-iOS-unsigned.app.tar.gz"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def platform_assets(source_dir: Path) -> list[Path]:
    if not source_dir.is_dir():
        raise ValueError(f"Asset directory does not exist: {source_dir}")

    files = [path for path in source_dir.iterdir() if path.is_file()]
    windows = [
        path
        for path in files
        if path.name.startswith(WINDOWS_PREFIX) and path.suffix.lower() == ".exe"
    ]
    expected_names = FIXED_ASSETS | OPTIONAL_ASSETS | {path.name for path in windows}
    missing = FIXED_ASSETS - {path.name for path in files}
    unexpected = {
        path.name
        for path in files
        if path.name != "SHA256SUMS.txt" and path.name not in expected_names
    }
    if missing or len(windows) != 1 or unexpected:
        problems = []
        if missing:
            problems.append(f"missing {', '.join(sorted(missing))}")
        if len(windows) != 1:
            problems.append(
                f"expected one Windows installer, found {len(windows)}"
            )
        if unexpected:
            problems.append(f"unexpected files: {', '.join(sorted(unexpected))}")
        raise ValueError("Invalid platform asset set: " + "; ".join(problems))

    allowed_names = FIXED_ASSETS | OPTIONAL_ASSETS
    return sorted(
        [
            path
            for path in files
            if path.name in allowed_names or path in windows
        ],
        key=lambda path: path.name,
    )


def create_bundle(source_dir: Path, output_path: Path) -> None:
    assets = platform_assets(source_dir)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = "".join(f"{sha256(path)}  {path.name}\n" for path in assets)

    with ZipFile(output_path, "w", compression=ZIP_DEFLATED, compresslevel=6) as bundle:
        for path in assets:
            bundle.write(path, arcname=path.name)
        bundle.writestr("SHA256SUMS.txt", manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    create_bundle(args.assets_dir, args.output)
    print(f"Created {args.output}")


if __name__ == "__main__":
    main()
