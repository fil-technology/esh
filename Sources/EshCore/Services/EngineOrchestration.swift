import Foundation
import Darwin

public enum EngineID: String, Codable, Hashable, Sendable, CaseIterable {
    case llamaCpp = "llama.cpp"
    case llamaCppServer = "llama.cpp-server"
    case mlx
    case ollama
    case llamafile
    case transformers

    public init?(argument: String) {
        switch argument.lowercased() {
        case "llama.cpp", "llama-cpp", "llama_cpp", "gguf":
            self = .llamaCpp
        case "llama.cpp-server", "llama.cpp server", "llama-server", "llama_cpp_server":
            self = .llamaCppServer
        case "mlx", "mlx-lm", "mlxlm":
            self = .mlx
        case "ollama":
            self = .ollama
        case "llamafile":
            self = .llamafile
        case "transformers", "pytorch", "torch":
            self = .transformers
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .llamaCpp: "llama.cpp"
        case .llamaCppServer: "llama.cpp server"
        case .mlx: "MLX"
        case .ollama: "Ollama"
        case .llamafile: "llamafile"
        case .transformers: "Transformers"
        }
    }

    public var backend: BackendKind? {
        switch self {
        case .llamaCpp:
            .gguf
        case .mlx:
            .mlx
        case .llamaCppServer, .ollama, .llamafile, .transformers:
            nil
        }
    }
}

public enum EngineStatus: String, Codable, Hashable, Sendable {
    case ready
    case missing
    case disabled
    case unavailable
}

public enum EngineAcceleration: Codable, Hashable, Sendable {
    case available(String)
    case unavailable(String)
    case unknown
}

public struct EngineHostSystem: Codable, Hashable, Sendable {
    public var operatingSystem: String
    public var architecture: String
    public var isAppleSilicon: Bool

    public init(
        operatingSystem: String,
        architecture: String,
        isAppleSilicon: Bool
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.isAppleSilicon = isAppleSilicon
    }

    public static func current() -> EngineHostSystem {
        let architecture = currentArchitecture()
        return EngineHostSystem(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            isAppleSilicon: architecture == "arm64" || architecture == "arm64e"
        )
    }

