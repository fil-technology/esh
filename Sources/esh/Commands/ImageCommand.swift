import Foundation
import EshCore

// Thin CLI over the generic image.edit capability — a convenience surface, NOT a second image pipeline.
// It builds an ExecutionRequest-equivalent ImageEditOptions and calls the same ImageEditService the web
// (`/v1/execute`) uses, including generic LoRA/style adapters resolved through the shared catalog.
enum ImageCommand {
    private static let usage = """
    Usage: esh image edit <input-image> "<instruction>" [--adapter <id>] [--model <backend>] \
    [--adapter-scale <n>] [--steps <n>] [--seed <n>] [--width <n>] [--height <n>] [--out <path>]
           esh image adapters
    """

    static func run(arguments: [String], currentDirectoryURL: URL) async throws {
        guard let sub = arguments.first else { print(usage); return }
        switch sub {
        case "edit":     try edit(arguments: Array(arguments.dropFirst()), currentDirectoryURL: currentDirectoryURL)
        case "adapters": listAdapters()
        case "-h", "--help", "help": print(usage)
        default: throw StoreError.invalidManifest("Unknown image subcommand: \(sub)\n\(usage)")
        }
    }

    private static func edit(arguments: [String], currentDirectoryURL: URL) throws {
        let positional = arguments.filter { !$0.hasPrefix("--") }
        guard let inputArg = positional.first else { throw StoreError.invalidManifest(usage) }
        let instruction = CommandSupport.optionalValue(flag: "--instruction", in: arguments)
            ?? (positional.count >= 2 ? positional[1] : nil)
        guard let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalidManifest("image edit requires an instruction.\n\(usage)")
        }
        let inURL = URL(fileURLWithPath: inputArg, relativeTo: currentDirectoryURL).standardizedFileURL
        guard FileManager.default.fileExists(atPath: inURL.path) else {
            throw StoreError.invalidManifest("input image not found: \(inURL.path)")
        }
        let root = PersistenceRoot.default()
        try StorageService().ensureAssetsAvailable(root: root)   // never fill internal disk
        let hfCache = root.cachesURL.appendingPathComponent("image-models", isDirectory: true).path

        // Backend pin (optional). An adapter overrides this with its own compatible base family.
        var backend: ImageEditBackend = .flux2Klein
        var pinned: ImageEditBackend?
        if let b = CommandSupport.optionalValue(flag: "--model", in: arguments) {
            guard let bk = ImageEditBackend(rawValue: b) else {
                throw StoreError.invalidManifest("unknown --model '\(b)' (backends: \(ImageEditBackend.allCases.map { $0.rawValue }.joined(separator: ", ")))")
            }
            backend = bk; pinned = bk
        }

        // Generic style adapter (LoRA), resolved through the shared catalog (same path as the provider/web).
        var loraPaths: [String] = [], loraScales: [Double] = []
        var model: String?, baseModel: String?, adapterID: String?
        if let aid = CommandSupport.optionalValue(flag: "--adapter", in: arguments)
            ?? CommandSupport.optionalValue(flag: "--lora", in: arguments) {
            let r = try ImageAdapterCatalog.resolveForEdit(
                id: aid, scale: CommandSupport.optionalValue(flag: "--adapter-scale", in: arguments).flatMap(Double.init),
                pinnedBackend: pinned, hfCacheRoot: hfCache)
            backend = r.backend; loraPaths = r.loraPaths; loraScales = r.loraScales
            model = r.model; baseModel = r.baseModel; adapterID = r.adapterID
        }

        let outURL: URL = CommandSupport.optionalValue(flag: "--out", in: arguments)
            .map { URL(fileURLWithPath: $0, relativeTo: currentDirectoryURL).standardizedFileURL }
            ?? inURL.deletingPathExtension().appendingPathExtension("edited.png")

        let opts = ImageEditOptions(
            backend: backend, model: model, baseModel: baseModel, loraPaths: loraPaths, loraScales: loraScales,
            seed: CommandSupport.optionalValue(flag: "--seed", in: arguments).flatMap { Int($0) },
            steps: CommandSupport.optionalValue(flag: "--steps", in: arguments).flatMap { Int($0) },
            width: CommandSupport.optionalValue(flag: "--width", in: arguments).flatMap { Int($0) },
            height: CommandSupport.optionalValue(flag: "--height", in: arguments).flatMap { Int($0) },
            hfCache: hfCache)

        FileHandle.standardError.write(Data("editing (\(backend.rawValue)\(adapterID.map { " + " + $0 } ?? "")) — this can take a few minutes…\n".utf8))
        let res = try ImageEditService().edit(imagePath: inURL.path, outputPath: outURL.path, instruction: instruction, options: opts)
        print("edited → \(outURL.path)")
        print("  backend=\(res.backend) model=\(res.model)\(adapterID.map { " adapter=\($0)" } ?? "") \(res.width)x\(res.height) license=\(res.license)\(res.commercial ? "" : " (non-commercial)")")
    }

    private static func listAdapters() {
        let root = PersistenceRoot.default()
        let hfCache = root.cachesURL.appendingPathComponent("image-models", isDirectory: true).path
        print("Style adapters (esh image edit … --adapter <id>):")
        for id in ImageAdapterCatalog.ids {
            guard let a = ImageAdapterCatalog.resolve(id) else { continue }
            let installed = ImageAdapterCatalog.isInstalled(a, hfCacheRoot: hfCache)
            let name = id.padding(toLength: max(id.count, 18), withPad: " ", startingAt: 0)
            print("  \(name)  \(a.displayName)  [\(a.backend.rawValue), \(a.license), ~\(a.approxSizeMB) MB, \(installed ? "installed" : "not installed")]")
        }
    }
}
