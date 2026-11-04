#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh debug
check_output="$PWD/.build/smoke"
mkdir -p "$check_output"
dist/EasyMarkdown.app/Contents/MacOS/EasyMarkdown -appLanguage zh-Hans --smoke-test "$check_output"
cat "$check_output/report.json"
