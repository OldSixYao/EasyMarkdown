#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh debug
dist/EasyMarkdown.app/Contents/MacOS/EasyMarkdown -appLanguage zh-Hans \
  --configuration-test "$PWD/.build/configurations"
cat .build/configurations/report.json
