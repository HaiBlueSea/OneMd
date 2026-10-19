#!/usr/bin/env python3
"""Package the current local build for a GitHub Release; never upload anything."""

import hashlib
import json
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    subprocess.run(["python3", "scripts/build_mdos.py"], cwd=ROOT, check=True)
    app = ROOT / "build/OneMd.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    binary = app / "Contents/MacOS/OneMd"
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if arch not in ("arm64", "x86_64"):
        raise SystemExit(f"Unsupported release architecture: {arch}")
    out = ROOT / "release" / f"{version}-macos-{arch}"
    out.mkdir(parents=True, exist_ok=True)
    archive = out / f"OneMd-{version}-macos-{arch}.zip"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["ditto", str(app), str(ROOT / "release/OneMd.app")], check=True)
    # ditto preserves the application bundle layout and executable permissions.
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out / "SHA256SUMS.txt").write_text(f"{digest}  {archive.name}\n")
    notes = ROOT / "docs/releases" / f"{version}.md"
    shutil.copy2(notes, out / "RELEASE_NOTES.md")
    metadata = {
        "version": version,
        "build": info["CFBundleVersion"],
        "bundle_id": info["CFBundleIdentifier"],
        "architecture": arch,
        "minimum_macos": info["LSMinimumSystemVersion"],
        "signature": "ad-hoc",
        "notarized": False,
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True).strip()),
        "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
        "sha256": digest,
    }
    (out / "BUILD_INFO.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Release assets: {out}")
    print(f"SHA-256: {digest}")


if __name__ == "__main__":
    main()
