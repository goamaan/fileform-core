#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

FILEFORM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILEFORM_WORK="$FILEFORM_ROOT/Artifacts/engine-build"
FILEFORM_PACK="${FILEFORM_MEDIA_PACK_OUTPUT:-$FILEFORM_ROOT/Artifacts/MediaPack}"
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
FILEFORM_GPG_HOME="$(mktemp -d /tmp/fileform-gpg.XXXXXX)"
trap 'gpgconf --homedir "$FILEFORM_GPG_HOME" --kill all >/dev/null 2>&1 || true; rm -rf "$FILEFORM_GPG_HOME"' EXIT
gpg --homedir "$FILEFORM_GPG_HOME" --batch --import ffmpeg-devel.asc > key-import.log 2>&1 || { cat key-import.log >&2; exit 1; }
gpg --homedir "$FILEFORM_GPG_HOME" --batch --status-fd 1 \
    --verify "ffmpeg-$FILEFORM_VERSION.tar.xz.asc" "ffmpeg-$FILEFORM_VERSION.tar.xz" > verification.txt 2> verification.log || { cat verification.log >&2; exit 1; }
grep -q "VALIDSIG $FILEFORM_KEY " verification.txt || { echo 'Unexpected FFmpeg release signer.' >&2; exit 1; }

if [ ! -d "ffmpeg-$FILEFORM_VERSION" ]; then tar -xf "ffmpeg-$FILEFORM_VERSION.tar.xz"; fi
# Build only the LGPL encoder library; the optional mpglib decoder is excluded.
FILEFORM_LAME_VERSION=3.100
FILEFORM_LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
FILEFORM_LAME_PREFIX="$FILEFORM_WORK/lame-install"
if [ ! -f "lame-$FILEFORM_LAME_VERSION.tar.gz" ]; then
    curl --fail --location --silent --show-error "https://downloads.sourceforge.net/project/lame/lame/$FILEFORM_LAME_VERSION/lame-$FILEFORM_LAME_VERSION.tar.gz" -o "lame-$FILEFORM_LAME_VERSION.tar.gz.download"
    mv "lame-$FILEFORM_LAME_VERSION.tar.gz.download" "lame-$FILEFORM_LAME_VERSION.tar.gz"
fi
printf '%s  %s\n' "$FILEFORM_LAME_SHA256" "lame-$FILEFORM_LAME_VERSION.tar.gz" | shasum -a 256 -c -
if [ ! -d "lame-$FILEFORM_LAME_VERSION" ]; then tar -xf "lame-$FILEFORM_LAME_VERSION.tar.gz"; fi
cd "lame-$FILEFORM_LAME_VERSION"
FILEFORM_LAME_FLAGS=(--prefix="$FILEFORM_LAME_PREFIX" --disable-shared --enable-static --disable-decoder --disable-frontend --disable-analyzer-hooks)
CFLAGS="-O2 -mmacosx-version-min=14.0" ./configure "${FILEFORM_LAME_FLAGS[@]}" > "$FILEFORM_WORK/lame-configure.log" 2>&1 || { tail -n 60 "$FILEFORM_WORK/lame-configure.log" >&2; exit 1; }
make -j "${FILEFORM_BUILD_JOBS:-6}" > "$FILEFORM_WORK/lame-make.log" 2>&1 || { tail -n 60 "$FILEFORM_WORK/lame-make.log" >&2; exit 1; }
make install > "$FILEFORM_WORK/lame-install.log" 2>&1
cp COPYING "$FILEFORM_PACK/licenses/LAME-COPYING"
cp LICENSE "$FILEFORM_PACK/licenses/LAME-LICENSE"
cp README "$FILEFORM_PACK/licenses/LAME-README"
cp "$FILEFORM_WORK/lame-$FILEFORM_LAME_VERSION.tar.gz" "$FILEFORM_PACK/sources/"
printf '%s\n' "CFLAGS=-O2 -mmacosx-version-min=14.0" "${FILEFORM_LAME_FLAGS[@]}" > "$FILEFORM_PACK/lame-build-flags.txt"
cd "$FILEFORM_WORK/ffmpeg-$FILEFORM_VERSION"
FILEFORM_FLAGS=(
    --prefix=/ --disable-autodetect --disable-network --disable-doc --disable-debug
    --disable-ffplay --disable-avdevice --disable-shared --enable-static
    --disable-protocols --enable-protocol=file,pipe
    --enable-videotoolbox --enable-audiotoolbox --enable-zlib
    --enable-libmp3lame
    "--extra-cflags=-mmacosx-version-min=14.0 -I$FILEFORM_LAME_PREFIX/include"
    "--extra-ldflags=-mmacosx-version-min=14.0 -L$FILEFORM_LAME_PREFIX/lib"
)
./configure "${FILEFORM_FLAGS[@]}" > "$FILEFORM_WORK/configure.log" 2>&1 || { tail -n 60 "$FILEFORM_WORK/configure.log" >&2; exit 1; }
FILEFORM_JOBS="${FILEFORM_BUILD_JOBS:-6}"
make -j "$FILEFORM_JOBS" > "$FILEFORM_WORK/make.log" 2>&1 || { tail -n 60 "$FILEFORM_WORK/make.log" >&2; exit 1; }
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
grep -q 'libmp3lame' "$FILEFORM_PACK/encoders.txt" || { echo 'MP3 encoder missing.' >&2; exit 1; }
otool -L "$FILEFORM_PACK/bin/ffmpeg" > "$FILEFORM_PACK/linked-libraries.txt"
if grep -Eq '/opt/homebrew|/usr/local|lame-install' "$FILEFORM_PACK/linked-libraries.txt"; then
    echo 'Unexpected external runtime library.' >&2; exit 1
fi
clang --version > "$FILEFORM_PACK/toolchain.txt"
sw_vers >> "$FILEFORM_PACK/toolchain.txt"
cp "$FILEFORM_ROOT/Tools/build-media-pack.sh" "$FILEFORM_PACK/sources/build-media-pack.sh"
FILEFORM_PACK_PATH="$FILEFORM_PACK" python3 - <<'PY'
import hashlib, json, os, platform
from pathlib import Path
p=Path(os.environ['FILEFORM_PACK_PATH'])
manifest={
    'schemaVersion':1, 'id':'app.fileform.media', 'version':'9.0.1-fileform.2',
    'architecture':platform.machine(), 'minimumMacOS':'14.0',
    'upstreamVersion':'9.0.1', 'license':'LGPL-2.1-or-later',
    'sourceSHA256':'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635',
    'upstreamSignatureVerified':True, 'networkProtocols':False,
    'audioEncoders':['aac','pcm_s16le','flac','libmp3lame'],
    'components':[{'name':'LAME','version':'3.100','license':'LGPL-2.0-or-later',
        'sourceSHA256':'ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e',
        'sourceURL':'https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz',
        'decoderEnabled':False,'frontendEnabled':False}],
    'executables':{name:hashlib.sha256((p/'bin'/name).read_bytes()).hexdigest() for name in ['ffmpeg','ffprobe']}
}
(p/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
echo "Verified media pack built at $FILEFORM_PACK"
