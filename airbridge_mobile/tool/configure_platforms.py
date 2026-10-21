#!/usr/bin/env python3
"""Apply Airbridge's native networking permissions to Flutter-generated hosts."""

from __future__ import annotations

import plistlib
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "platform_templates"


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise SystemExit(f"Missing platform template: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    print(f"configured {destination.relative_to(ROOT)}")


def update_plist(path: Path, mutate, *, create_if_missing: bool = False) -> None:
    if not path.is_file() and not create_if_missing:
        raise SystemExit(
            f"Flutter host file not found: {path.relative_to(ROOT)}. "
            "Run tool/bootstrap_platforms.sh first."
        )
    if path.is_file():
        with path.open("rb") as stream:
            values = plistlib.load(stream)
    else:
        values = {}
    mutate(values)
    with path.open("wb") as stream:
        plistlib.dump(values, stream, sort_keys=False)
    print(f"configured {path.relative_to(ROOT)}")


IOS_MINIMUM_VERSION = "15.5"


def update_ios_deployment_target() -> None:
    podfile = ROOT / "ios" / "Podfile"
    if podfile.is_file():
        text = podfile.read_text()
        platform_line = f"platform :ios, '{IOS_MINIMUM_VERSION}'"
        platform_pattern = re.compile(
            r"(?m)^\s*#?\s*platform\s+:ios\s*,\s*['\"][^'\"]+['\"]\s*$"
        )
        if platform_pattern.search(text):
            text = platform_pattern.sub(platform_line, text, count=1)
        else:
            text = f"{platform_line}\n{text}"
        podfile.write_text(text)
        print(
            f"configured {podfile.relative_to(ROOT)} "
            f"(iOS {IOS_MINIMUM_VERSION} minimum)"
        )
    else:
        print("iOS Podfile not generated yet; deployment target will be reapplied after pub get")

    project = ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj"
    if project.is_file():
        project_text = project.read_text()
        project_text, replacements = re.subn(
            r"(IPHONEOS_DEPLOYMENT_TARGET\s*=\s*)[0-9.]+;",
            rf"\g<1>{IOS_MINIMUM_VERSION};",
            project_text,
        )
        if replacements:
            project.write_text(project_text)
            print(
                f"configured {project.relative_to(ROOT)} "
                f"(iOS {IOS_MINIMUM_VERSION} minimum)"
            )


def update_apple_info(values: dict) -> None:
    values["CFBundleDisplayName"] = "Airbridge"
    values["NSLocalNetworkUsageDescription"] = (
        "Airbridge discovers and exchanges data with peers on your local network."
    )
    values["NSBonjourServices"] = ["_airbridge._tcp"]
    values["NSCameraUsageDescription"] = (
        "Airbridge uses the camera only to scan a nearby device's one-time pairing QR."
    )
    transport = values.setdefault("NSAppTransportSecurity", {})
    transport["NSAllowsLocalNetworking"] = True
    # The app only uses cleartext for its configured local peer endpoints.
    # Use TLS if you add non-LAN endpoints.
    transport["NSAllowsArbitraryLoads"] = True


def update_ios_entitlements(values: dict) -> None:
    # Apple must approve this capability and the provisioning profile must include it.
    values["com.apple.developer.networking.multicast"] = True


def update_macos_entitlements(values: dict) -> None:
    values["com.apple.security.network.client"] = True
    values["com.apple.security.network.server"] = True


def main() -> None:
    copy_file(
        TEMPLATES / "android" / "AndroidManifest.xml",
        ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml",
    )
    copy_file(
        TEMPLATES / "android" / "network_security_config.xml",
        ROOT / "android" / "app" / "src" / "main" / "res" / "xml" / "network_security_config.xml",
    )
    copy_file(
        TEMPLATES / "android" / "MainActivity.kt",
        ROOT
        / "android"
        / "app"
        / "src"
        / "main"
        / "kotlin"
        / "com"
        / "coderosus"
        / "airbridge_mobile"
        / "MainActivity.kt",
    )

    ios_info = ROOT / "ios" / "Runner" / "Info.plist"
    update_plist(ios_info, update_apple_info)
    ios_entitlements = ROOT / "ios" / "Runner" / "Runner.entitlements"
    update_plist(ios_entitlements, update_ios_entitlements, create_if_missing=True)
    update_ios_deployment_target()

    macos_info = ROOT / "macos" / "Runner" / "Info.plist"
    update_plist(macos_info, update_apple_info)
    for filename in ("DebugProfile.entitlements", "Release.entitlements"):
        update_plist(
            ROOT / "macos" / "Runner" / filename,
            update_macos_entitlements,
        )

    print("Airbridge platform networking configuration is ready.")


if __name__ == "__main__":
    main()
