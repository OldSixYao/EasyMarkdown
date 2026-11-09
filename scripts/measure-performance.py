#!/usr/bin/env python3
"""Compile production sources into an isolated, reproducible performance harness."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--mode", choices=["native", "web", "interactive", "draft", "extended-memory", "configuration-memory", "images-memory"], default="native")
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    scripts = Path(__file__).resolve().parent
    app = output / ("EasyMarkdown测量-" + uuid.uuid4().hex[:8] + ".app")
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    bundle = resources / "Measurement.bundle"
    shutil.copytree(source / "Sources/EasyMarkdown/Resources", bundle / "Resources")
    (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "app.easymarkdown.measurement.resources"}))
    info = plistlib.loads((source / "scripts/Info.plist").read_bytes())
    identity = "app.easymarkdown.measurement." + uuid.uuid4().hex
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identity, "CFBundleName": app.stem,
        "CFBundleExecutable": "PerformanceHarness", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": info["CFBundleShortVersionString"],
        "CFBundleVersion": info["CFBundleVersion"], "LSUIElement": True,
        "NSHighResolutionCapable": True, "LSMinimumSystemVersion": "14.0",
    }))
    support = output / "HarnessSupport.swift"
    support.write_text("import AppKit\nimport Foundation\n"
        + "enum AppResources { static let bundle = Bundle(path: " + json.dumps(str(bundle), ensure_ascii=False) + ")! }\n"
        + "@MainActor final class AppDelegate: NSObject, NSApplicationDelegate { func open(_ url: URL) {} }\n")
    harness = output / "PerformanceHarness.swift"
    shutil.copy2(scripts / "performance/PerformanceHarness.swift", harness)
    shutil.copy2(scripts / "performance/web.js", output / "web.js")
    core = sorted((source / "Sources/EasyMarkdownCore").glob("*.swift"))
    commands = [
        ["swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-whole-module-optimization",
         "-emit-module", "-emit-object", "-module-name", "EasyMarkdownCore", *map(str, core),
         "-emit-module-path", str(output / "EasyMarkdownCore.swiftmodule"), "-o", str(output / "EasyMarkdownCore.o")]
    ]
    names = ["DocumentSession", "DocumentView", "MarkdownDocument", "MarkdownPreview", "SourceEditor",
             "SourceHighlighting", "MarkdownToolbar", "ToolbarHoverFeedback", "SplitScrollPosition",
             "DraftStore", "DocumentFormattingService", "DirectoryMonitor", "PreviewActivity",
             "LocalResourceHandler", "ImageResourceBudget", "ImageDownload", "MemoryCheck"]
    files = [source / "Sources/EasyMarkdown" / (name + ".swift") for name in names]
    files = [path for path in files if path.exists()]
    commands.append(["swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-I", str(output),
        str(output / "EasyMarkdownCore.o"), *map(str, files), str(support), str(harness), "-o", str(macos / "PerformanceHarness")])
    (output / "commands.json").write_text(json.dumps(commands, indent=2, ensure_ascii=False))
    with (output / "build.log").open("w") as log:
        for command in commands:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError((output / "build.log").read_text())
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    try:
        if args.mode.endswith("memory"):
            subprocess.run(["python3", str(scripts / "check-memory.py"), str(app), str(output / "memory")],
                           env=dict(os.environ, EASYMARKDOWN_EXTENDED_MEMORY="1",
                                    EASYMARKDOWN_MEASUREMENT_SCENARIO=args.mode), check=True)
        else:
            with (output / "run.log").open("w") as log:
                subprocess.run([str(macos / "PerformanceHarness"), args.mode, str(output)],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
            print((output / "metrics.json").read_text())
    finally:
        lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        subprocess.run([lsregister, "-u", str(app)], capture_output=True)
        app.rename(app.with_suffix(".profile-artifact"))


if __name__ == "__main__":
    main()
