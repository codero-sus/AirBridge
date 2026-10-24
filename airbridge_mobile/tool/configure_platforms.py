#!/usr/bin/env python3
"""Apply Airbridge platform permissions, camera setup, deep links, and logo overlays."""

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


def update_linux_window_icon() -> None:
    runner = ROOT / "linux" / "runner" / "my_application.cc"
    if not runner.is_file():
        return
    text = runner.read_text()
    if "gtk_window_set_icon_from_file(window" in text:
        return
    marker = "GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));"
    if marker not in text:
        print("Linux runner template changed; skipped automatic window icon setup")
        return
    icon_setup = '''

  // Use the bundled official Airbridge logo as the native Linux window icon.
  g_autofree gchar* executable_path = g_file_read_link("/proc/self/exe", nullptr);
  if (executable_path != nullptr) {
    g_autofree gchar* executable_directory = g_path_get_dirname(executable_path);
    g_autofree gchar* logo_path = g_build_filename(
        executable_directory, "data", "flutter_assets", "assets",
        "airbridge_logo.png", nullptr);
    gtk_window_set_icon_from_file(window, logo_path, nullptr);
  }'''
    runner.write_text(text.replace(marker, marker + icon_setup, 1))
    print(f"configured {runner.relative_to(ROOT)} (official Airbridge window icon)")


def update_windows_app_link_support() -> None:
    header = ROOT / "windows" / "runner" / "win32_window.h"
    source = ROOT / "windows" / "runner" / "win32_window.cpp"
    if not header.is_file() or not source.is_file():
        return

    header_text = header.read_text()
    declaration = "bool ForwardAppLinkToRunningInstance(const std::wstring& title);"
    if declaration not in header_text:
        create_marker = re.compile(r"(bool CreateAndShow\([\s\S]*?;)")
        header_text, count = create_marker.subn(
            r"\1\n\n  " + declaration,
            header_text,
            count=1,
        )
        if not count:
            print("Windows runner header changed; single-instance URL forwarding was not declared")

    source_text = source.read_text()
    include = '#include "app_links/app_links_plugin_c_api.h"'
    if include not in source_text:
        include_marker = '#include "win32_window.h"'
        if include_marker in source_text:
            source_text = source_text.replace(
                include_marker,
                f"{include_marker}\n\n{include}",
                1,
            )
        else:
            print("Windows runner source changed; could not add the app_links API header")

    method_name = "ForwardAppLinkToRunningInstance"
    if method_name not in source_text:
        create_marker = re.compile(r"bool Win32Window::CreateAndShow\(")
        method = (
            "// Forward protocol activations instead of starting a second Airbridge node.\n"
            "bool Win32Window::ForwardAppLinkToRunningInstance("
            "const std::wstring& title) {\n"
            "  HWND existing_window = ::FindWindow(kWindowClassName, title.c_str());\n"
            "  if (existing_window == nullptr) {\n"
            "    return false;\n"
            "  }\n"
            "  SendAppLink(existing_window);\n"
            "  return true;\n"
            "}\n\n"
        )
        source_text, count = create_marker.subn(method + r"bool Win32Window::CreateAndShow(", source_text, count=1)
        if not count:
            print("Windows runner CreateAndShow changed; app-link forwarding was not implemented")

    call_marker = re.compile(r"(bool Win32Window::CreateAndShow\([\s\S]*?\)\s*\{)")
    if "ForwardAppLinkToRunningInstance(title)" not in source_text:
        source_text, count = call_marker.subn(
            r"\1\n  if (ForwardAppLinkToRunningInstance(title)) {\n"
            "    return false;\n"
            "  }\n",
            source_text,
            count=1,
        )
        if not count:
            print("Windows runner entry point changed; single-instance URL handling may need review")

    if header_text != header.read_text():
        header.write_text(header_text)
    if source_text != source.read_text():
        source.write_text(source_text)
        print(f"configured {source.relative_to(ROOT)} (single-instance custom URL forwarding)")


