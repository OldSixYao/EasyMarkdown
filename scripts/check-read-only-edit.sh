#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="${EASYMARKDOWN_APP_OUTPUT:-$PWD/dist/EasyMarkdown.app}"
bash scripts/build-app.sh debug
"$app_dir/Contents/MacOS/EasyMarkdown" -appLanguage zh-Hans \
  --read-only-edit-test "$PWD/.build/read-only-edit"
cat .build/read-only-edit/result.txt
