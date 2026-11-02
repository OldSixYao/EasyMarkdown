#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library -D STANDALONE_CHECKS \
  Sources/EasyMarkdownCore/*.swift Tests/EasyMarkdownCoreTests/*.swift scripts/check-core.swift \
  -o .build/checks/core-checks
.build/checks/core-checks
