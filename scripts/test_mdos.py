#!/usr/bin/env python3
"""Compile focused native regressions against the app's current release objects."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
TASK = ROOT / (".tmp/sidebar-drag-fix" if "--sidebar-only" in sys.argv else ".tmp/document-links" if "--links-only" in sys.argv else ".tmp/ui-resource-review")
TASK.mkdir(parents=True, exist_ok=True)
subprocess.run(["swift", "build", "-c", "release", "--product", "OneMd"], cwd=ROOT, check=True)
BUILD = (ROOT / ".build/release").resolve()
description = json.loads((BUILD / "description.json").read_text())
command = next(value for key, value in description["swiftCommands"].items() if key.startswith("C.OneMd-"))
args = command["otherArguments"]
flags = []
i = 0
while i < len(args):
    arg = args[i]
    if arg in ["-target", "-sdk", "-module-cache-path", "-swift-version"]:
        flags += args[i:i+2]
        i += 2
    elif arg == "-Xcc":
        flags += args[i:i+2]
        i += 2
    else:
        i += 1
objects = [line for line in (BUILD / "OneMd.product/Objects.LinkFileList").read_text().splitlines() if "/OneMd.build/" not in line]
sources = ["Tests/MDOSRegressionTests/main.swift", "Tests/MDOSRegressionTests/SidebarResizeTests.swift", "Tests/MDOSRegressionTests/DocumentLinkTests.swift", "Sources/MarkView/WindowFrameAutosave.swift", "Sources/MarkView/WebPreviewView.swift", "Sources/MarkView/EditorView.swift", "Sources/MarkView/ScrollSyncController.swift", "Sources/MarkView/Strings.swift", "Sources/MarkView/AppLogger.swift"]
binary = TASK / "MDOSRegressionTests"
subprocess.run(["swiftc", "-O", "-I", str(BUILD / "Modules"), *flags, *sources, *objects, "-o", str(binary)], cwd=ROOT, check=True)
# A separate executable gives UserDefaults a separate process domain.
log_path = TASK / ("quick.log" if "--quick" in sys.argv else "regression.log")
with log_path.open("w") as log:
    result = subprocess.run([str(binary), str(TASK), *sys.argv[1:]], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
print(log_path.read_text())
sys.exit(result.returncode)
