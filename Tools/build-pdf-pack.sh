#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
FILEFORM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILEFORM_PDF_WORK="${FILEFORM_PDF_BUILD_ROOT:-$FILEFORM_ROOT/Artifacts/pdf-build}"
FILEFORM_PDF_PACK="${FILEFORM_PDF_PACK_OUTPUT:-$FILEFORM_ROOT/Artifacts/PDFPack}"
FILEFORM_PDF_ARCH="${FILEFORM_BUILD_ARCH:-$(uname -m)}"
case "$FILEFORM_PDF_ARCH" in arm64|x86_64) ;; *) echo 'Build arm64 or x86_64 separately.' >&2; exit 1;; esac
mkdir -p "$FILEFORM_PDF_WORK" "$FILEFORM_PDF_PACK/bin" "$FILEFORM_PDF_PACK/licenses" "$FILEFORM_PDF_PACK/sources"
cd "$FILEFORM_PDF_WORK"
fetch_source() {
    local filename="$1" source_url="$2" source_hash="$3"
    if [ ! -f "$filename" ]; then
        curl --fail --location --silent --show-error "$source_url" -o "$filename.download"
        mv "$filename.download" "$filename"
    fi
    printf '%s  %s\n' "$source_hash" "$filename" | shasum -a 256 -c -
    if [ ! -d "${filename%.tar.gz}" ]; then tar -xf "$filename"; fi
}
fetch_source qpdf-12.4.1.tar.gz https://github.com/qpdf/qpdf/releases/download/v12.4.1/qpdf-12.4.1.tar.gz f045aa277be2356ff53a89a8622945958291177d2483afc20ede7c8a8cd3873c
fetch_source libjpeg-turbo-3.2.0.tar.gz https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz 6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
cmake -S libjpeg-turbo-3.2.0 -B jpeg-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$FILEFORM_PDF_ARCH" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF > jpeg-configure.log 2>&1
cmake --build jpeg-build --target jpeg-static --parallel "${FILEFORM_BUILD_JOBS:-2}" > jpeg-build.log 2>&1
mkdir -p jpeg-include
cp libjpeg-turbo-3.2.0/src/jpeglib.h libjpeg-turbo-3.2.0/src/jmorecfg.h jpeg-build/jconfig.h jpeg-include/
cmake -S qpdf-12.4.1 -B qpdf-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$FILEFORM_PDF_ARCH" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_DOC=OFF \
    -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON -DDEFAULT_CRYPTO=native \
    -DPKG_CONFIG_EXECUTABLE=/usr/bin/false -U 'pc_*' \
    -DLIBJPEG_H_PATH="$FILEFORM_PDF_WORK/jpeg-include" \
    -DLIBJPEG_LIB_PATH="$FILEFORM_PDF_WORK/jpeg-build/libjpeg.a" > qpdf-configure.log 2>&1
cmake --build qpdf-build --target qpdf --parallel "${FILEFORM_BUILD_JOBS:-2}" > qpdf-build.log 2>&1
cp qpdf-build/qpdf/qpdf "$FILEFORM_PDF_PACK/bin/qpdf"
cp qpdf-12.4.1/LICENSE.txt "$FILEFORM_PDF_PACK/licenses/qpdf-LICENSE.txt"
cp qpdf-12.4.1/NOTICE.md "$FILEFORM_PDF_PACK/licenses/qpdf-NOTICE.md"
cp qpdf-12.4.1/Artistic-2.0 "$FILEFORM_PDF_PACK/licenses/qtest-Artistic-2.0.txt"
cp libjpeg-turbo-3.2.0/LICENSE.md "$FILEFORM_PDF_PACK/licenses/libjpeg-turbo-LICENSE.md"
cp libjpeg-turbo-3.2.0/README.ijg "$FILEFORM_PDF_PACK/licenses/libjpeg-turbo-README.ijg"
printf '%s\n' 'This software is based in part on the work of the Independent JPEG Group.' > "$FILEFORM_PDF_PACK/licenses/IJG-attribution.txt"
cp qpdf-12.4.1.tar.gz libjpeg-turbo-3.2.0.tar.gz "$FILEFORM_PDF_PACK/sources/"
cp "$FILEFORM_ROOT/Tools/build-pdf-pack.sh" "$FILEFORM_PDF_PACK/sources/"
cp jpeg-build/CMakeCache.txt "$FILEFORM_PDF_PACK/jpeg-build-flags.txt"
cp qpdf-build/CMakeCache.txt "$FILEFORM_PDF_PACK/qpdf-build-flags.txt"
"$FILEFORM_PDF_PACK/bin/qpdf" --version > "$FILEFORM_PDF_PACK/version.txt"
otool -L "$FILEFORM_PDF_PACK/bin/qpdf" > "$FILEFORM_PDF_PACK/linked-libraries.txt"
# Only system runtime libraries are allowed in this static tool pack.
awk 'NR > 1 {print $1}' "$FILEFORM_PDF_PACK/linked-libraries.txt" | while IFS= read -r dependency; do
    case "$dependency" in /usr/lib/*|/System/Library/*) ;; *) echo "Unexpected runtime library: $dependency" >&2; exit 1;; esac
done
clang --version > "$FILEFORM_PDF_PACK/toolchain.txt"
sw_vers >> "$FILEFORM_PDF_PACK/toolchain.txt"
FILEFORM_PDF_PACK_PATH="$FILEFORM_PDF_PACK" FILEFORM_PDF_ARCHITECTURE="$FILEFORM_PDF_ARCH" python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
p = Path(os.environ['FILEFORM_PDF_PACK_PATH'])
components = [
    {'name':'qpdf', 'version':'12.4.1', 'license':'Apache-2.0',
     'sourceURL':'https://github.com/qpdf/qpdf/releases/download/v12.4.1/qpdf-12.4.1.tar.gz',
     'sourceSHA256':'f045aa277be2356ff53a89a8622945958291177d2483afc20ede7c8a8cd3873c'},
    {'name':'libjpeg-turbo', 'version':'3.2.0', 'license':'IJG AND BSD-3-Clause AND Zlib',
     'sourceURL':'https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz',
     'sourceSHA256':'6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e'},
    {'name':'zlib', 'distribution':'Apple system library', 'license':'Zlib'}]
manifest = {'schemaVersion':1, 'id':'app.fileform.pdf', 'version':'12.4.1-fileform.1',
    'architecture':os.environ['FILEFORM_PDF_ARCHITECTURE'], 'minimumMacOS':'14.0',
    'upstreamSignatureVerified':False, 'components':components,
    'executables':{'qpdf':hashlib.sha256((p/'bin/qpdf').read_bytes()).hexdigest()}}
(p/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
PY
echo "Verified PDF pack built at $FILEFORM_PDF_PACK"
