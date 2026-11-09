#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh debug
dist/EasyMarkdown.app/Contents/MacOS/EasyMarkdown -appLanguage zh-Hans \
  --editor-workspace-test "$PWD/.build/editor-workspace"
