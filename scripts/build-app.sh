#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  echo "Usage: $0 [release|debug]" >&2
  exit 1
fi
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/dist/EasyMarkdown.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/EasyMarkdown" "$app_dir/Contents/MacOS/"
cp -R "$binary_dir/EasyMarkdown_EasyMarkdown.bundle" "$app_dir/Contents/Resources/"
for language in zh-Hans zh-Hant en; do
  mkdir -p "$app_dir/Contents/Resources/$language.lproj"
  cp Sources/EasyMarkdown/Resources/"$language.lproj/"*.strings "$app_dir/Contents/Resources/$language.lproj/"
done
cp scripts/Info.plist "$app_dir/Contents/Info.plist"
cp Assets/AppIcon.icns "$app_dir/Contents/Resources/"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
