#!/usr/bin/env python3
"""Build the distributable OneMd.app with SwiftPM and an ad-hoc signature."""

from __future__ import annotations

import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
APP_NAME = "OneMd"
BUNDLE_ID = "local.mdos.app"
OUTPUT_DIR = PROJECT_DIR / "build"
APP_DIR = OUTPUT_DIR / f"{APP_NAME}.app"


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("+", " ".join(cmd))
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        raise SystemExit(result.returncode)


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    run(["swift", "build", "-c", "release", "--product", APP_NAME], cwd=PROJECT_DIR)

    bin_path = PROJECT_DIR / ".build/release" / APP_NAME
    if not bin_path.is_file():
        raise SystemExit(f"missing binary: {bin_path}")

    if APP_DIR.exists():
        shutil.rmtree(APP_DIR)

    macos = APP_DIR / "Contents/MacOS"
    resources = APP_DIR / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)

    shutil.copy2(bin_path, macos / APP_NAME)

    src_plist = PROJECT_DIR / "Sources/MarkView/Info.plist"
    with src_plist.open("rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleExecutable"] = APP_NAME
    info["CFBundleIdentifier"] = BUNDLE_ID
    info["CFBundleName"] = APP_NAME
    info["CFBundleDisplayName"] = APP_NAME
    info["CFBundlePackageType"] = "APPL"
    with (APP_DIR / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)

    (APP_DIR / "Contents/PkgInfo").write_bytes(b"APPL????")

    icon = PROJECT_DIR / "Sources/MarkView/Resources/AppIcon.icns"
    if icon.is_file():
        shutil.copy2(icon, resources / "AppIcon.icns")

    # Binary redistributions must carry the upstream and dependency notices.
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(PROJECT_DIR / name, resources / name)
    shutil.copytree(PROJECT_DIR / "docs/licenses", resources / "Licenses")

    allowed = {
        "MarkView_MarkViewCore.bundle",
        "MarkView_OneMd.bundle",
    }
    for bundle in (PROJECT_DIR / ".build/release").glob("*.bundle"):
        if bundle.name not in allowed:
            continue
        dest = resources / bundle.name
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(bundle, dest)

    entitlements = PROJECT_DIR / "Sources/MarkView/MarkView.entitlements"
    sign_cmd = ["codesign", "-s", "-", "-f", "--deep"]
    if entitlements.is_file():
        sign_cmd.extend(["--entitlements", str(entitlements)])
    sign_cmd.append(str(APP_DIR))
    run(sign_cmd)

    print(f"Built {APP_DIR}")


if __name__ == "__main__":
    main()
