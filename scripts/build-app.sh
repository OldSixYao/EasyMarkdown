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
app_dir="${EASYMARKDOWN_APP_OUTPUT:-$PWD/dist/EasyMarkdown.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$binary_dir/EasyMarkdown" "$app_dir/Contents/MacOS/"
ditto "$binary_dir/EasyMarkdown_EasyMarkdown.bundle" "$app_dir/Contents/Resources/EasyMarkdown_EasyMarkdown.bundle"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
  "$app_dir/Contents/Frameworks/Sparkle.framework"
for language in zh-Hans zh-Hant en; do
  mkdir -p "$app_dir/Contents/Resources/$language.lproj"
  cp Sources/EasyMarkdown/Resources/"$language.lproj/"*.strings "$app_dir/Contents/Resources/$language.lproj/"
done
cp scripts/Info.plist "$app_dir/Contents/Info.plist"
cp Assets/AppIcon.icns "$app_dir/Contents/Resources/"
# Preserve Sparkle's upstream signatures, including its nested helpers.
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
