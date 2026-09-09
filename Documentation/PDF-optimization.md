# PDF structural optimization

The `qpdf` route supports PDF `compress` and `fit` using a verified PDF engine pack and an isolated native worker. It retains every page. It does not rasterize the document, resize images or introduce lossy JPEG encoding. A fit attempt may fail with `targetUnmet`; compression returns `notSmaller` without publishing when the candidate is not smaller.

Configure `ConversionEngine(mediaPack:pdfPack:workerExecutable:)`; all arguments are optional. The PDF pack uses `manifest.json` schema 1, ID `app.fileform.pdf`, a version string and `executables.qpdf` containing the SHA-256 of `bin/qpdf`. Pack integrity is checked again at execution. The worker defaults to `FILEFORM_WORKER_PATH` or a sibling `fileform-worker`. Apps should pass their bundled helper explicitly.

Typed `TransformationRequest` conversion operations require `.preserve` color, `.preserve` metadata and `.requireLossless` fidelity. Here lossless means structurally rewritten PDF with preserved content, not identical file bytes. Legacy PDF compress/fit and their typed migration explicitly adopt that policy. Non-preserving typed policies are rejected. Page-selection, resizing and background options are not supported for this route.

The CLI accepts `--pdf-pack`, `FILEFORM_PDF_PACK`, or an adjacent `PDFPack` for `compress`, `fit`, `transform`, `setup apply` and capability reporting. Example:

```sh
fileform compress input.pdf --to pdf --pdf-pack ./PDFPack --output optimized.pdf
fileform fit input.pdf --to pdf --max-bytes 1000000 --pdf-pack ./PDFPack --output fitted.pdf
```

Capabilities expose a distinct `qpdf` PDF route with goals `compress` and `fit`; clients must match both format and goal. The existing `documents` PDF route still means selected-page export.

The optimizer checks source/output structural validity with qpdf, compares every page's independently decoded content streams, text, five page boxes, rotation and bounded raster pixels using CoreGraphics/PDFKit in a worker, and compares scalar Info metadata plus decoded XMP. Signed/encrypted documents, annotations/forms, outlines, attachments, JavaScript/actions, tagged PDFs, optional content and complex metadata are rejected. No sanitization, PDF/A conformance or byte-identical signature preservation is claimed. Object stream generation can raise the minimum PDF version to 1.5.

Inputs and candidates are limited to 512 MiB and documents to 1,000 pages. Workers enforce time/CPU and file limits; verification rendering is capped at 2,048 pixels per edge and 144 DPI. Traversal and decoded content size limits reject overly complex documents. The local qpdf process has a 120-second optimization deadline with monitored output size and bounded diagnostics. Raster equality at that resolution is supporting evidence, not a universal visual equivalence proof; the structural route uses only lossless qpdf filters and verifies decoded page content independently.

Before publication the engine checks source identity and SHA-256, candidate validity and the requested byte constraint. Owned temporary output is cleaned on failure/cancellation. Finalization uses the existing exclusive, atomic output transaction and never overwrites a source or existing destination.

See [Dependencies](Dependencies.md) and the public PDF pack recipe for exact dependency/distribution information. `PDFOptimizationTests` exercise a source-owned three-page text/vector fixture with nonzero boxes and 0/90/180-degree rotation, exact fit boundaries, not-smaller, unsupported policies/features, pack integrity, cancellation, changed sources and safe output publication.

Build the pack with `Tools/build-pdf-pack.sh` (CMake, Ninja and an Apple C++20 toolchain). It pins qpdf 12.4.1 (`f045aa277be2356ff53a89a8622945958291177d2483afc20ede7c8a8cd3873c`) and libjpeg-turbo 3.2.0 (`6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e`) source archives. Hash verification is not detached-signature verification. The pack contains both source archives, build recipe/cache flags, component manifest, upstream licenses/notices and required IJG attribution. qtest's Artistic license covers source-only testing material; the runtime CLI uses static libqpdf/libjpeg and Apple system libraries. No Homebrew runtime binaries are bundled.

The recipe defaults to the host architecture and a macOS 14 deployment target. An x86_64 JPEG SIMD build additionally needs NASM. Customer signing/notarization, actual supported-OS and Intel execution, clean installation and release-source delivery remain release gates; a deployment-target field is not runtime proof. Use `Tools/package-cli.sh --with-pdf` to include the pack in a development CLI archive. `python3 Tools/smoke-pdf-optimization.py` exercises real CLI discovery, planning and terminal byte-limit outcomes; `--work <new-directory>` retains its synthetic fixture and evidence for native acceptance.
