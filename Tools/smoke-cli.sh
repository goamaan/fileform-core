#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
FILEFORM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$FILEFORM_ROOT"
swift build >/dev/null
FILEFORM_WORK="$(mktemp -d "${TMPDIR:-/tmp}/fileform-cli-smoke.XXXXXX")"
trap 'rm -rf "$FILEFORM_WORK"' EXIT
swift Tools/generate-fixtures.swift "$FILEFORM_WORK/inputs" >/dev/null
mkdir "$FILEFORM_WORK/outputs"
.build/debug/fileform --help > "$FILEFORM_WORK/help.txt"
.build/debug/fileform inspect "$FILEFORM_WORK/inputs/Studio chart.png" --json > "$FILEFORM_WORK/inspection.json"
.build/debug/fileform convert "$FILEFORM_WORK/inputs/Studio chart.png" --to jpeg --output "$FILEFORM_WORK/outputs/chart.jpg" --json > "$FILEFORM_WORK/result.json"
.build/debug/fileform convert "$FILEFORM_WORK/inputs/Studio chart.png" --to png --output "$FILEFORM_WORK/outputs/dry.png" --dry-run --json > "$FILEFORM_WORK/plan.json"
test ! -e "$FILEFORM_WORK/outputs/dry.png"
set +e
.build/debug/fileform fit "$FILEFORM_WORK/inputs/Studio chart.png" --to jpeg --max-bytes 10 --output "$FILEFORM_WORK/outputs/impossible.jpg" --json > "$FILEFORM_WORK/unmet.json" 2> "$FILEFORM_WORK/unmet.log"
FILEFORM_STATUS=$?
set -e
test "$FILEFORM_STATUS" = 4
test ! -e "$FILEFORM_WORK/outputs/impossible.jpg"
printf 'name,note\r\n"Lee, Jo","hello"\r\n' > "$FILEFORM_WORK/inputs/table.csv"
.build/debug/fileform convert "$FILEFORM_WORK/inputs/table.csv" --to json --output "$FILEFORM_WORK/outputs/table.json" --json > "$FILEFORM_WORK/table-result.json"
if [ -f Artifacts/MediaPack/manifest.json ]; then
    FILEFORM_MEDIA_PACK="$FILEFORM_ROOT/Artifacts/MediaPack" .build/debug/fileform convert "$FILEFORM_WORK/inputs/Studio tone.wav" --to flac --output "$FILEFORM_WORK/outputs/tone.flac" --json > "$FILEFORM_WORK/audio-result.json"
fi
FILEFORM_SMOKE_PATH="$FILEFORM_WORK" python3 - <<'PY'
import json,os
from pathlib import Path
p=Path(os.environ['FILEFORM_SMOKE_PATH'])
assert json.loads((p/'result.json').read_text())['status']=='succeeded'
assert json.loads((p/'inspection.json').read_text())['family']=='image'
assert json.loads((p/'unmet.json').read_text())['code']=='target_unmet'
assert json.loads((p/'outputs/table.json').read_text())==[{'name':'Lee, Jo','note':'hello'}]
assert not list((p/'outputs').glob('.fileform-*'))
print('CLI smoke passed: real image conversion, JSON reports, dry-run, target miss, table cells and available media.')
PY