def update_linux_app_link_support() -> None:
    runner = ROOT / "linux" / "runner" / "my_application.cc"
    if not runner.is_file():
        return
    text = runner.read_text()
    updated = text.replace(
        "G_APPLICATION_NON_UNIQUE",
        "G_APPLICATION_HANDLES_COMMAND_LINE | G_APPLICATION_HANDLES_OPEN",
    )

    activate_pattern = re.compile(
        r"(static void my_application_activate\(GApplication\* application\)\s*\{"
        r"\s*MyApplication\* self = MY_APPLICATION\(application\);\s*)"
    )
    if "gtk_application_get_windows(GTK_APPLICATION(application))" not in updated:
        updated, count = activate_pattern.subn(
            r"\1\n  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));\n"
            "  if (windows != nullptr) {\n"
            "    gtk_window_present(GTK_WINDOW(windows->data));\n"
            "    return;\n"
            "  }\n",
            updated,
            count=1,
        )
        if not count:
            print("Linux runner activation changed; could not add single-instance app-link handling")

    local_command_pattern = re.compile(
        r"(static gboolean my_application_local_command_line\([\s\S]*?"
        r"g_application_activate\(application\);\s*"
        r"\*exit_status\s*=\s*0;\s*)return TRUE;"
    )
    local_command_handler_ready = re.search(
        r"g_application_activate\(application\);\s*"
        r"\*exit_status\s*=\s*0;\s*return FALSE;",
        updated,
    )
    if "g_application_activate(application);" in updated and not local_command_handler_ready:
        updated, count = local_command_pattern.subn(r"\1return FALSE;", updated, count=1)
        if not count:
            print("Linux runner command-line handler changed; app-link forwarding may need review")

    if updated != text:
        runner.write_text(updated)
        print(f"configured {runner.relative_to(ROOT)} (single-instance custom URL handling)")


def update_apple_info(values: dict) -> None:
    values["CFBundleDisplayName"] = "Airbridge"
    values["NSLocalNetworkUsageDescription"] = (
        "Airbridge discovers and exchanges data with peers on your local network."
    )
    values["NSBonjourServices"] = ["_airbridge._tcp"]
    values["NSCameraUsageDescription"] = (
        "Airbridge uses the camera only to scan a nearby device's one-time pairing QR."
    )
    url_types = values.setdefault("CFBundleURLTypes", [])
    if not any(
        scheme.lower() == "airbridge"
        for url_type in url_types
        for scheme in url_type.get("CFBundleURLSchemes", [])
    ):
        url_types.append(
            {
                "CFBundleURLName": "com.coderosus.airbridge_mobile",
                "CFBundleURLSchemes": ["airbridge"],
            }
        )
    transport = values.setdefault("NSAppTransportSecurity", {})
    transport["NSAllowsLocalNetworking"] = True
    # The app only uses cleartext for its configured local peer endpoints.
    # Use TLS if you add non-LAN endpoints.
    transport["NSAllowsArbitraryLoads"] = True


def update_ios_info(values: dict) -> None:
    update_apple_info(values)
    values["FlutterDeepLinkingEnabled"] = False


def update_ios_entitlements(values: dict) -> None:
    # Apple must approve this capability and the provisioning profile must include it.
    values["com.apple.developer.networking.multicast"] = True


def update_macos_entitlements(values: dict) -> None:
    values["com.apple.security.network.client"] = True
    values["com.apple.security.network.server"] = True
    values["com.apple.security.device.camera"] = True


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
    update_plist(ios_info, update_ios_info)
    ios_entitlements = ROOT / "ios" / "Runner" / "Runner.entitlements"
    update_plist(ios_entitlements, update_ios_entitlements, create_if_missing=True)
    update_ios_deployment_target()
    update_windows_app_link_support()
    update_linux_window_icon()
    update_linux_app_link_support()

    macos_info = ROOT / "macos" / "Runner" / "Info.plist"
    update_plist(macos_info, update_apple_info)
    for filename in ("DebugProfile.entitlements", "Release.entitlements"):
        update_plist(
            ROOT / "macos" / "Runner" / filename,
            update_macos_entitlements,
        )

    print("Airbridge platform networking, camera, and deep-link configuration is ready.")


if __name__ == "__main__":
    main()
