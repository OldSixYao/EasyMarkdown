#!/usr/bin/env python3
"""在隔离应用、偏好域和本地服务器中验证真实更新流程，不修改已安装应用。"""
import base64
import functools
import http.server
import json
import plistlib
import shutil
import tempfile
import subprocess
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
ACCOUNT = "app.easymarkdown.mac.updates"
OUTPUT = Path(tempfile.mkdtemp(prefix="easymarkdown-updates-"))
REPORT = ROOT / ".build/updates" / OUTPUT.name
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT, **kwargs)


def sign(path):
    return subprocess.check_output([str(TOOLS / "sign_update"), "--account", ACCOUNT, "-p", str(path)], text=True).strip()


def configure(app, changes):
    plist = app / "Contents/Info.plist"
    data = plistlib.loads(plist.read_bytes())
    data.update(changes)
    plist.write_bytes(plistlib.dumps(data))
    run("codesign", "--force", "--sign", "-", app, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def copy_app(destination):
    run("ditto", ROOT / "dist/EasyMarkdown.app", destination)


def feed(path, archive, url, build="25", minimum="14.0.0", signature=None):
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "EasyMarkdown 隔离更新检查"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "隔离更新检查"
    ET.SubElement(item, f"{{{NS}}}version").text = build
    ET.SubElement(item, f"{{{NS}}}shortVersionString").text = "0.1.24"
    ET.SubElement(item, f"{{{NS}}}minimumSystemVersion").text = minimum
    ET.SubElement(item, f"{{{NS}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "enclosure", {
        "url": url, "length": str(archive.stat().st_size), "type": "application/octet-stream",
        f"{{{NS}}}edSignature": signature or sign(archive),
    })
    ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)
    sign(path)


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.endswith("/interrupted.zip"):
            self.send_response(200)
            self.send_header("Content-Length", "10000000")
            self.end_headers()
            self.wfile.write(b"PK\x03\x04interrupted")
            self.close_connection = True
        else:
            super().do_GET()


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    run("bash", "scripts/build-app.sh", "debug")
    run(ROOT / "dist/EasyMarkdown.app/Contents/MacOS/EasyMarkdown", "--update-test", OUTPUT / "configuration", timeout=30)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(OUTPUT)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f"http://127.0.0.1:{server.server_port}"
    results = ["configuration"]
    # All bundle modifications and localhost exceptions are confined to these copies.
    scenarios = ["controller", "preferences", "no-update", "standard-current", "found", "offline", "bad-feed", "bad-signature",
                 "corrupt-archive", "interrupted", "unsupported", "install", "save", "discard", "cancel", "save-failure"]
    try:
        for scenario in scenarios:
            directory = OUTPUT / scenario
            directory.mkdir()
            app = directory / "installed/EasyMarkdown.app"
            copy_app(app)
            identifier = f"app.easymarkdown.updatecheck.{uuid.uuid4().hex}"
            feed_url = f"{base_url}/{scenario}/appcast.xml"
            configure(app, {
                "CFBundleIdentifier": identifier,
                "CFBundleVersion": "25" if scenario in ("no-update", "standard-current") else "24",
                "SUFeedURL": "http://127.0.0.1:9/appcast.xml" if scenario == "offline" else feed_url,
                "SUEnableAutomaticChecks": False,
                "AppleLanguages": ["en"],
                "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
                "EasyMarkdownUpdateFixture": True,
                "EasyMarkdownUpdateScenario": scenario,
                "EasyMarkdownUpdateReportPath": str(directory),
            })
            if scenario not in ("controller", "preferences", "offline"):
                candidate = directory / "candidate/EasyMarkdown.app"
                run("ditto", app, candidate)
                configure(candidate, {"CFBundleVersion": "25", "EasyMarkdownUpdateScenario": "relaunch"})
                archive = directory / "update.zip"
                run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", candidate, archive)
                if scenario == "corrupt-archive":
                    archive.write_bytes(b"not a zip archive")
                feed(directory / "appcast.xml", archive,
                     f"{base_url}/{scenario}/{'interrupted.zip' if scenario == 'interrupted' else 'update.zip'}",
                     minimum="99.0.0" if scenario == "unsupported" else "14.0.0",
                     signature=base64.b64encode(bytes(64)).decode() if scenario == "bad-signature" else None)
                if scenario == "bad-feed":
                    path = directory / "appcast.xml"
                    path.write_bytes(path.read_bytes().replace("隔离更新检查".encode(), b"tampered"))
            log = open(directory / "process.log", "wb")
            process = subprocess.Popen([str(app / "Contents/MacOS/EasyMarkdown"), "-appLanguage", "en"], stdout=log, stderr=log)
            try:
                process.wait(timeout=75)
                if process.returncode:
                    raise RuntimeError(f"{scenario} 进程失败：{(directory / 'process.log').read_text()[-2500:]}")
                report = json.loads((directory / "report.json").read_text())
                expected = ("standard-current" if scenario == "standard-current" else
                            "controller-passed" if scenario == "controller" else
                            "preferences-passed" if scenario == "preferences" else
                            "not-found" if scenario in ("no-update", "unsupported") else
                            "found" if scenario == "found" else
                            "ready-to-install" if scenario in ("install", "save", "discard") else
                            "cancel-preserved" if scenario == "cancel" else
                            "save-failure-preserved" if scenario == "save-failure" else "error")
                if report["result"] != expected:
                    raise RuntimeError(f"{scenario} 结果不符：{report}")
                if scenario == "preferences":
                    configure(app, {"EasyMarkdownUpdateScenario": "preferences-restored"})
                    run(app / "Contents/MacOS/EasyMarkdown", "-appLanguage", "en", timeout=20, stdout=log, stderr=log)
                    restored = json.loads((directory / "report.json").read_text())
                    if restored["result"] != "preferences-restored":
                        raise RuntimeError("自动检查偏好未在重启后恢复")
                if scenario in ("install", "save", "discard"):
                    for _ in range(200):
                        if (directory / "relaunch.json").exists():
                            break
                        time.sleep(0.1)
                    relaunch = json.loads((directory / "relaunch.json").read_text())
                    if relaunch != {"result": "relaunched", "build": "25"}:
                        raise RuntimeError(f"{scenario} 未重新启动目标版本：{relaunch}")
                    if scenario == "save" and (directory / "document.md").read_text() != "# Modified\n":
                        raise RuntimeError("升级前保存未写入文档")
                    if scenario == "discard" and (directory / "document.md").read_text() != "# Original\n":
                        raise RuntimeError("放弃修改意外覆盖原文档")
                elif scenario not in ("cancel", "save-failure"):
                    installed = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                    if installed["CFBundleVersion"] != ("25" if scenario in ("no-update", "standard-current") else "24"):
                        raise RuntimeError(f"{scenario} 意外替换原应用")
                if scenario == "bad-signature" and "signature validation before unarchiving failed" not in report.get("errorDetails", ""):
                    raise RuntimeError("安装包没有在解压前因签名错误被拒绝")
                if scenario == "bad-feed" and "found:25" in report["events"]:
                    raise RuntimeError("被篡改的更新源仍提供更新")
                results.append(scenario)
                print(f"通过：{scenario}", flush=True)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                log.close()
                subprocess.run(["defaults", "delete", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        server.shutdown()
        for path in OUTPUT.rglob("*"):
            if path.is_file() and path.suffix in (".json", ".log", ".png") and ".app" not in str(path):
                destination = REPORT / path.relative_to(OUTPUT)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
    (OUTPUT / "summary.json").write_text(json.dumps({"passed": results}, ensure_ascii=False, indent=2))
    shutil.copy2(OUTPUT / "summary.json", REPORT / "summary.json")
    print(f"更新验证完成：{REPORT}")
    print(f"隔离应用位于：{OUTPUT}")


if __name__ == "__main__":
    main()
