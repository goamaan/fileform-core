// SPDX-License-Identifier: Apache-2.0
import Foundation
import ArgumentParser
import FileformDomain
import FileformCore

struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "image", abstract: "Edit oriented still images.", subcommands: [ImageCrop.self])
}
struct ImageCrop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "crop", abstract: "Crop oriented pixels, then optionally resize or fit a byte limit.")
    @OptionGroup var job: JobArguments
    @Option(help: "Left edge in oriented pixels.") var x = 0
    @Option(help: "Top edge in oriented pixels.") var y = 0
    @Option(help: "Crop width in pixels.") var width: Int
    @Option(help: "Crop height in pixels.") var height: Int
    @Option(help: "Optional exact maximum output bytes.") var maxBytes: Int64?
    mutating func run() async throws {
        do {
            let input = URL(fileURLWithPath: job.input)
            let output = job.output.map { URL(fileURLWithPath: $0) } ?? input.deletingLastPathComponent()
                .appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-cropped.\(job.format.fileExtension)")
            let options = ConversionOptions(quality: job.quality, minimumQuality: job.minimumQuality, maxDimension: job.maxDimension,
                                            maximumBytes: maxBytes, background: job.background, minimumVideoBitrate: job.minimumVideoBitrate,
                                            pageNumber: job.page)
            let request = try TransformationRequest(assets: [.init(id: "source", url: input)],
                operation: .imageCrop(rectangle: .init(x: x, y: y, width: width, height: height), conversion: .init(goal: maxBytes == nil ? .convert : .fit, options: options)),
                output: .init(destination: output, format: job.format), collisionPolicy: job.collision)
            try await executeEditing(request, engine: makeEngine(job.mediaPack), dryRun: job.dryRun)
        } catch { try fail(error, json: job.json) }
    }
}
struct PDFCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pdf", abstract: "Compose and split PDFs using verified page order.", subcommands: [PDFMerge.self, PDFSplit.self, PDFPages.self])
}
struct PDFMerge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "merge", abstract: "Combine ordered PDFs and still images into one PDF.")
    @Argument(help: "Ordered source files.") var inputs: [String]
    @Option(help: "New PDF output path.") var output: String
    @Option(help: "Collision policy: fail or rename.") var collision: CollisionPolicy = .fail
    @Flag(help: "Inspect and emit a plan without saving files.") var dryRun = false
    @Flag(help: "Emit structured errors/results.") var json = false
    mutating func run() async throws {
        do {
            guard !inputs.isEmpty, inputs.count <= 128 else { throw FileformError(.invalidRequest, "Provide between 1 and 128 PDF/image sources.") }
            let assets = inputs.enumerated().map { AssetReference(id: "source-\($0.offset + 1)", url: URL(fileURLWithPath: $0.element)) }
            let engine = makeEngine(nil), output = URL(fileURLWithPath: output), dryRun = dryRun, collision = collision
            try await cancellable {
                var pages: [PageReference] = []
                for asset in assets {
                    let info = try await engine.inspect(asset.url)
                    guard [.image, .pdf].contains(info.family) else { throw FileformError(.unsupported, "PDF composition accepts PDFs and still images.") }
                    pages += (0..<(info.pageCount ?? 1)).map { PageReference(sourceID: asset.id, pageIndex: $0) }
                }
                let request = try TransformationRequest(assets: assets, operation: .pdfComposition(pages: pages),
                                                        output: .init(destination: output, format: .pdf), collisionPolicy: collision)
                try await performEditing(request, engine: engine, dryRun: dryRun)
            }
        } catch { try fail(error, json: json) }
    }
}
struct PDFSplit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "split", abstract: "Publish selected page groups as one complete output folder.")
    @Argument(help: "PDF input file.") var input: String
    @Option(help: "One-based groups separated by semicolons, e.g. '1-3;4,2;5'. Order and duplicates are retained.") var ranges: String
    @Option(help: "New output directory.") var output: String
    @Option(help: "Collision policy: fail or rename.") var collision: CollisionPolicy = .fail
    @Flag(help: "Emit a plan without saving.") var dryRun = false
    @Flag(help: "Emit structured errors/results.") var json = false
    mutating func run() async throws {
        do {
            guard ranges.utf8.count <= 16384 else { throw FileformError(.resourceLimit, "The page selection is too long.") }
            var totalPages = 0
            let groups = try ranges.split(separator: ";", omittingEmptySubsequences: false).map { group -> [PageReference] in
                var pages: [PageReference] = []
                for part in group.split(separator: ",", omittingEmptySubsequences: false) {
                    let bounds = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
                    guard (1...2).contains(bounds.count), let start = Int(bounds[0]), start > 0, start <= 1000,
                          let end = bounds.count == 2 ? Int(bounds[1]) : start, end >= start, end <= 1000 else {
                        throw FileformError(.invalidRequest, "Use one-based pages or increasing ranges between 1 and 1000.")
                    }
                    totalPages += end - start + 1
                    guard totalPages <= 1000 else { throw FileformError(.resourceLimit, "A split operation accepts at most 1000 selected pages.") }
                    pages += (start...end).map { .init(sourceID: "source", pageIndex: $0 - 1) }
                }
                return pages
            }
            let request = try TransformationRequest(assets: [.init(id: "source", url: URL(fileURLWithPath: input))], operation: .pdfSplit(groups: groups),
                output: .init(destination: URL(fileURLWithPath: output), format: .pdf, cardinality: .directory), collisionPolicy: collision)
            try await executeEditing(request, engine: makeEngine(nil), dryRun: dryRun)
        } catch { try fail(error, json: json) }
    }
}
private func executeEditing(_ request: TransformationRequest, engine: ConversionEngine, dryRun: Bool) async throws {
    try await cancellable { try await performEditing(request, engine: engine, dryRun: dryRun) }
}
private func performEditing(_ request: TransformationRequest, engine: ConversionEngine, dryRun: Bool) async throws {
    let plan = try await engine.plan(request)
    if dryRun { try emit(plan); return }
    for warning in plan.warnings { diagnostic(warning) }
    try emit(await engine.run(plan) { diagnostic($0.phase.rawValue) })
}

