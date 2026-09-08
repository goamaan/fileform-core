#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

FILEFORM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILEFORM_WORK="$FILEFORM_ROOT/Artifacts/engine-build"
FILEFORM_PACK="$FILEFORM_ROOT/Artifacts/MediaPack"
FILEFORM_VERSION=9.0.1
FILEFORM_SHA256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
FILEFORM_KEY=FCF986EA15E6E293A5644F10B4322F04D67658D8
mkdir -p "$FILEFORM_WORK" "$FILEFORM_PACK/bin" "$FILEFORM_PACK/licenses" "$FILEFORM_PACK/sources"
cd "$FILEFORM_WORK"

for item in "ffmpeg-$FILEFORM_VERSION.tar.xz" "ffmpeg-$FILEFORM_VERSION.tar.xz.asc"; do
    if [ ! -f "$item" ]; then
        curl --fail --location --silent --show-error "https://ffmpeg.org/releases/$item" -o "$item.download"
        mv "$item.download" "$item"
    fi
done
printf '%s  %s\n' "$FILEFORM_SHA256" "ffmpeg-$FILEFORM_VERSION.tar.xz" | shasum -a 256 -c -
command -v gpg >/dev/null || { echo 'Install GnuPG to verify the upstream source release.' >&2; exit 1; }
curl --fail --silent --show-error https://ffmpeg.org/ffmpeg-devel.asc -o ffmpeg-devel.asc
mkdir -p verification-keyring
chmod 700 verification-keyring
gpg --homedir "$FILEFORM_WORK/verification-keyring" --batch --import ffmpeg-devel.asc >/dev/null 2>&1
gpg --homedir "$FILEFORM_WORK/verification-keyring" --batch --status-fd 1 \
    --verify "ffmpeg-$FILEFORM_VERSION.tar.xz.asc" "ffmpeg-$FILEFORM_VERSION.tar.xz" > verification.txt 2> verification.log
grep -q "VALIDSIG $FILEFORM_KEY " verification.txt || { echo 'Unexpected FFmpeg release signer.' >&2; exit 1; }

if [ ! -d "ffmpeg-$FILEFORM_VERSION" ]; then tar -xf "ffmpeg-$FILEFORM_VERSION.tar.xz"; fi
cd "ffmpeg-$FILEFORM_VERSION"
FILEFORM_FLAGS=(
    --prefix=/ --disable-autodetect --disable-network --disable-doc --disable-debug
    --disable-ffplay --disable-avdevice --disable-shared --enable-static
    --disable-protocols --enable-protocol=file,pipe
    --enable-videotoolbox --enable-audiotoolbox --enable-zlib
    --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0
)
./configure "${FILEFORM_FLAGS[@]}" > "$FILEFORM_WORK/configure.log" 2>&1
FILEFORM_JOBS="${FILEFORM_BUILD_JOBS:-6}"
make -j "$FILEFORM_JOBS" > "$FILEFORM_WORK/make.log" 2>&1
cp ffmpeg ffprobe "$FILEFORM_PACK/bin/"
cp COPYING.LGPLv2.1 LICENSE.md "$FILEFORM_PACK/licenses/"
cp "$FILEFORM_WORK/ffmpeg-$FILEFORM_VERSION.tar.xz" "$FILEFORM_WORK/ffmpeg-$FILEFORM_VERSION.tar.xz.asc" "$FILEFORM_PACK/sources/"
printf '%s\n' "${FILEFORM_FLAGS[@]}" > "$FILEFORM_PACK/build-flags.txt"
"$FILEFORM_PACK/bin/ffmpeg" -hide_banner -version > "$FILEFORM_PACK/version.txt"
"$FILEFORM_PACK/bin/ffmpeg" -hide_banner -protocols > "$FILEFORM_PACK/protocols.txt"
"$FILEFORM_PACK/bin/ffmpeg" -hide_banner -encoders > "$FILEFORM_PACK/encoders.txt"
"$FILEFORM_PACK/bin/ffmpeg" -hide_banner -decoders > "$FILEFORM_PACK/decoders.txt"
"$FILEFORM_PACK/bin/ffmpeg" -hide_banner -L > "$FILEFORM_PACK/license-report.txt"
if grep -Eq -- '--enable-(gpl|nonfree)|GNU General Public License' "$FILEFORM_PACK/license-report.txt"; then
    echo 'Unexpected FFmpeg license configuration.' >&2; exit 1
fi
FILEFORM_PACK_PATH="$FILEFORM_PACK" python3 - <<'PY'
import hashlib, json, os, platform
from pathlib import Path
p=Path(os.environ['FILEFORM_PACK_PATH'])
manifest={
    'schemaVersion':1, 'id':'app.fileform.media', 'version':'9.0.1-fileform.1',
    'architecture':platform.machine(), 'minimumMacOS':'14.0',
    'upstreamVersion':'9.0.1', 'license':'LGPL-2.1-or-later',
    'sourceSHA256':'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635',
    'upstreamSignatureVerified':True, 'networkProtocols':False,
    'executables':{name:hashlib.sha256((p/'bin'/name).read_bytes()).hexdigest() for name in ['ffmpeg','ffprobe']}
}
(p/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
echo "Verified media pack built at $FILEFORM_PACK"
