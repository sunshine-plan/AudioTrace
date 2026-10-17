#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p work/capture-flow-tests work/MacModuleCache
python3 - "$1" <<'PY'
from pathlib import Path
import sys,zipfile,shutil
base=Path('work/capture-flow-tests/input').resolve(); base.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(sys.argv[1]) as archive:
    assert sum(f.file_size for f in archive.infolist())<100_000_000
    for item in archive.infolist():
        target=(base/item.filename).resolve()
        assert target.is_relative_to(base)
        if item.is_dir(): target.mkdir(parents=True,exist_ok=True);continue
        target.parent.mkdir(parents=True,exist_ok=True)
        with archive.open(item) as source, target.open('wb') as destination: shutil.copyfileobj(source,destination)
p=Path('Tests/CoreTests.swift').read_text().split('@main struct CoreTests')[0]
Path('work/capture-flow-tests/Fixtures.swift').write_text(p)
PY
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/work/MacModuleCache" \
  Shared/*.swift AudioTrace/IntegrityChecker.swift AudioTrace/SessionExport.swift \
  work/capture-flow-tests/Fixtures.swift Tests/CaptureFlowTests.swift -o work/capture-flow-tests/CaptureFlowTests
fixture_dir=(work/capture-flow-tests/input/session_*(/))
work/capture-flow-tests/CaptureFlowTests "$PWD/work/capture-flow-tests" "$PWD/$fixture_dir[1]"