    private static func currentArchitecture() -> String {
        var info = utsname()
        uname(&info)
        let bytes = withUnsafeBytes(of: &info.machine) { rawBuffer -> [UInt8] in
            rawBuffer.reduce(into: []) { result, byte in
                if byte != 0 {
                    result.append(byte)
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct MLXEngineDoctorResult: Codable, Hashable, Sendable {
    public var pythonExecutable: String
    public var mlxVersion: String
    public var mlxLMVersion: String
    public var mlxVLMVersion: String
    public var numpyVersion: String
    public var safetensorsVersion: String

    public init(
        pythonExecutable: String,
        mlxVersion: String,
        mlxLMVersion: String,
        mlxVLMVersion: String,
        numpyVersion: String,
        safetensorsVersion: String
    ) {
        self.pythonExecutable = pythonExecutable
        self.mlxVersion = mlxVersion
        self.mlxLMVersion = mlxLMVersion
        self.mlxVLMVersion = mlxVLMVersion
        self.numpyVersion = numpyVersion
        self.safetensorsVersion = safetensorsVersion
    }
}

public struct EngineDetectionResult: Codable, Hashable, Sendable {
    public var engine: EngineID
    public var enabled: Bool
    public var installed: Bool
    public var status: EngineStatus
    public var isOptional: Bool
    public var platformCompatible: Bool
    public var version: String?
    public var binaryPath: String?
    public var packagePath: String?
    public var acceleration: EngineAcceleration
    public var formats: [ModelFormat]
    public var capabilities: [String]
    public var limitations: [String]
    public var suggestedFix: String?

    public init(
        engine: EngineID,
        enabled: Bool = true,
        installed: Bool,
        status: EngineStatus,
        isOptional: Bool,
        platformCompatible: Bool,
        version: String? = nil,
        binaryPath: String? = nil,
        packagePath: String? = nil,
        acceleration: EngineAcceleration = .unknown,
        formats: [ModelFormat],
        capabilities: [String] = [],
        limitations: [String] = [],
        suggestedFix: String? = nil
    ) {
        self.engine = engine
        self.enabled = enabled
        self.installed = installed
        self.status = status
        self.isOptional = isOptional
        self.platformCompatible = platformCompatible
        self.version = version
        self.binaryPath = binaryPath
        self.packagePath = packagePath
        self.acceleration = acceleration
        self.formats = formats
        self.capabilities = capabilities
        self.limitations = limitations
        self.suggestedFix = suggestedFix
    }
}

public struct EngineDetectionService: Sendable {
    public typealias CommandRunner = @Sendable (URL, [String]) throws -> ProcessOutput
    public typealias MLXDoctor = @Sendable () throws -> MLXEngineDoctorResult

    private let environment: [String: String]
    private let configuration: OrchestratorConfiguration
    private let hostSystem: EngineHostSystem
    private let isExecutable: @Sendable (String) -> Bool
    private let fileExists: @Sendable (String) -> Bool
    private let commandRunner: CommandRunner
    private let mlxDoctor: MLXDoctor

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configuration: OrchestratorConfiguration = .default,
        hostSystem: EngineHostSystem = .current(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        commandRunner: @escaping CommandRunner = { executableURL, arguments in
            try ProcessRunner.run(executableURL: executableURL, arguments: arguments)
        },
        mlxDoctor: @escaping MLXDoctor = {
            try MLXBridge().run(
                command: "doctor",
                request: EmptyEngineDoctorRequest(),
                as: MLXEngineDoctorResult.self
            )
        }
    ) {
        self.environment = environment
        self.configuration = configuration
        self.hostSystem = hostSystem
        self.isExecutable = isExecutable
        self.fileExists = fileExists
        self.commandRunner = commandRunner
        self.mlxDoctor = mlxDoctor
    }

    public func detectAll() throws -> [EngineDetectionResult] {
        try EngineID.allCases.map { try detect(engine: $0) }
    }

    public func detect(engine: EngineID) throws -> EngineDetectionResult {
        switch engine {
        case .llamaCpp:
            return detectLlamaCpp()
        case .llamaCppServer:
            return detectOptionalExecutable(
                engine: .llamaCppServer,
                executableName: "llama-server",
                enabled: configuration.experimental.llamaCppServer,
                formats: [.gguf],
                capabilities: ["GGUF server", "OpenAI-compatible backend"],
                limitations: ["Roadmap adapter only; esh serve does not delegate to llama-server yet."],
                configKey: "llama_cpp_server"
            )
        case .mlx:
            return detectMLX()
        case .ollama:
            return detectOptionalExecutable(
                engine: .ollama,
                executableName: "ollama",
                enabled: configuration.experimental.ollamaAdapter,
                formats: [],
                capabilities: ["External adapter", "Managed models"],
                limitations: ["Roadmap adapter only; esh core routing does not depend on Ollama."],
                configKey: "ollama_adapter"
            )
        case .llamafile:
            return detectOptionalExecutable(
                engine: .llamafile,
                executableName: "llamafile",
                enabled: configuration.experimental.llamafile,
                formats: [],
                capabilities: ["Portable single-file runtime"],
                limitations: ["Roadmap only until core engine abstraction is stable."],
                configKey: "llamafile"
            )
        case .transformers:
            return detectTransformers()
        }
    }

    private func detectLlamaCpp() -> EngineDetectionResult {
        guard configuration.engines.llamaCpp.enabled else {
            let binaryPath = firstExecutableCandidate(llamaCppCandidates())
            return EngineDetectionResult(
                engine: .llamaCpp,
                enabled: false,
                installed: binaryPath != nil,
                status: .disabled,
                isOptional: false,
                platformCompatible: true,
                binaryPath: binaryPath,
                formats: [.gguf],
                capabilities: ["GGUF", "CPU", "Metal"],
                suggestedFix: "Enable llama.cpp in ~/.esh/config.toml: [engines.llama_cpp] enabled = true"
            )
        }

        guard let binaryPath = firstExecutableCandidate(llamaCppCandidates()) else {
            return EngineDetectionResult(
                engine: .llamaCpp,
                installed: false,
                status: .missing,
                isOptional: false,
                platformCompatible: true,
                acceleration: hostSystem.isAppleSilicon ? .unavailable("Metal support could not be checked without llama-cli.") : .unknown,
                formats: [.gguf],
                capabilities: ["GGUF", "CPU", "Metal"],
                suggestedFix: "Install llama.cpp with `brew install llama.cpp`, or set ESH_LLAMA_CPP_CLI to your `llama-cli` path."
            )
        }

        let versionOutput = commandOutput(for: binaryPath, arguments: ["--version"])
        let version = versionOutput.flatMap(parsedVersionLine)
        let acceleration: EngineAcceleration
        if versionOutput?.range(of: "metal", options: .caseInsensitive) != nil
            || versionOutput?.range(of: "mtl backend", options: .caseInsensitive) != nil {
            acceleration = .available("Metal")
        } else if hostSystem.isAppleSilicon {
            acceleration = .unknown
        } else {
            acceleration = .unknown
        }

        return EngineDetectionResult(
            engine: .llamaCpp,
            installed: true,
            status: .ready,
            isOptional: false,
            platformCompatible: true,
            version: version,
            binaryPath: binaryPath,
            acceleration: acceleration,
            formats: [.gguf],
            capabilities: ["GGUF", "Streaming text", "CPU", "Metal"],
            limitations: ["Multimodal GGUF models are not wired through esh yet."]
        )
    }

    private func detectMLX() -> EngineDetectionResult {
        guard configuration.engines.mlx.enabled else {
            return EngineDetectionResult(
                engine: .mlx,
                enabled: false,
                installed: configuration.engines.mlx.python != nil,
                status: .disabled,
                isOptional: false,
                platformCompatible: hostSystem.isAppleSilicon,
                packagePath: configuredValue(configuration.engines.mlx.python),
                formats: [.mlx],
                capabilities: ["MLX", "mlx-lm"],
                suggestedFix: "Enable MLX in ~/.esh/config.toml: [engines.mlx] enabled = true"
            )
        }

        do {
            let doctor = try mlxDoctor()
            let compatible = hostSystem.isAppleSilicon
            return EngineDetectionResult(
                engine: .mlx,
                installed: true,
                status: compatible ? .ready : .unavailable,
                isOptional: false,
                platformCompatible: compatible,
                version: "mlx \(doctor.mlxVersion), mlx-lm \(doctor.mlxLMVersion), mlx-vlm \(doctor.mlxVLMVersion)",
                packagePath: doctor.pythonExecutable,
                acceleration: compatible ? .available("Apple Silicon Metal") : .unavailable("Apple Silicon required"),
                formats: [.mlx],
                capabilities: ["MLX", "mlx-lm", "Apple Silicon"],
                limitations: compatible ? [] : ["MLX local inference requires Apple Silicon."],
                suggestedFix: compatible ? nil : "Run MLX models on an Apple Silicon Mac, or use GGUF with llama.cpp on this machine."
            )
        } catch {
            return EngineDetectionResult(
                engine: .mlx,
                installed: false,
                status: .missing,
                isOptional: false,
                platformCompatible: hostSystem.isAppleSilicon,
                acceleration: hostSystem.isAppleSilicon ? .unknown : .unavailable("Apple Silicon required"),
                formats: [.mlx],
                capabilities: ["MLX", "mlx-lm"],
                suggestedFix: "Run `./scripts/bootstrap.sh`, or install MLX dependencies with `pip install mlx-lm mlx-vlm safetensors`."
            )
        }
    }

    private func detectOptionalExecutable(
        engine: EngineID,
        executableName: String,
        enabled: Bool,
        formats: [ModelFormat],
        capabilities: [String],
        limitations: [String],
        configKey: String
    ) -> EngineDetectionResult {
        let binaryPath = which(executableName)
        guard enabled else {
            return EngineDetectionResult(
                engine: engine,
                enabled: false,
                installed: binaryPath != nil,
                status: .disabled,
                isOptional: true,
                platformCompatible: true,
                binaryPath: binaryPath,
                formats: formats,
                capabilities: capabilities,
                limitations: limitations,
                suggestedFix: "Enable with ~/.esh/config.toml: [experimental] \(configKey) = true"
            )
        }

        return EngineDetectionResult(
            engine: engine,
            installed: binaryPath != nil,
            status: binaryPath == nil ? .missing : .ready,
            isOptional: true,
            platformCompatible: true,
            version: binaryPath.flatMap { commandOutput(for: $0, arguments: ["--version"]).flatMap(parsedVersionLine) },
            binaryPath: binaryPath,
            formats: formats,
            capabilities: capabilities,
            limitations: limitations,
            suggestedFix: binaryPath == nil ? "Optional roadmap engine. No action is required for core esh usage." : nil
        )
    }

    private func detectTransformers() -> EngineDetectionResult {
        let python = which("python3") ?? which("python")
        guard configuration.experimental.transformers else {
            return EngineDetectionResult(
                engine: .transformers,
                enabled: false,
                installed: python != nil,
                status: .disabled,
                isOptional: true,
                platformCompatible: true,
                binaryPath: python,
                formats: [],
                capabilities: ["Hugging Face safetensors fallback"],
                limitations: ["Experimental roadmap fallback; usually slower and heavier than MLX or llama.cpp."],
                suggestedFix: "Enable with ~/.esh/config.toml: [experimental] transformers = true"
            )
        }
        return EngineDetectionResult(
            engine: .transformers,
            installed: python != nil,
            status: python == nil ? .missing : .ready,
            isOptional: true,
            platformCompatible: true,
            binaryPath: python,
            formats: [],
            capabilities: ["Hugging Face safetensors fallback"],
            limitations: ["Experimental roadmap fallback; usually slower and heavier than MLX or llama.cpp."],
            suggestedFix: python == nil ? "Optional roadmap engine. No action is required for core esh usage." : nil
        )
    }

    private func llamaCppCandidates() -> [String] {
        [
            configuredValue(configuration.engines.llamaCpp.binary),
            environment["ESH_LLAMA_CPP_CLI"],
            environment["LLAMA_CPP_CLI"],
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            which("llama-cli")
        ].compactMap { $0 }
    }

    private func configuredValue(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.lowercased() != "auto" else {
            return nil
        }
        return value
    }

    private func firstExecutableCandidate(_ candidates: [String]) -> String? {
        candidates.first { isExecutable($0) }
    }

    private func which(_ executableName: String) -> String? {
        guard fileExists("/usr/bin/which") || isExecutable("/usr/bin/which") else {
            return nil
        }
        guard let output = try? commandRunner(URL(fileURLWithPath: "/usr/bin/which"), [executableName]),
              output.exitCode == 0 else {
            return nil
        }
        let path = String(decoding: output.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, isExecutable(path) else {
            return nil
        }
        return path
    }

    private func commandOutput(for binaryPath: String, arguments: [String]) -> String? {
        guard let output = try? commandRunner(URL(fileURLWithPath: binaryPath), arguments),
              output.exitCode == 0 else {
            return nil
        }
        return String(decoding: output.stdout + output.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parsedVersionLine(from text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.first { line in
            let lowered = line.lowercased()
            return lowered.hasPrefix("version:")
                || lowered.contains("llama.cpp")
                || (lowered.contains("build") && !lowered.contains("load_backend"))
        } ?? lines.first { !$0.lowercased().contains("load_backend") } ?? lines.first
    }
}

public struct LocalModelFormatDetector: Sendable {
    public init() {}

    public func detectFormat(at url: URL) throws -> ModelFormat {
        let filenames = try filenames(at: url)
        return ModelFilenameHeuristics.inferFormat(
            identifier: url.lastPathComponent,
            filenames: filenames
        )
    }

    public func filenames(at url: URL) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return [url.lastPathComponent]
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }
        return enumerator.compactMap { item -> String? in
            guard let fileURL = item as? URL else { return nil }
            return fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
        }
    }
}

public struct RuntimeSelectionRequest: Hashable, Sendable {
    public var modelID: String
    public var detectedFormat: ModelFormat
    public var preferredEngines: [EngineID]
    public var requestedEngine: EngineID?
    public var hostSystem: EngineHostSystem
    public var engines: [EngineDetectionResult]

    public init(
        modelID: String,
        detectedFormat: ModelFormat,
        preferredEngines: [EngineID],
        requestedEngine: EngineID?,
        hostSystem: EngineHostSystem,
        engines: [EngineDetectionResult]
    ) {
        self.modelID = modelID
        self.detectedFormat = detectedFormat
        self.preferredEngines = preferredEngines
        self.requestedEngine = requestedEngine
        self.hostSystem = hostSystem
        self.engines = engines
    }
}

public struct RuntimeSelectionDecision: Hashable, Sendable {
    public var engine: EngineID
    public var backend: BackendKind
    public var explanation: String

    public init(engine: EngineID, backend: BackendKind, explanation: String) {
        self.engine = engine
        self.backend = backend
        self.explanation = explanation
    }
}

public struct OrchestrationError: LocalizedError, Hashable, Sendable {
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct RuntimeSelectionService: Sendable {
    public init() {}

    public func select(request: RuntimeSelectionRequest) throws -> RuntimeSelectionDecision {
        if let requested = request.requestedEngine {
            return try selectRequestedEngine(requested, request: request)
        }

        for preferred in request.preferredEngines {
            if let decision = decisionIfReady(preferred, request: request, reason: "Using model preferred engine: \(preferred.displayName).") {
                return decision
            }
        }

        if request.hostSystem.isAppleSilicon,
           request.detectedFormat == .mlx,
           let decision = decisionIfReady(.mlx, request: request, reason: "MLX format detected on Apple Silicon.") {
            return decision
        }

        if request.detectedFormat == .gguf,
           let decision = decisionIfReady(.llamaCpp, request: request, reason: "GGUF format detected; using llama.cpp.") {
            return decision
        }

        if request.detectedFormat == .mlx,
           let decision = decisionIfReady(.mlx, request: request, reason: "MLX format detected.") {
            return decision
        }

        throw OrchestrationError(unavailableMessage(for: request))
    }

    private func selectRequestedEngine(
        _ engine: EngineID,
        request: RuntimeSelectionRequest
    ) throws -> RuntimeSelectionDecision {
        guard supportsFormat(engine: engine, format: request.detectedFormat) else {
            throw OrchestrationError(incompatibleMessage(engine: engine, request: request))
        }
        guard let result = request.engines.first(where: { $0.engine == engine }) else {
            throw OrchestrationError("Cannot run \(request.modelID) with \(engine.displayName).\nReason: engine detection did not return a result.\nSuggested fixes:\n  1. Check setup: esh doctor")
        }
        guard result.status == .ready, let backend = engine.backend else {
            throw OrchestrationError(missingMessage(engine: engine, result: result, request: request))
        }
        return RuntimeSelectionDecision(
            engine: engine,
            backend: backend,
            explanation: "Using requested engine: \(engine.displayName)."
        )
    }

    private func decisionIfReady(
        _ engine: EngineID,
        request: RuntimeSelectionRequest,
        reason: String
    ) -> RuntimeSelectionDecision? {
        guard supportsFormat(engine: engine, format: request.detectedFormat),
              let result = request.engines.first(where: { $0.engine == engine }),
              result.status == .ready,
              let backend = engine.backend else {
            return nil
        }
        return RuntimeSelectionDecision(engine: engine, backend: backend, explanation: reason)
    }

    private func supportsFormat(engine: EngineID, format: ModelFormat) -> Bool {
        switch (engine, format) {
        case (.llamaCpp, .gguf), (.mlx, .mlx):
            true
        default:
            false
        }
    }

    private func incompatibleMessage(engine: EngineID, request: RuntimeSelectionRequest) -> String {
        let format = request.detectedFormat.rawValue.uppercased()
        let fix: String
        switch request.detectedFormat {
        case .gguf:
            fix = "Run with GGUF instead: esh infer --model \(request.modelID) --message <text>"
        case .mlx:
            fix = "Run with MLX instead: esh infer --model \(request.modelID) --message <text>"
        case .unknown:
            fix = "Validate the model files: esh validate \(request.modelID)"
        }
        return """
        Cannot run \(request.modelID) with \(engine.displayName).
        Reason: model format \(format) is not supported by \(engine.displayName).

        Suggested fixes:
          1. \(fix)
          2. Check setup: esh doctor
        """
    }

    private func missingMessage(
        engine: EngineID,
        result: EngineDetectionResult,
        request: RuntimeSelectionRequest
    ) -> String {
        """
        Cannot run \(request.modelID) with \(engine.displayName).
        Reason: \(engine.displayName) is \(result.status.rawValue).

        Suggested fixes:
          1. \(result.suggestedFix ?? "Install or enable \(engine.displayName).")
          2. Check setup: esh doctor
        """
    }

    private func unavailableMessage(for request: RuntimeSelectionRequest) -> String {
        let format = request.detectedFormat.rawValue.uppercased()
        let missingRequired = request.engines
            .filter { !$0.isOptional && $0.status != .ready }
            .map(\.engine.displayName)
            .joined(separator: ", ")
        return """
        Cannot select a runtime for \(request.modelID).
        Reason: no ready engine supports detected format \(format).

        Suggested fixes:
          1. Install missing engines: \(missingRequired.isEmpty ? "llama.cpp or MLX" : missingRequired)
          2. Check setup: esh doctor
          3. Validate the model files: esh validate \(request.modelID)
        """
    }
}

public struct ModelValidationReport: Codable, Hashable, Sendable {
    public var modelID: String
    public var displayName: String
    public var localPath: String
    public var detectedFormat: ModelFormat
    public var foundFiles: [String]
    public var compatibleEngines: [EngineID]
    public var selectedEngine: EngineID?
    public var selectedBackend: BackendKind?
    public var selectionExplanation: String?
    public var missingDependencies: [String]
    public var suggestedFixes: [String]
    public var warnings: [String]
    public var sizeBytes: Int64

    public init(
        modelID: String,
        displayName: String,
        localPath: String,
        detectedFormat: ModelFormat,
        foundFiles: [String],
        compatibleEngines: [EngineID],
        selectedEngine: EngineID?,
        selectedBackend: BackendKind?,
        selectionExplanation: String?,
        missingDependencies: [String],
        suggestedFixes: [String],
        warnings: [String],
        sizeBytes: Int64
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.localPath = localPath
        self.detectedFormat = detectedFormat
        self.foundFiles = foundFiles
        self.compatibleEngines = compatibleEngines
        self.selectedEngine = selectedEngine
        self.selectedBackend = selectedBackend
        self.selectionExplanation = selectionExplanation
        self.missingDependencies = missingDependencies
        self.suggestedFixes = suggestedFixes
        self.warnings = warnings
        self.sizeBytes = sizeBytes
    }
}

public struct ModelValidationService: Sendable {
    private let formatDetector: LocalModelFormatDetector
    private let runtimeSelector: RuntimeSelectionService

    public init(
        formatDetector: LocalModelFormatDetector = .init(),
        runtimeSelector: RuntimeSelectionService = .init()
    ) {
        self.formatDetector = formatDetector
        self.runtimeSelector = runtimeSelector
    }

    public func validate(
        install: ModelInstall,
        requestedEngine: EngineID?,
        hostSystem: EngineHostSystem,
        engines: [EngineDetectionResult]
    ) throws -> ModelValidationReport {
        let installURL = URL(fileURLWithPath: install.installPath, isDirectory: true)
        let filenames = try formatDetector.filenames(at: installURL).sorted()
        let detectedFormat = try formatDetector.detectFormat(at: installURL)
        let compatibleEngines = compatibleEngineIDs(for: detectedFormat, install: install)
        let relevantEngines = engines.filter { compatibleEngines.contains($0.engine) }
        let missingDependencies = relevantEngines
            .filter { $0.status != .ready }
            .map(\.engine.displayName)
        let suggestedFixes = relevantEngines.compactMap(\.suggestedFix)

        let decision: RuntimeSelectionDecision?
        let selectionFailure: String?
        do {
            decision = try runtimeSelector.select(
                request: RuntimeSelectionRequest(
                    modelID: install.id,
                    detectedFormat: detectedFormat,
                    preferredEngines: preferredEngines(for: install),
                    requestedEngine: requestedEngine,
                    hostSystem: hostSystem,
                    engines: engines
                )
            )
            selectionFailure = nil
        } catch {
            decision = nil
            selectionFailure = error.localizedDescription
        }

        var warnings: [String] = []
        if detectedFormat == .unknown {
            warnings.append("Could not detect GGUF or MLX model files in \(install.installPath).")
        }
        if let selectionFailure {
            warnings.append(selectionFailure)
        } else if decision == nil, compatibleEngines.isEmpty == false, missingDependencies.isEmpty {
            warnings.append("Compatible engines were found, but none could be selected.")
        }

        return ModelValidationReport(
            modelID: install.id,
            displayName: install.spec.displayName,
            localPath: install.installPath,
            detectedFormat: detectedFormat,
            foundFiles: filenames,
            compatibleEngines: compatibleEngines,
            selectedEngine: decision?.engine,
            selectedBackend: decision?.backend,
            selectionExplanation: decision?.explanation,
            missingDependencies: missingDependencies,
            suggestedFixes: suggestedFixes,
            warnings: warnings,
            sizeBytes: install.sizeBytes
        )
    }

    private func compatibleEngineIDs(for format: ModelFormat, install: ModelInstall) -> [EngineID] {
        switch format {
        case .gguf:
            [.llamaCpp]
        case .mlx:
            [.mlx]
        case .unknown:
            switch install.spec.backend {
            case .gguf:
                [.llamaCpp]
            case .mlx:
                [.mlx]
            case .onnx:
                []
            }
        }
    }

    private func preferredEngines(for install: ModelInstall) -> [EngineID] {
        switch install.spec.backend {
        case .gguf:
            [.llamaCpp]
        case .mlx:
            [.mlx]
        case .onnx:
            []
        }
    }
}

public struct EmptyEngineDoctorRequest: Codable, Sendable {
    public init() {}
}
