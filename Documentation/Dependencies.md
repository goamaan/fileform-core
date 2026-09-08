# Dependency and distribution policy

Reviewed against upstream sources September 8, 2026. These are engineering packaging decisions, not clearance of an unbuilt distribution. The development media pack builds FFmpeg 9.0.1 from signature-verified source. Swift Argument Parser 1.8.2 is pinned for the CLI. Final customer distribution still requires signing and the recorded release gates.

| Candidate | Upstream terms / concern | Initial decision |
|---|---|---|
| Original Fileform core/CLI | Apache-2.0 | Publish source, license and attribution; retain these in app distributions |
| Swift Argument Parser 1.8.2 | Apache-2.0 | Exact SwiftPM dependency and Package.resolved; include its license in CLI archives |
| Apple ImageIO/CoreGraphics, AVFoundation, PDFKit, Vision | Platform SDK/framework terms | Use system APIs; test runtime and deployment-target availability |
| FFmpeg + ffprobe | LGPL baseline; enabled GPL components change the build license; nonfree configurations may not be redistributable | Start with a reproducible LGPL build, without GPL/nonfree options; inspect all enabled libraries. Prefer a separately packaged tool adapter. Broad-media release remains gated on that build |
| libvips | LGPL-2.1 license; codec dependencies have additional terms | Review exact dependency graph and linking/replacement obligations; no arbitrary prebuilt bundle |
| qpdf | Apache-2.0 in current upstream; bundled dependencies retain notices | Pin version and inventory dependencies before distribution |
| Pandoc | GPL | Optional standalone document tool under its own license; review actual communication/aggregation architecture and source distribution before shipping; do not link/copy it into proprietary app code |
| LibreOffice | MPL-2.0 with numerous separately licensed components | Optional headless pack; preserve full build-specific license inventory and applicable source obligations |
| Ghostscript | AGPL/commercial | Excluded until an explicit compliant distribution decision; qpdf does not replace every Ghostscript capability |

Before any engine pack is released, record exact version/revision, source archive and hash, build toolchain and flags, patches, transitive components, license texts/notices, binary hashes and signatures, source delivery location, and any replacement/relinking requirements. Verify runtime capabilities using that artifact and retain reproducible build instructions and an SBOM.

Do not assume running an executable separately automatically settles license compatibility. Do not use a developer's Homebrew binary as a distributable release artifact. App commercial terms must preserve recipients' rights to open components. Codec patent questions are separate from source-code licensing and remain a distribution review item.

Sources:

- [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)
- [FFmpeg legal guidance](https://ffmpeg.org/legal.html)
- [libvips license](https://github.com/libvips/libvips/blob/master/LICENSE)
- [qpdf license](https://qpdf.readthedocs.io/en/stable/license.html)
- [Pandoc license](https://github.com/jgm/pandoc/blob/main/COPYING.md)
- [LibreOffice licenses](https://www.libreoffice.org/licenses/)
- [Ghostscript licensing](https://www.ghostscript.com/licensing/)
