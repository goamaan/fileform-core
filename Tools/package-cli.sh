#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
FILEFORM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$FILEFORM_ROOT"
FILEFORM_WITH_MEDIA=false
if [ "${1:-}" = --with-media ]; then FILEFORM_WITH_MEDIA=true
elif [ -n "${1:-}" ]; then echo 'Usage: Tools/package-cli.sh [--with-media]' >&2; exit 2; fi
swift build -c release
FILEFORM_STAGE="$(mktemp -d /tmp/fileform-cli-package.XXXXXX)"
trap 'rm -rf "$FILEFORM_STAGE"' EXIT
mkdir -p "$FILEFORM_STAGE/Notices" Artifacts/releases
cp .build/release/fileform "$FILEFORM_STAGE/fileform"
cp LICENSE "$FILEFORM_STAGE/Notices/FileformCore-LICENSE.txt"
cp NOTICE "$FILEFORM_STAGE/Notices/FileformCore-NOTICE.txt"
cp .build/checkouts/swift-argument-parser/LICENSE.txt "$FILEFORM_STAGE/Notices/SwiftArgumentParser-LICENSE.txt"
if [ "$FILEFORM_WITH_MEDIA" = true ]; then
    test -f Artifacts/MediaPack/manifest.json || { echo 'Build the media pack first.' >&2; exit 1; }
    ditto Artifacts/MediaPack "$FILEFORM_STAGE/MediaPack"
fi
codesign --force --sign - --options runtime "$FILEFORM_STAGE/fileform"
codesign --verify --strict "$FILEFORM_STAGE/fileform"
"$FILEFORM_STAGE/fileform" capabilities --json > "$FILEFORM_STAGE/capabilities.json"
FILEFORM_VERSION="$("$FILEFORM_STAGE/fileform" --version)"
FILEFORM_REVISION="$(git rev-parse HEAD)"
FILEFORM_DIRTY=false
if [ -n "$(git status --porcelain)" ]; then FILEFORM_DIRTY=true; fi
FILEFORM_STAGE_PATH="$FILEFORM_STAGE" FILEFORM_PACKAGE_REVISION="$FILEFORM_REVISION" FILEFORM_PACKAGE_DIRTY="$FILEFORM_DIRTY" FILEFORM_PACKAGE_VERSION="$FILEFORM_VERSION" python3 - <<'PY'
import hashlib,json,os,platform
from pathlib import Path
p=Path(os.environ['FILEFORM_STAGE_PATH'])
d={'schemaVersion':1,'product':'Fileform CLI','version':os.environ['FILEFORM_PACKAGE_VERSION'],
   'architecture':platform.machine(),'coreRevision':os.environ['FILEFORM_PACKAGE_REVISION'],
   'sourceDirty':os.environ['FILEFORM_PACKAGE_DIRTY']=='true','distribution':'development','notarized':False,
   'sha256':hashlib.sha256((p/'fileform').read_bytes()).hexdigest(),'mediaPackIncluded':(p/'MediaPack').exists()}
(p/'manifest.json').write_text(json.dumps(d,indent=2)+'\n')
(p/'README.txt').write_text('Fileform CLI — development archive\n\nRun ./fileform --help. If MediaPack is included beside the executable, it is discovered automatically.\n\nThis archive is ad-hoc signed for development, not notarized for customer delivery. Source and build instructions: https://github.com/goamaan/fileform-core\n\nOpen-source licenses are in Notices; media source and licenses are inside MediaPack when included.\n')
PY
FILEFORM_ARCHIVE="$FILEFORM_ROOT/Artifacts/releases/fileform-cli-$FILEFORM_VERSION-$(uname -m).tar.gz"
tar -czf "$FILEFORM_ARCHIVE" -C "$FILEFORM_STAGE" .
(
    cd "$(dirname "$FILEFORM_ARCHIVE")"
    shasum -a 256 "$(basename "$FILEFORM_ARCHIVE")" > "$(basename "$FILEFORM_ARCHIVE").sha256"
)
echo "Development CLI archive: $FILEFORM_ARCHIVE"
