#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p work/test-results work/MacModuleCache
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/work/MacModuleCache" \
  Shared/*.swift AudioTrace/SessionExport.swift AudioTrace/IntegrityChecker.swift Tests/CoreTests.swift \
  -o work/test-results/CoreTests
/usr/bin/time -l work/test-results/CoreTests "$PWD/work/test-results"
python3 Scripts/verify_test_results.py
