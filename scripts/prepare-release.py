#!/usr/bin/env python3
"""构建磁盘映像并生成签名更新源；不提交代码或发布远端。"""
import argparse
import hashlib
import html
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = "app.easymarkdown.mac.updates"
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
REPOSITORY = "https://github.com/OldSixYao/EasyMarkdown"


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="使用已有发布构建，仍检查版本和签名")
    args = parser.parse_args()
    if not args.skip_build:
        run("bash", "scripts/build-app.sh", "release")
    app = ROOT / "dist/EasyMarkdown.app"
    source = plistlib.loads((ROOT / "scripts/Info.plist").read_bytes())
    bundle = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "SUPublicEDKey", "SUFeedURL"):
        if bundle[key] != source[key]:
            raise RuntimeError(f"应用包与源配置不同：{key}")
    if not bundle["SURequireSignedFeed"] or not bundle["SUVerifyUpdateBeforeExtraction"]:
        raise RuntimeError("发布构建未启用更新签名验证")
    version = source["CFBundleShortVersionString"]
    architectures = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/EasyMarkdown")], text=True).strip()
    if architectures != "arm64":
        raise RuntimeError("当前发布脚本只支持苹果芯片安装包")
    run("codesign", "--verify", "--deep", "--strict", app)
    public_key = subprocess.check_output([str(TOOLS / "generate_keys"), "--account", ACCOUNT, "-p"], text=True).strip()
    if public_key != source["SUPublicEDKey"]:
        raise RuntimeError("钥匙串中的更新公钥与应用包不匹配")
    destination = ROOT / f"dist/release-{version}"
    destination.mkdir(parents=True, exist_ok=True)
    archive_name = f"EasyMarkdown-{version}-arm64.dmg"
    with tempfile.TemporaryDirectory(prefix="release-", dir=ROOT / ".build") as staging:
        staging = Path(staging)
        image_root = staging / "image"
        image_root.mkdir()
        run("ditto", app, image_root / "EasyMarkdown.app")
        (image_root / "Applications").symlink_to("/Applications")
        archive = destination / archive_name
        run("hdiutil", "create", "-ov", "-volname", "EasyMarkdown", "-srcfolder", image_root,
            "-fs", "APFS", "-format", "ULFO", archive)
        run("hdiutil", "verify", archive)
        # Feed generation only sees this release's archive, while retaining older feed entries.
        feed_root = staging / "feed"
        feed_root.mkdir()
        shutil.copy2(archive, feed_root / archive_name)
        existing_feed = ROOT / "updates/appcast.xml"
        if existing_feed.exists():
            shutil.copy2(existing_feed, feed_root / "appcast.xml")
        changelog = (ROOT / "CHANGELOG.md").read_text()
        section = changelog.split(f"## {version}\n", 1)[1].split("\n## ", 1)[0]
        bullets = [line[2:] for line in section.splitlines() if line.startswith("- ")]
        release_notes = "<ul>" + "".join(f"<li>{html.escape(line)}</li>" for line in bullets) + "</ul>"
        (feed_root / archive_name.replace(".dmg", ".html")).write_text(release_notes)
        run(TOOLS / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0",
            "--download-url-prefix", f"{REPOSITORY}/releases/download/v{version}/",
            "--link", REPOSITORY, "--embed-release-notes", feed_root)
        run(TOOLS / "sign_update", "--account", ACCOUNT, "--verify", feed_root / "appcast.xml")
        shutil.copy2(feed_root / "appcast.xml", destination / "appcast.xml")
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (destination / "SHA256SUMS.txt").write_text(f"{checksum}  {archive_name}\n")
    print(f"发布产物：{destination}")
    print("先公开磁盘映像和校验和并验证下载，再将 appcast.xml 原样复制到 updates/ 并提交推送。")


if __name__ == "__main__":
    main()
