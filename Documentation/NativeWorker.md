# Native worker protocol and first acceptance slice

`fileform-worker` is a public executable built without the private application.
It currently isolates image/PDF inspection and oriented PNG preview rendering.
Full conversion/OCR/composition still use the existing engine and have not yet
migrated into the worker. Do not claim that all native parsing is isolated.

The coordinator selects the executable through trusted configuration. Requests
carry inherited source/output descriptor numbers, never executable paths, shell
commands or arbitrary backend flags. The worker requires a v1 handshake followed
by exactly one typed operation. Responses echo request IDs; inspection payloads
exclude source paths and the coordinator rebinds their asset identity.

Framing is a four-byte unsigned big-endian JSON length over stdin/stdout pipes,
with a 1 MiB frame ceiling. Zero, oversized, truncated, unknown-version and malformed
messages fail. Incremental decoding tolerates fragmented/coalesced writes. The
launcher drains nonblocking output under a two-frame bound. Parser diagnostics
are not exposed as arbitrary stderr strings.

The launcher snapshots the source identity, opens it read-only, verifies `fstat`
against the snapshot, and uses `posix_spawn` file actions to transfer only the
selected descriptors. A private scratch directory owns output and worker temp
files. `TMPDIR` is inherited explicitly so crash cleanup remains coordinator-owned.
Worker copies are bounded at 512 MiB; PNG dimensions are bounded at 4096 pixels.
The output handle must be empty, writable, regular, singly linked and distinct
from the source. No worker commits a final user destination.

The process gets a dedicated group. Monotonic wall timeout and cancellation kill
the group; `waitid(..., WNOWAIT)` reserves the leader PID until descendant teardown
is signaled, then the leader is reaped before scratch cleanup. Even a leader that
exits before its child cannot leave a live writer behind. Poll waits remain bounded
when the Swift task is already cancelled. Worker CPU, core-dump and per-file-size
limits are also installed. These are not a guarantee against every kernel hang or
a complete memory-pressure policy; further resource testing remains necessary.

```sh
swift build
.build/debug/fileform inspect image.png --worker .build/debug/fileform-worker --json
.build/debug/fileform preview image.png --output preview.png --maximum-dimension 240 --json
.build/debug/fileform preview document.pdf --output page.png --page 2 --json
```

Preview output is explicitly a bounded sRGB rendering, not a full-fidelity export.
The CLI archive includes the matching worker, its hash/protocol version and the
runtime capability inventory. Development signatures are not notarization.

Current automated evidence: framing adversarial cases; descriptor alias/offset/
size safety; rotated non-square PDF with a nonzero media-box origin and colored
content assertions; real subprocess image inspection/PNG decoding; malformed input
recovery; child-leader exit ordering; timeout/cancel/flood cleanup. Native sandbox
host acceptance on arm64/macOS 26.2 separately confirmed a selected source handle
reaches the inherited-sandbox worker while an unselected sibling stays denied.
That test does not establish universal/older-OS support or full conversion isolation.

Run `swift test`, `Tools/smoke-cli.sh` and `python3 Tools/smoke-transformations.py`.
New native operations must retain the same file-access, framing and cleanup
constraints and gain independent content tests before client UI adoption.
