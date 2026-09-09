# Embedded PDF image extraction

`pdf.extract-images` discovers unique image XObjects referenced by selected PDF pages’ resources, including inherited/indirect resource dictionaries and nested Form resources. It exports eligible original JPEG streams and reconstructed PNGs together in one new directory. This is separate from [rendering whole pages](PDF-page-images.md): extraction uses intrinsic image dimensions, without a DPI, page rotation, placement or clipping operation.

```sh
fileform pdf extract-images --input report.pdf --output report-images --pdf-pack ./Artifacts/PDFPack --dry-run --json
fileform pdf extract-images --input report.pdf --output report-images --pdf-pack ./Artifacts/PDFPack --json
fileform pdf extract-images --input first.pdf --input second.pdf --pages '2,1-3' --output selected-images --pdf-pack ./Artifacts/PDFPack --json
```

`FILEFORM_PDF_PACK` is also supported. The native worker must be installed alongside the CLI (or configured with `FILEFORM_WORKER_PATH`). Inputs are unencrypted PDFs; standalone image sources are rejected. CLI selection is one-based across concatenated inputs; the typed operation carries zero-based `PageReference` values. Omission selects all source pages. Repeated selections add no duplicate exports. Bind a physical source only once; repeated paths, symlinks and hardlinks to that same source are rejected. Independent copies remain distinct sources.

## Contract and provenance

The operation is `.pdfExtractImages(pages: [PageReference])` with a `.directory` output and `OutputFormat.images`. `images` is an explicit heterogeneous collection target, never a file codec. Each committed artifact still has its actual `.jpeg` or `.png` format. Extraction rejects nonzero page-reference rotations because it does not transform embedded pixels. Portable transformation requests and setups support the operation through the standard `transform` and `setup` commands.

`TransformationPlan.pdfImageExtraction` contains candidates and discovered/supported/skipped counts before execution. Each candidate records source ID, original object number **and generation**, resource-page references and paths, intrinsic dimensions, filters/color space, encoding outcome, alpha policy and an explicit skip reason where applicable. Result candidates add artifact name, actual byte count and SHA-256. `CommittedArtifact.pdfEmbeddedImage` carries the same per-image metadata for persistent artifact histories; `sourcePages` is also populated. These optional fields preserve older record decoding.

Deduplication is by source/object/generation, never content hash. One reused image exports once with all selected-page provenance. A soft mask reached only through `/SMask` is auxiliary and is not exported separately; if that object is independently referenced as a primary `/XObject`, that primary use is reported normally. Traversal detects Form cycles using the current path, preserving provenance through other paths.

**Resource references are not paint occurrences.** Unused resources may be included. Inline `BI/ID/EI` content, annotation appearances and patterns are outside this discovery policy. The operation neither enumerates every visible image nor reconstructs painted layout; there is no page-raster fallback.

## Encoding policy

The fixed initial policy is original where possible:

- A standalone single `/DCTDecode` stream with compatible 8-bit DeviceRGB/DeviceGray interpretation, no custom `/Decode`, no `/DecodeParms`, no masks and no alternate-image semantics is copied byte for byte. The isolated worker checks encoded JPEG type, complete decoding/end marker, intrinsic dimensions and channel count. Nonidentity JPEG orientation metadata is rejected. SHA-256 must match the extracted original stream.
- Other supported 8-bit DeviceRGB/DeviceGray samples use plain streams, Flate, ASCIIHex, ASCII85, RunLength or supported chains. qpdf decodes them; exact sample count is mandatory. The isolated worker produces PNG with straight RGBA and verifies an exact decoded RGBA round trip, including RGB values beneath zero alpha. Gray becomes equal RGB channels; opaque samples retain alpha 255.
- A soft mask must be a same-size 8-bit DeviceGray image with supported filters and no custom decode, Matte or nested-mask semantics. It supplies straight alpha. The mask is never silently discarded or flattened.

Current explicit skips include ICCBased/Indexed/CMYK/CalRGB/CalGray/Lab/Separation/DeviceN color, unusual bit depths, stencils, explicit `/Mask`, custom `/Decode`, `/Matte`, differing mask dimensions, JPX/JBIG2/CCITT, DCT filter chains or decode parameters, LZW and predictor parameters. Unsupported candidates are visible in plans and results. Runtime decode or verification failures fail the entire job and publish no folder; they are not relabeled as successful skips.

No-image and all-unsupported plans return useful counts and warnings. Attempting execution returns `unsupported` with a clear reason and creates no output. A successful job with unsupported candidates includes their reasons and a partial-extraction warning; it does not claim those candidates were extracted.

## Bounds and publication

Each job permits 128 source bindings, 1000 selected pages, 1000 unique image objects, 512 MiB cumulative source bytes, 512 MiB cumulative decoded RGBA budget and 512 MiB actual output. Individual images must fit 16384 pixels per edge and 64 million pixels; encoded streams are bounded to 256 MiB. Full qpdf JSON is file-backed and capped at 32 MiB per source. Object dictionaries are capped at 100000 objects; traversal at 100000 resource visits, 32 Form/indirection levels and 64 page-ancestry levels. Each provenance path is at most 4096 UTF-8 bytes and total retained path text at most 4 MiB per job. Exceeding a bound fails explicitly instead of dropping candidate/provenance records.

qpdf runs with time/cancellation and fresh-stat output checks. Streams are file-backed; output bytes are never collected in unrestricted stdout buffers. Native decoding/reconstruction runs through inherited descriptors in the isolated worker. The coordinator checks source identity before and after inspection/extraction, verifies checksums and stages every artifact before exclusive atomic folder publication. Collision `fail` preserves an existing output; `rename` selects a new name. Cancellation or any failure cleans staging and preserves sources.

## Verification

```sh
swift build
swift test --filter pdfImageExtraction
python3 Tools/smoke-pdf-image-extraction.py
# Retain reproducible native/CLI fixtures and JSON evidence:
python3 Tools/smoke-pdf-image-extraction.py --work Artifacts/Verification/pdf-image-extraction-cli
```

The source-owned generator exercises original JPEG bytes, exact straight RGBA including alpha zero, grayscale/generalized filters, inherited/indirect/nested/cyclic resource graphs, reuse and selection, actual nonzero object generation, explicit unsupported cases, malformed sample lengths, no-image plans, source aliases/changes/cancellation, encryption rejection, transform/setup persistence, output bounds, no-clobber/rename and source preservation. No new dependency or binary is introduced; this uses the same integrity-managed [qpdf PDF pack](PDF-optimization.md) and system CoreGraphics/ImageIO worker.
