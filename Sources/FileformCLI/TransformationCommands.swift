// SPDX-License-Identifier: Apache-2.0
import Foundation
import ArgumentParser
import FileformCore
import FileformDomain

struct Transform: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Validate or execute a versioned transformation request.")
    @Argument(help: "JSON transformation request file (maximum 1 MiB).") var request: String
    @Option(help: "Media engine pack directory.") var mediaPack: String?
    @Option(help: "PDF engine pack directory; also accepts FILEFORM_PDF_PACK.") var pdfPack: String?
    @Flag(help: "Inspect and emit an immutable plan without writing outputs.") var dryRun = false
    @Flag(help: "Emit structured errors and results.") var json = false
    mutating func run() async throws {
        do {
            let request = try readContract(TransformationRequest.self, path: request)
            let engine = makeEngine(mediaPack, pdfPath: pdfPack)
            let dryRun = dryRun
            try await cancellable {
                let plan = try await engine.plan(request)
                if dryRun { try emit(plan) }
                else { try emit(await engine.run(plan) { diagnostic($0.phase.rawValue) }) }
            }
        } catch { try fail(error, json: json) }
    }
}
struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create and apply portable, versioned transformation setups.",
                                                     subcommands: [SetupCreate.self, SetupApply.self])
}
struct SetupCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Write a path-free setup from a request to stdout.")
    @Argument(help: "Transformation request JSON file.") var request: String
    @Option(help: "Human-readable setup name.") var name: String
    @Flag(help: "Emit structured errors.") var json = false
    mutating func run() async throws {
        do { try emit(TransformationRecipe(name: name, request: readContract(TransformationRequest.self, path: request))) }
        catch { try fail(error, json: json) }
    }
}
struct SetupApply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apply", abstract: "Bind a setup to new files and run it.")
    @Argument(help: "Setup JSON file.") var setup: String
    @Option(parsing: .singleValue, help: "One slot=path binding in recorded slot order; repeat for each source.") var asset: [String] = []
    @Option(help: "Destination file or atomic output directory.") var output: String
    @Option(help: "Media engine pack directory.") var mediaPack: String?
    @Option(help: "PDF engine pack directory; also accepts FILEFORM_PDF_PACK.") var pdfPack: String?
    @Flag(help: "Inspect and emit a plan without creating outputs.") var dryRun = false
    @Flag(help: "Emit structured errors and results.") var json = false
    mutating func run() async throws {
        do {
            let recipe = try readContract(TransformationRecipe.self, path: setup)
            let assets: [AssetReference] = try asset.map { binding in
                let parts = binding.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    throw FileformError(.invalidRequest, "Each asset must be a nonempty slot=path binding.")
                }
                return .init(id: String(parts[0]), url: URL(fileURLWithPath: String(parts[1])))
            }
            let request = try recipe.bind(assets: assets, destination: URL(fileURLWithPath: output))
            let engine = makeEngine(mediaPack, pdfPath: pdfPack); let dryRun = dryRun
            try await cancellable {
                let plan = try await engine.plan(request)
                if dryRun { try emit(plan) }
                else { try emit(await engine.run(plan) { diagnostic($0.phase.rawValue) }) }
            }
        } catch { try fail(error, json: json) }
    }
}

func readContract<T: Decodable>(_ type: T.Type, path: String) throws -> T {
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
    catch { throw FileformError(.ioFailure, "Could not open the JSON contract file.") }
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 1_048_577) ?? Data()
    guard data.count <= 1_048_576 else { throw FileformError(.resourceLimit, "JSON contracts cannot exceed 1 MiB.") }
    do { return try JSONDecoder().decode(type, from: data) }
    catch let error as FileformError { throw error }
    catch { throw FileformError(.invalidRequest, "Malformed or unsupported JSON contract.") }
}

struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render a bounded PNG preview in the native worker.")
    @Argument(help: "Image or PDF source.") var input: String
    @Option(help: "New PNG output file; originals are never overwritten.") var output: String
    @Option(help: "Worker executable; defaults to fileform-worker beside this CLI.") var worker: String?
    @Option(help: "Longest edge in pixels, from 1 to 4096.") var maximumDimension: Int = 1024
    @Option(help: "One-based PDF page.") var page: Int?
    @Flag(help: "Emit structured errors and results.") var json = false
    mutating func run() async throws {
        do {
            guard page.map({ $0 > 0 }) ?? true else { throw FileformError(.invalidRequest, "PDF pages are one-based.") }
            let executable = worker.map { URL(fileURLWithPath: $0) }
                ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("fileform-worker")
            let client = NativeWorkerClient(executable: executable)
            let input = URL(fileURLWithPath: input), output = URL(fileURLWithPath: output)
            let dimension = maximumDimension, index = page.map { $0 - 1 }
            let result = try await cancellable { try await client.exportPreview(input, destination: output, maximumDimension: dimension, pageIndex: index) }
            try emit(result)
        } catch { try fail(error, json: json) }
    }
}
