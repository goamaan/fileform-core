# Versioned transformations

The additive v1 contract keeps existing `ConversionRequest`, conversion JSON and
`convert`/`compress`/`fit` commands compatible. `TransformationRequest` describes
ordered named local assets, a typed operation, output file/directory, fidelity and
collision policies. Unknown versions and invalid combinations fail explicitly.

`Examples/Transformations` contains conversion, composition, split, crop, trim and
link request shapes. Replace the `FILEFORM_FIXTURES` and `FILEFORM_OUTPUTS` paths
before use. Conversion, oriented image crop, PDF composition and PDF split now execute.
Media trim and link acquisition remain schema-only and fail closed.
See Editing.md for current bounds and declared losses.

Payload encoding is a single case key with named fields (or `_0` for a single
unnamed associated value). This encoding is fixed for schema version 1. Page
indices are zero-based; repeated pages and their order are meaningful. Split
groups describe an atomic directory output, distinct from independent batch jobs.
Crops are top-left pixel coordinates after orientation. Media intervals are
half-open `[start,end)` rational ticks/timescale; comparisons do not round through
floating point. Inspection must additionally validate page, crop and time bounds.

```sh
fileform transform request.json --dry-run --json
fileform transform request.json --json
fileform setup create request.json --name 'My setup' > setup.json
fileform setup apply setup.json --asset source=/path/new-input.png --output /path/result.png --json
fileform capabilities --input /path/new-input.png --inventory
```

Portable setups store ordered source slots, operation settings and output format,
never source/destination paths or bookmarks. Bind all slots explicitly in order.
Link URLs cannot be saved in setups because their query strings may contain
credentials. JSON input is capped at 1 MiB. UI history and security-scoped bookmarks
are separate responsibilities. CLI stdout carries JSON; progress uses stderr.

Planning records identities for all assets. Runtime treats serialized plans as
untrusted, revalidates requests and source identity, and derives its backend again.
Caller-supplied warnings do not authorize an operation. The migration adapter
rejects color/metadata preservation or strict lossless policies that the legacy
converter cannot guarantee. Path, symlink and hardlink source aliases are rejected,
including with keep-both naming. Final output still uses exclusive rename.

`JobRuntime.submit` yields a job ID and bounded asynchronous event stream. Sequence
numbers are monotonic; a terminal success/failure follows engine cleanup exactly
once. Slow readers may lose older progress events, but the final event is retained.
Cancellation is cooperative until the native worker is integrated; this contract
does not claim native parser crash isolation. Completed output remains successful
if cancellation races after commit. Independent jobs retain independent results.

The versioned capability inventory records operation IDs, applicable families,
output cardinality, actual installed backend version, local-processing status,
limitations and verification method. It is a runtime inventory, not a release
acceptance certificate. An actual request still needs planning; options such as
alpha flattening or PDF page selection may be mandatory. No new route is enabled
merely by adding an enum case. Release inventories must be captured alongside exact
source revision, platform, pack hashes and fixture evidence.

Verify using `swift test`, `Tools/smoke-cli.sh`, and
`python3 Tools/smoke-transformations.py` after building the CLI.
