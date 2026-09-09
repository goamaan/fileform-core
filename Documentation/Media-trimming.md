# Measured local media trimming

The shared engine and standalone CLI trim real media with the existing verified
FFmpeg pack. No additional encoder is bundled by this route. The native timeline,
waveform and playback editor are separate client work.

```sh
fileform media trim recording.wav --to wav --start 48001/48000 --end 144013/48000 --output excerpt.wav --json
fileform media trim recording.mp4 --to mp4 --start 1.35 --end 3.57 --output exact.mp4 --json
fileform media trim recording.mp4 --to mp4 --start 1.35 --end 3.57 --mode copy --output fast.mp4 --dry-run --json
fileform media trim recording.mp4 --to m4a --start 1.35 --end 3.57 --mode copy --audio-stream 0 --output audio.m4a --json
```

Set `FILEFORM_MEDIA_PACK` or pass `--media-pack` to select the same public media
pack used for conversion. Decimal seconds accept up to nine fractional places;
`ticks/timescale` preserves exact rational sample/frame requests. Intervals are
half-open `[start,end)` in a zero-based source playback clock. A shared nonzero
container/stream timestamp origin is accounted for; differing picture/audio
start offsets require a separate synchronization workflow and fail explicitly.

## Exact and copy behavior

Exact mode selects frame or sample onsets within the requested interval. A video
request between frames therefore rounds its start and end upward to frame
boundaries; a range containing no frame onset fails. Audio-only requests use
sample boundaries. When picture is retained, audio follows the same realized
picture range to retain synchronization. The plan reports both the requested and
realized ranges before execution. It never silently cuts at a preceding GOP.

Before an exact trim maps source time to sample indices, it validates every
decoded audio frame's timestamp against cumulative sample counts. Gaps, overlaps,
missing timestamps and clocks that cannot resolve exact sample positions fail
explicitly, including audio accompanying video. This prevents a timestamp gap
from shifting the exported content to a different part of the recording. The
same check runs again when executing a saved plan.

Exact video writes H.264 with optional AAC to MP4/MOV. Exact audio writes WAV
(16-bit PCM), FLAC (integer input up to 24 bits), or M4A/AAC. WAV reduces higher
source precision explicitly; FLAC trim rejects floating-point decoded input.
AAC/H.264 re-encoding can lose detail. Integer PCM/FLAC routes that preserve the
source sample precision compare independent hashes of decoded selected samples
and decoded output samples; rewriting PCM does not itself imply lost quality.

Copy mode is a narrower verified route: H.264 without reordered frames and AAC
from MP4/MOV-family inputs into MP4/MOV, or AAC into M4A. Picture starts snap to the
preceding eligible keyframe and ends snap to the following keyframe (or the
source end), enclosing the requested interval. Audio-only copy uses enclosing
AAC packet boundaries even when extracted from a file with an unselected picture
stream. It copies encoded packets and verifies their payload hashes and timeline
against the source. A decode failure or mismatch publishes nothing.

AAC packets accompanying copied picture may overlap either selected edge by one
packet. Plans report that explicit tolerance; results report the actual measured
container duration. This is not a sample-exact AAC cut, and the output may be
slightly longer than the snapped picture interval. Exact mode is available when
re-encoding to tighter boundaries is preferable.

## Explicit mute

Use `fileform media trim recording.mp4 --to mp4 --start 1 --end 3 --mute --output silent.mp4`
to omit every audio track intentionally. Muting works with exact and eligible copy
video trims, including inputs with several audio tracks. Plans declare the audio
removal and output verification requires zero audio streams. `--mute` rejects
audio-only outputs and cannot be combined with `--audio-stream`.

The Swift operation uses `muteAudio: true`; portable JSON writes the distinct
`mediaTrimMuted` tag so older clients reject this work instead of accidentally
keeping sound. Unmuted work retains the original `mediaTrim` v1 payload exactly.
A `muteAudio: true` field under the legacy tag is rejected. Existing v1 records
decode as unmuted: an absent audio-stream selection still means choose
the only available track automatically, or ask for an explicit selection if there
are several. Muting does not bypass the picture timestamp, codec or fidelity
constraints. It intentionally avoids validating discarded audio as part of the
output timeline.

## Contracts and limits

`TransformationOperation.mediaTrim` works through `ConversionEngine`,
`JobRuntime`, `fileform transform` and portable setups as well as the command
above. `TransformationPlan.mediaTrim` and `TransformationResult.mediaTrim` are
optional additive measurements; older records decode with `nil`. Each
`MediaTrimDetails` contains requested/realized source ranges, mode, whether
streams were copied, duration tolerance and, for results, measured output
duration. Resolved stream indices are **absolute ffprobe indices**; request
`audioStream` and CLI `--audio-stream` are **zero-based audio-only ordinals**.
Multiple audio tracks require an explicit ordinal. Unselected tracks, chapters,
descriptive metadata and cover artwork have declared losses.

The initial route accepts one selected picture stream, constant frame timing,
even dimensions, square pixels and supported 8-bit SDR without alpha. Variable
frame timing, gaps, retained subtitles/data/attachments, HDR and video alpha are
not implemented. Fast mode additionally rejects reordered frames and other
containers/codecs. Packet inspection and decoded-audio-frame inspection are each
bounded to 100,000 records per selected stream and the process runner's 16 MiB
diagnostic cap; unusually long/dense
recordings may hit that bound before the six-hour source limit. A timeout or
bound failure is explicit and cannot become partial-output success.

Media fit-size constraints, joining, broad stream preservation and MP3 are not
provided by the trim payload. Strict whole-file lossless fidelity requests fail
because metadata and unselected streams are not preserved. Capability inventory
lists the installed trim operation and output formats; an actual request still
needs planning to establish supported timing and stream properties.

Execution revalidates the input identity, stream selection and measured interval.
If a saved plan would snap differently, it fails and requires a new plan. It
does not trust serialized metadata or backend flags. Work uses the shared
single-heavy-job gate and process cancellation policy. Every output is staged on
the destination filesystem, fully decoded, checked for frame/stream count,
codec, dimensions, sample rate/channels and measured duration, then published
with exclusive rename. Source path/symlink/hardlink aliases are rejected even
with keep-both naming. Originals and racing destinations remain unchanged.

## Verification

```sh
swift test
Tools/smoke-cli.sh
python3 Tools/smoke-media-trim.py
```

The media pack must already exist; use its documented source build when missing.
Tests use synthetic PCM samples and six-second, color-marked H.264/AAC recordings
with one-second GOPs. They verify exact sample content, all selected frame
markers, audio phase relative to picture, encoded packet hashes, snapped source
bounds, actual duration, invalid ranges, explicit multiple-track selection,
source identity changes, aliases, cancellation and racing output preservation.
An amplitude-marked AAC regression independently demonstrates that timestamp
selection across an interior gap differs from decoded-sample indexing, then
requires the unsupported clock to be rejected for both audio-only and video
outputs.
CLI smoke independently decodes output bytes and exercises real commands,
dry-run, structured errors and capability export.

FFmpeg distinguishes input seeking, which can retain material preceding a seek
point during stream copy, from output-side discard. The implementation uses
that distinction deliberately and verifies the realized content instead of
assuming `-ss` alone establishes exactness. See [FFmpeg seeking and stream copy](https://ffmpeg.org/ffmpeg.html)
and [FFmpeg trim/atrim filters](https://ffmpeg.org/ffmpeg-filters.html).
