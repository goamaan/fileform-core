# Downloader runtime feasibility

Measured on macOS 26.2 on September 9, 2026. This is a reproducible dependency
probe, not an enabled acquisition adapter or a service-coverage claim.

## Pinned artifact

- Upstream: [yt-dlp 2026.08.19](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19).
- Asset: `yt-dlp_macos.zip`, 53,923,637 bytes.
- SHA-256: `07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8`,
  verified before extraction against the immutable release asset digest.
- Extracted artifact: 134 files, 130,010,634 logical bytes. Includes Python 3.14
  and EJS solver scripts; no ambient Python is needed.
- Main executable contains arm64 and x86_64. Both native launch and an explicit
  `arch -x86_64 ... --version` under Rosetta returned `2026.08.19`.
- Its existing signature verifies but is ad-hoc, has no Team Identifier and no
  sealed resources. This is not notarization or proof of a Fileform-signed pack.
- Bundled `THIRD_PARTY_LICENSES.txt` includes GPL/LGPL components such as GNU
  Readline, mutagen, libintl, libidn2 and libunistring. The upstream project's
  Unlicense alone does not describe the distributed aggregate. Preserve the
  exact artifact's notices and source-compliance materials in a separately
  versioned pack; it is not being incorporated into this library's license.

The [tagged README](https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/README.md)
and [EJS instructions](https://github.com/yt-dlp/yt-dlp/wiki/EJS) document the
runtime controls and bundled solver distinction. This probe disables JavaScript
runtimes; a pinned JS runtime and its execution restrictions still need proof.

## Reproduce

After obtaining and hash-checking that exact archive, extract it preserving
executable permissions. Build the ordinary Fileform MediaPack, then run:

```sh
python3 Tools/spike-downloader.py \
  --downloader Artifacts/DownloaderSpike/unpacked/yt-dlp_macos \
  --media-pack Artifacts/MediaPack \
  --report Artifacts/DownloaderSpike/report.json
```

The script generates its own MP4, audio, HLS segments and two-item page. A local
HTTPS server binds only loopback. Its ephemeral fixture CA is trusted only in
the child process, never installed in the system. A negative invocation without
that CA must fail certificate verification. No third-party media or account is
accessed. A deliberately invalid configuration in an isolated config directory
proves `--ignore-config` is effective. Plugins, self-updates, remote components,
JS runtimes, filesystem cache and ambient proxies are disabled explicitly.
The script removes its owned temporary fixtures, server and partial files.

## Observed results

| Probe | Result |
|---|---|
| Direct HTTPS MP4 | Downloaded bytes exactly equal the generated source |
| Relative HTTPS redirect | Downloaded bytes exactly equal the generated source |
| Missing Content-Length | Complete download still matches source bytes |
| HTML with two video items | Discovery returns two actual entries |
| HLS with three segments | Complete decode returns all 30 color-marker frames |
| Untrusted fixture certificate | Rejected with certificate verification failure |
| Maximum size, known length | Exit 0, no output when 1,024-byte limit is exceeded |
| Maximum size, unknown length | Exit 0, **31,084-byte output despite 1,024-byte limit** |
| Termination during slow download | Process group stops; downloader leaves a `.part` file |

The exact generated encoded byte count can vary by encoder build; the size-limit
counterexample is the output exceeding the requested ceiling, not a fixed size.

## Consequences for implementation

`--max-filesize` and process exit status cannot enforce Fileform's byte contract.
A Fileform runtime must count incoming bytes independently, terminate before the
configured ceiling is exceeded, remove only its own staging, verify the complete
media and publish through an output transaction. Cancellation must finish worker
cleanup before becoming terminal. The ordinary media ProcessRunner currently
manages its direct child; a downloader that launches interpreters/postprocessors
needs process-group ownership rather than assuming that helper is sufficient.

Production URL/address and redirect policy must cover every extracted resource,
including playlist segments, images and subtitle resources. The probe's loopback
fixture exception is not a production policy. No browser cookies, credential
files or arbitrary downloader arguments are part of this API.

Still open: signed pack installation and rollback, nested executable verification,
sandboxed application launch, pinned JS runtime, macOS 14 runtime testing, resource
and output-size enforcement, real per-service fixtures, public acquisition
contracts/CLI and native discovery/download/editor integration. No service is
marked supported merely because the extractor appears in yt-dlp's inventory.
