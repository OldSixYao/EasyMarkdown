#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh debug
binary="$PWD/dist/EasyMarkdown.app/Contents/MacOS/EasyMarkdown"
for language in zh-Hans zh-Hant en; do
  EASYMARKDOWN_EXPECTED_LANGUAGE="$language" "$binary" -appLanguage "$language" -AppleLanguages '(fr)' \
    --language-test "$PWD/.build/languages/$language"
done
# Simulate system preferences without writing to the user's global defaults.
for language in zh-Hans zh-Hant en; do
  EASYMARKDOWN_EXPECTED_LANGUAGE="$language" "$binary" -appLanguage system -AppleLanguages "($language)" \
    --language-test "$PWD/.build/languages/system-$language"
done
EASYMARKDOWN_EXPECTED_LANGUAGE=en "$binary" -appLanguage system -AppleLanguages '(fr)' \
  --language-test "$PWD/.build/languages/system-fallback"
