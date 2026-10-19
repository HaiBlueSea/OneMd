#!/usr/bin/env python3
"""Capture real ContentView + WKWebView offscreen, using public fixtures only."""

import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TASK = ROOT / ".tmp/github-screenshots"
TASK.mkdir(parents=True, exist_ok=True)
subprocess.run(["swift", "build", "-c", "release", "--product", "OneMd"], cwd=ROOT, check=True)
build = (ROOT / ".build/release").resolve()
description = json.loads((build / "description.json").read_text())
command = next(v for k, v in description["swiftCommands"].items() if k.startswith("C.OneMd-"))
flags = []
args = command["otherArguments"]
for i, arg in enumerate(args[:-1]):
    if arg in ("-target", "-sdk", "-module-cache-path", "-swift-version", "-Xcc"):
        flags.extend(args[i:i + 2])
objects = [p for p in (build / "OneMd.product/Objects.LinkFileList").read_text().splitlines() if "/OneMd.build/" not in p]
# Reuse the app's window tracker and notification names without its @main entry.
app_source = (ROOT / "Sources/MarkView/MarkViewApp.swift").read_text()
tracker = app_source[app_source.index("@MainActor\nfinal class WindowFileTracker"):app_source.index("@main")]
notifications = app_source[app_source.index("extension Notification.Name {"):app_source.index("@MainActor\nenum AppBootstrap")]
support = TASK / "AppSupport.swift"
support.write_text("import AppKit\nimport Foundation\n" + tracker + notifications)
sources = sorted(str(p) for p in (ROOT / "Sources/MarkView").glob("*.swift") if p.name != "MarkViewApp.swift")
binary = TASK / "MDOSScreenshots"
subprocess.run(["swiftc", "-O", "-I", str(build / "Modules"), *flags, *sources, str(support), str(ROOT / "scripts/screenshot_scene.swift"), *objects, "-o", str(binary)], cwd=ROOT, check=True)
shutil.copytree(build / "MarkView_MarkViewCore.bundle", TASK / "MarkView_MarkViewCore.bundle", dirs_exist_ok=True)
subprocess.run([str(binary), str(ROOT)], cwd=ROOT, check=True)
