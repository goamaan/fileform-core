# Measured media timelines and previews

`MediaPreviewService(mediaPack:)` is the public runtime seam for editor previews.
It uses the verified local-only media pack and its isolated FFmpeg/ffprobe helpers;
no decoding or raw engine arguments belong in the native views.

`inspect` returns source identity, rational duration and signed clock origin,
audio ordinals and absolute stream indices, channel/sample-rate measurements,
and video geometry, orientation and decoded frame timing. Each preview checks
the supplied descriptor against current source identity and measured data.
The service caches one timeline; it does not persist media contents or file access.

`waveform` returns measured extrema for each channel separately, with exact
sample intervals. It does not downmix, pad the final bucket or invent missing
samples. Decoded audio continuity and coverage are checked before sample-index
mapping. Gaps, overlaps, incompatible origins and truncated coverage are explicit
limitations, rather than compressed or fabricated timeline regions.

`poster` decodes the frame at or immediately before a requested time, applies
source display orientation and returns a bounded PNG with the realized frame
time. `playbackPreview` creates a normalized temporary WAV or MP4 using verified
trim/conversion routes. Multitrack audio requires an explicit ordinal; mute is
explicit. The returned lease owns its private directory: retain it while a player
uses its URL, then call `discard` or release it. Native playback must stop and
release its item before discarding the lease. Source files are never removed.

The conservative first implementation generates a proxy on request. Oversized
video is resized after normalization, which can require two encoding passes.
Proxy creation retains the existing trim route restrictions. `originalPlaybackReliable`
is false until a native playback path has independent compatibility evidence.

Explicit export APIs use exclusive output transactions, reject source and hardlink
aliases, recheck source identity and keep temporary player artifacts separate
from final outputs. Normal preview generation does not publish a user result.

## CLI

Pass the verified pack using `--media-pack` or `FILEFORM_MEDIA_PACK`:

```sh
fileform media inspect recording.wav --json
fileform media waveform recording.wav --bins 512 --json
fileform media preview recording.wav --output playback.wav --json
fileform media preview recording.mp4 --audio-stream 1 --output playback.mp4 --json
fileform media preview recording.mp4 --poster-time 1.35 --max-dimension 512 --output poster.png --json
```

Inspection is bounded to six hours, 100,000 decoded video frames, sixteen audio
tracks and eight channels per track. Audio continuity checks retain the trim
runtime's 100,000 decoded-frame bound. Waveforms accept 16–4096 buckets and bound
each decoded aggregation buffer to 128 MiB. Diagnostics remain bounded by the
process runner; cancellation waits for helper termination before cleanup.

## Verification

The 89-test core suite passes locally. Focused tests prove opposite stereo channels
retain their envelopes, complete sample coverage, sample-exact normalized PCM,
source-change and cancellation rejection, safe lease cleanup and alias rejection.
Video tests verify measured frame count and poster color at its reported time,
resized playback dimensions and selection of a non-silent second track over a
silent first track. Gapped audio is rejected for both waveform and playback proxy.
`Tools/smoke-media-trim.py` also verifies the real CLI's timeline, waveform, poster
pixels and complete decoded playback samples. Native editor integration remains
separate work; these checks do not claim a complete native trimming workflow.
