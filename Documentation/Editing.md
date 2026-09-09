# First image and PDF editing routes

All routes are public/free library and CLI operations using the same versioned
request, immutable plan and verified artifact result. Image/PDF editing still runs
through native coordinator backends; full worker isolation remains open.

## Oriented image cropping

```sh
fileform image crop image.png --to png --x 100 --y 100 --width 600 --height 400 \
  --max-dimension 300 --output cropped.png --json
```

Pixels use a top-left origin after EXIF orientation is normalized exactly once.
Crop precedes optional longest-edge resize; resize never upscales. All eight
orientations have independent corner-pixel fixtures. PNG/TIFF preserve supported
alpha; JPEG requires an explicit background when the source has transparency.
`--max-bytes` enables bounded full-output fitting; failure publishes nothing.
Standard sRGB and descriptive metadata removal are explicit current policies.
Profile/metadata preservation and strict lossless requests fail instead of being
silently ignored. Full interactive crop handles and additional writers are client/
pack work, not capabilities implied by this initial route.

## PDF composition and splitting

```sh
fileform pdf merge first.pdf second.pdf photo.png --output combined.pdf --json
fileform pdf split combined.pdf --ranges '2;1,3' --output selected-pages --json
```

The merge command keeps source order and all source pages. Typed requests support
arbitrary ordered page references, duplicates and clockwise quarter turns. CLI
page syntax is one-based; internal indices are zero-based. Each image contributes
one page at one point per oriented pixel. No page sizing/margin policy is inferred.

Split groups preserve user order and duplicates. Every child PDF is staged and
verified before the complete new folder is exclusively renamed into place.
Cancellation/failure leaves no partial output set. Collisions default to failure;
`--collision rename` selects a new destination without replacing existing items.
Path/symlink/hardlink aliases of any source are rejected, including alternate
collision names. Sources are rechecked immediately before publication.

Initial bounds: 128 sources, 1000 output pages and 512 MiB total source bytes.
Encrypted/locked sources and strict lossless fidelity are rejected. Newly created
PDFs do not guarantee retention of document-level metadata, form behavior or
outlines; existing digital signatures do not certify the new document. These
consequences appear in plans/results. Reopened page count, text, boxes and rotation
are checked; adversarial source changes and cancellation are independently tested.
This does not implement PDF compression, redaction, password management or the
other advanced PDF operations.

Run `swift test` and `python3 Tools/smoke-editing.py` after building. The latter
executes actual CLI crop/merge/split commands, verifies dimensions/cardinality,
checks invalid ranges and retains source hashes. Client GUI acceptance is separate.
