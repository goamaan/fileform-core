# MP3 output

The `9.0.1-fileform.2` media pack adds MP3 conversion through FFmpeg's
`libmp3lame` adapter. Earlier packs still inspect/decode MP3, but do not advertise
an available MP3 conversion route. The manifest's `audioEncoders` field declares
this additional writer; the existing executable SHA-256 checks still apply.

```
fileform convert recording.wav --to mp3 --output recording.mp3
fileform fit recording.wav --to mp3 --max-bytes 110000 --output small.mp3
```

The current route preserves one mono or stereo audio track at 32, 44.1 or 48 kHz.
Other sample rates or channel counts fail during planning; there is no implicit
resampling or downmixing. A video input with one audio track can be extracted to
MP3. Encoding is lossy, normally at 128 kb/s. Fit selects a supported constant
bitrate down to 48 kb/s and publishes only if the complete verified file meets
the exact byte limit. Compression retains the original if the candidate is not
smaller. Descriptive tags, chapters and cover art are removed; the Xing/LAME
header records encoder delay and padding for gapless-aware decoders.

Verification checks the MP3 container and codec, channel count, sample rate,
full duration and full decode before exclusive publication. `MP3Tests` also uses
Apple's independent `afconvert` decoder. Trimming directly to MP3 remains unsupported: existing
frame/sample trim guarantees have not been extended to its encoder padding.
Joining, implicit channel selection and general stream preservation are also
outside this route.

## Reproducible pack

`Tools/build-media-pack.sh` builds pinned FFmpeg 9.0.1 plus LAME **3.100**, an
explicit compatibility baseline rather than a claim to use the latest LAME
release. The latter archive's SHA-256 is
`ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`.
It is fetched from [the upstream release archive](https://sourceforge.net/projects/lame/files/lame/3.100/).
The LAME archive is hash-pinned, not signature-verified; FFmpeg retains its
release-signature verification.

Only the static LAME encoder library is built. `--disable-decoder`,
`--disable-frontend` and `--disable-analyzer-hooks` exclude the optional decoder,
frontend and analysis hooks. The encoder library is LGPL-2.0-or-later; FFmpeg
remains LGPL-2.1-or-later. See the [LAME project](https://lame.sourceforge.io/),
[its license guidance](https://lame.sourceforge.io/license.txt) and
[FFmpeg's distribution guidance](https://ffmpeg.org/legal.html).
No Homebrew library is used in the distributed pack.

The generated pack includes both source archives, the FFmpeg signature, LAME's
COPYING/LICENSE/README, FFmpeg notices, component versions and source hashes,
both build flag inventories, the build script, codec reports, linked-library
report and binary hashes. App and CLI packaging must retain this whole pack,
including sources and notices, and preserve recipients' replacement/rebuilding
rights. Static linkage here is between open-source media components in a
separate executable, not into the client application. Architecture, deployment
floor, signing and customer-distribution review remain release checks for each
built artifact.

To build a candidate without changing a working pack:

```
FILEFORM_MEDIA_PACK_OUTPUT="$PWD/Artifacts/MediaPack-MP3" Tools/build-media-pack.sh
FILEFORM_MEDIA_PACK="$PWD/Artifacts/MediaPack-MP3" swift test --filter MP3Tests
```

## Development verification

On September 9, 2026, the arm64 pack built and ran on macOS 26.2. All 26
selected tests passed (`MP3Tests`, existing media/trim cases and affected
inventory/direct-fetch cases). The MP3 cases cover 32/44.1/48 kHz, mono/stereo,
independent Apple decode, exact gapless-decoded sample counts, removal of a
source title, fit success/failure and legacy-pack rejection. `Tools/smoke-cli.sh`
also passed. A separate CLI WAV→MP3 fixture produced 35,328 bytes from a
410,348-byte source; Apple's decoder recovered exactly 102,576 stereo samples
at 48 kHz with nonzero signal. These are local development results; macOS 14,
x86_64 and signed app packaging still need their release checks.
