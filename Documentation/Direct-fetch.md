# Verified direct media fetch

The shared `TransformationOperation.fetch` adapter and `fileform fetch` commands
save original media bytes from an explicitly requested HTTP(S) URL. They do not
extract media from arbitrary web pages or convert the source to another format.
Those choices require the separately reviewed downloader/transform workflow.

```sh
fileform fetch lookup https://example.org/recording.wav --json
fileform fetch save https://example.org/recording.wav --to wav \
  --output ./recording.wav --max-bytes 52428800 --media-pack ./MediaPack --json
```

The examples describe command syntax, not a hosted sample at example.org.
`--dry-run` on `fetch save` contacts the source with HEAD and returns a bound plan,
but downloads no media and publishes no output. `lookup` does not require the
media pack; `save` requires it for independent decoding. HTTP is permitted when
explicitly present in the input URL and disclosed in the plan. HTTPS redirects
never downgrade. No browser cookies, login state or credential store is used.

## Plan and execution

`TransformationPlan.fetchSource` stores the requested/resolved URL, content type,
length and available ETag/Last-Modified validators. Execution repeats lookup and
compares the snapshot; a serialized plan cannot substitute an unrelated resolved
URL or omit observed properties. GET uses strong If-Match, or If-Unmodified-Since
when available, and also checks the response properties and received length.
Changed bindings return `input_changed`. Sources without strong validators have
an explicit warning: HEAD cannot establish an immutable content hash.

The bounded transport enforces actual retained bytes for known and unknown
lengths. After receiving, a job-owned output transaction stages a copy. Verification
forces the expected demuxer (rather than following an unexpected playlist), disables
MOV external data references, checks container/stream limits, decodes every audio
and video stream with errors treated as failures, and requires nonzero decoded
time. The candidate must match the download's actual byte count and SHA-256.
Only then does exclusive atomic publication occur. `--collision rename` keeps
existing paths; the default fails. Cancellation cleans owned staging after its
network/decoder work terminates.

Supported direct source types are MP4, MOV, M4A, WAV, FLAC and MP3. A different
container or HTML payload fails instead of receiving a misleading extension.
MP3 here means preserving an existing MP3; separate [MP3 conversion](MP3-output.md) requires the MP3-enabled media pack. Limits
include the requested ceiling (at most 8 GiB), 120 seconds per network transfer,
six hours of media, four video/eight audio streams (16 streams total), eight audio
channels per track, 192 kHz, 64 million pixels per video frame and ten minutes for
verification. The original downloaded metadata is preserved, not stripped.

Receipts contain source host, actual bytes and SHA-256, without signed URL queries.
Plans contain source URLs and must be treated as sensitive local work records.
Fetch URLs remain forbidden in portable saved setups. Capability inventory marks
these routes as requiring network access and the verification pack.

## Evidence

`DirectFetchTests` verifies byte identity, plan serialization, conditional requests,
changed validators, false MIME/body types, forged source binding, exclusive name
handling and the distinction between network fetch and separately available MP3 encoding.
Together with the transport and existing suites, 98 local tests passed.

```sh
python3 Tools/smoke-direct-fetch.py --cli .build/debug/fileform \
  --media-pack Artifacts/MediaPack
```

The independent CLI smoke generates its own WAV and local HTTP server. It checks
lookup, dry-run, received byte hash, verified publication, collision/rename, type
mismatch, size limit and staging cleanup. `Tests/Fixtures/direct-fetch.wav` provides
a small synthetic fixture for a separate pinned-commit HTTPS check.

The native link editor, HEAD-incompatible source handling, provider/item/quality
extraction and signed downloader-pack installation remain separate work. Do not
claim service coverage from this direct-file adapter.