struct PDFPages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pages", abstract: "Export selected PDF/image pages as full-resolution PNG or JPEG images in one folder.")
    @Option(name: .customLong("input"), help: "Source PDF or still image; repeat in document order.") var inputs: [String] = []
    @Option(help: "One-based pages/ranges in the concatenated inputs, e.g. 3,1-2,3. Omit for every page.") var pages: String?
    @Option(help: "Explicit render resolution, 36–600 DPI.") var dpi: Int = 144
    @Option(name: .customLong("to"), help: "Output image format: png or jpeg.") var format: OutputFormat = .png
    @Option(help: "JPEG quality from 0.05 to 1; PNG encoding is lossless.") var quality: Double = 0.9
    @Option(help: "New output directory; every selected page is published together.") var output: String
    @Option(help: "Collision policy: fail or rename.") var collision: CollisionPolicy = .fail
    @Flag(help: "Inspect and validate every selected page without saving files.") var dryRun = false
    @Flag(help: "Emit structured errors/results.") var json = false
    mutating func run() async throws {
        do {
            guard (1...128).contains(inputs.count), [.png, .jpeg].contains(format), (36...600).contains(dpi), quality.isFinite, (0.05...1).contains(quality) else { throw FileformError(.invalidRequest, "Use 1–128 inputs, PNG/JPEG, 36–600 DPI and quality 0.05–1.") }
            let assets = inputs.enumerated().map { AssetReference(id: "source-\($0.offset + 1)", url: URL(fileURLWithPath: $0.element)) }
            let selection = pages, dpi = dpi, quality = quality, format = format, destination = URL(fileURLWithPath: output), collision = collision, dryRun = dryRun
            // Inspect through the same isolated worker used for rendering.
            let workerURL = ProcessInfo.processInfo.environment["FILEFORM_WORKER_PATH"].map { URL(fileURLWithPath: $0) }
                ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("fileform-worker")
            let worker = NativeWorkerClient(executable: workerURL)
            try await cancellable {
                var all: [PageReference] = []
                for asset in assets {
                    let info = try await worker.inspect(asset.url)
                    guard [.pdf, .image].contains(info.family) else { throw FileformError(.unsupported, "Use PDF or still-image inputs.") }
                    let count = info.family == .pdf ? info.pageCount ?? 0 : 1
                    guard count > 0, all.count + count <= 128_000 else { throw FileformError(.resourceLimit, "Source page inventory exceeds limits.") }
                    all += (0..<count).map { PageReference(sourceID: asset.id, pageIndex: $0) }
                }
                let chosen: [PageReference]
                if let selection {
                    guard !selection.isEmpty, selection.utf8.count <= 16384 else { throw FileformError(.invalidRequest, "Provide a bounded page selection.") }
                    var selected: [PageReference] = []
                    for part in selection.split(separator: ",", omittingEmptySubsequences: false) {
                        let bounds = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
                        guard (1...2).contains(bounds.count), let start = Int(bounds[0]), start > 0,
                              let end = bounds.count == 2 ? Int(bounds[1]) : start, end >= start, end <= all.count else { throw FileformError(.invalidRequest, "Choose existing one-based pages or increasing ranges.") }
                        guard end - start + 1 <= 1000 - selected.count else { throw FileformError(.resourceLimit, "Export at most 1000 pages per job.") }
                        selected += all[(start - 1)..<end]
                    }
                    chosen = selected
                } else { chosen = all }
                let request = try TransformationRequest(assets: assets, operation: .pdfRasterize(pages: chosen, dpi: dpi, quality: quality),
                    output: .init(destination: destination, format: format, cardinality: .directory), collisionPolicy: collision)
                try await performEditing(request, engine: makeEngine(nil), dryRun: dryRun)
            }
        } catch { try fail(error, json: json) }
    }
}
