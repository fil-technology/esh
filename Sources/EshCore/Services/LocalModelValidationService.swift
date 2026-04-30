import Foundation

public struct LocalModelValidationService {
    private let engineService: EngineOrchestratorService

    public init(engineService: EngineOrchestratorService = .init()) {
        self.engineService = engineService
    }

    public func validate(
        modelPath: String,
        enginePreference: ModelValidationEnginePreference = .auto
    ) throws -> ModelValidationReport {
        let modelURL = expandedURL(modelPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw StoreError.notFound("Model path \(modelPath) was not found.")
        }

        let format = detectFormat(at: modelURL)
        let naturalEngines = compatibleEngines(for: format)
        let compatible: [EngineIdentifier]
        var warnings: [String] = []

        if let requested = enginePreference.engineIdentifier {
            if naturalEngines.contains(requested) {
                compatible = [requested]
            } else {
                compatible = []
                warnings.append("\(requested.displayName) does not support \(format.rawValue.uppercased()) models.")
            }
        } else {
            compatible = naturalEngines
        }

        if format == .unknown {
            warnings.append("Could not detect a GGUF file or MLX directory layout.")
        }

        let statuses = try compatible.map { try engineService.status(for: $0) }
        let readyEngine = statuses.first(where: \.ready)?.id
        let suggestedFixes = statuses.compactMap { status in
            status.ready ? nil : status.suggestedFix
        }

        return ModelValidationReport(
            modelPath: modelURL.path,
            format: format,
            compatibleEngines: compatible,
            readyEngine: readyEngine,
            engineStatuses: statuses,
            notes: readyEngine.map { ["Selected ready engine: \($0.displayName)."] } ?? [],
            warnings: warnings + statuses.flatMap(\.warnings),
            suggestedFixes: unique(suggestedFixes)
        )
    }

    private func detectFormat(at url: URL) -> ModelFormat {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .unknown
        }
        if !isDirectory.boolValue {
            return url.pathExtension.lowercased() == "gguf" ? .gguf : .unknown
        }

        let files = relativeFiles(under: url)
        return ModelFilenameHeuristics.inferFormat(identifier: url.lastPathComponent, filenames: files)
    }

    private func compatibleEngines(for format: ModelFormat) -> [EngineIdentifier] {
        switch format {
        case .gguf:
            [.llamaCpp]
        case .mlx:
            [.mlx]
        case .unknown:
            []
        }
    }

    private func relativeFiles(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return url.path.replacingOccurrences(of: root.path + "/", with: "")
        }
    }

    private func expandedURL(_ path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
