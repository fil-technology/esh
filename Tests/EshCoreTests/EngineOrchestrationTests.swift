import Foundation
import Testing
@testable import EshCore

@Suite
struct EngineOrchestrationTests {
    @Test
    func detectsLlamaCppFromConfiguredExecutableWithoutBootstrapping() throws {
        let service = EngineDetectionService(
            environment: ["ESH_LLAMA_CPP_CLI": "/tmp/llama-cli"],
            hostSystem: EngineHostSystem(
                operatingSystem: "macOS 15.0",
                architecture: "arm64",
                isAppleSilicon: true
            ),
            isExecutable: { $0 == "/tmp/llama-cli" },
            fileExists: { _ in false },
            commandRunner: { _, arguments in
                if arguments == ["--version"] {
                    return ProcessOutput(
                        stdout: Data("llama.cpp build 4321 Metal\n".utf8),
                        stderr: Data(),
                        exitCode: 0
                    )
                }
                return ProcessOutput(stdout: Data(), stderr: Data(), exitCode: 1)
            },
            mlxDoctor: { throw StoreError.invalidManifest("mlx-lm is not installed") }
        )

        let result = try service.detect(engine: .llamaCpp)

        #expect(result.engine == .llamaCpp)
        #expect(result.installed)
        #expect(result.status == .ready)
        #expect(result.binaryPath == "/tmp/llama-cli")
        #expect(result.version == "llama.cpp build 4321 Metal")
        #expect(result.acceleration == .available("Metal"))
        #expect(result.formats == [.gguf])
    }

    @Test
    func reportsMLXUnavailableOnIntelMacEvenWhenPythonPackageExists() throws {
        let service = EngineDetectionService(
            environment: [:],
            hostSystem: EngineHostSystem(
                operatingSystem: "macOS 15.0",
                architecture: "x86_64",
                isAppleSilicon: false
            ),
            isExecutable: { _ in false },
            fileExists: { _ in false },
            commandRunner: { _, _ in ProcessOutput(stdout: Data(), stderr: Data(), exitCode: 1) },
            mlxDoctor: {
                MLXEngineDoctorResult(
                    pythonExecutable: "/usr/bin/python3",
                    mlxVersion: "0.26.0",
                    mlxLMVersion: "0.25.0",
                    mlxVLMVersion: "0.1.0",
                    numpyVersion: "2.0.0",
                    safetensorsVersion: "0.4.5"
                )
            }
        )

        let result = try service.detect(engine: .mlx)

        #expect(result.installed)
        #expect(result.status == .unavailable)
        #expect(!result.platformCompatible)
        #expect(result.suggestedFix?.contains("Apple Silicon") == true)
    }

    @Test
    func includesRoadmapEnginesAsOptionalNotRequired() throws {
        let service = EngineDetectionService(
            environment: [:],
            hostSystem: EngineHostSystem(
                operatingSystem: "macOS 15.0",
                architecture: "arm64",
                isAppleSilicon: true
            ),
            isExecutable: { _ in false },
            fileExists: { _ in false },
            commandRunner: { _, _ in ProcessOutput(stdout: Data(), stderr: Data(), exitCode: 1) },
            mlxDoctor: { throw StoreError.invalidManifest("missing") }
        )

        let results = try service.detectAll()
        let optional = results.filter(\.isOptional).map(\.engine)

        #expect(results.first(where: { $0.engine == .llamaCpp })?.isOptional == false)
        #expect(results.first(where: { $0.engine == .mlx })?.isOptional == false)
        #expect(optional.contains(.ollama))
        #expect(optional.contains(.llamafile))
        #expect(optional.contains(.transformers))
        #expect(optional.contains(.llamaCppServer))
    }

    @Test
    func optionalRoadmapEnginesAreDisabledByDefaultEvenWhenInstalled() throws {
        let service = EngineDetectionService(
            environment: [:],
            hostSystem: EngineHostSystem(
                operatingSystem: "macOS 15.0",
                architecture: "arm64",
                isAppleSilicon: true
            ),
            isExecutable: { ["/tmp/ollama", "/tmp/llamafile", "/tmp/llama-server"].contains($0) },
            fileExists: { $0 == "/usr/bin/which" },
            commandRunner: { _, arguments in
                let path: String
                switch arguments.first {
                case "ollama": path = "/tmp/ollama"
                case "llamafile": path = "/tmp/llamafile"
                case "llama-server": path = "/tmp/llama-server"
                default: path = ""
                }
                return ProcessOutput(stdout: Data(path.utf8), stderr: Data(), exitCode: path.isEmpty ? 1 : 0)
            },
            mlxDoctor: { throw StoreError.invalidManifest("missing") }
        )

        let results = try service.detectAll()

        #expect(results.first(where: { $0.engine == .ollama })?.status == .disabled)
        #expect(results.first(where: { $0.engine == .llamafile })?.status == .disabled)
        #expect(results.first(where: { $0.engine == .llamaCppServer })?.status == .disabled)
    }

    @Test
    func enabledOptionalEngineProbesExecutable() throws {
        let config = OrchestratorConfiguration(
            experimental: OrchestratorConfiguration.Experimental(
                ollamaAdapter: true
            )
        )
        let service = EngineDetectionService(
            environment: [:],
            configuration: config,
            hostSystem: EngineHostSystem(
                operatingSystem: "macOS 15.0",
                architecture: "arm64",
                isAppleSilicon: true
            ),
            isExecutable: { $0 == "/tmp/ollama" },
            fileExists: { $0 == "/usr/bin/which" },
            commandRunner: { _, arguments in
                if arguments == ["ollama"] {
                    return ProcessOutput(stdout: Data("/tmp/ollama".utf8), stderr: Data(), exitCode: 0)
                }
                if arguments == ["--version"] {
                    return ProcessOutput(stdout: Data("ollama version 0.9.0\n".utf8), stderr: Data(), exitCode: 0)
                }
                return ProcessOutput(stdout: Data(), stderr: Data(), exitCode: 1)
            },
            mlxDoctor: { throw StoreError.invalidManifest("missing") }
        )

        let result = try service.detect(engine: .ollama)

        #expect(result.enabled)
        #expect(result.installed)
        #expect(result.status == .ready)
        #expect(result.binaryPath == "/tmp/ollama")
    }

    @Test
    func parsesOrchestratorConfigToml() throws {
        let text = """
        [defaults]
        engine = "auto"
        model_dir = "~/.esh/models"
        context_size = 8192

        [engines.llama_cpp]
        enabled = true
        binary = "/tmp/llama-cli"
        metal = true

        [engines.mlx]
        enabled = false
        python = "/tmp/python"

        [experimental]
        ollama_adapter = true
        llamafile = true
        transformers = false
        llama_cpp_server = true
        """

        let config = try OrchestratorConfiguration.parseTOML(text)

        #expect(config.defaults.engine == .auto)
        #expect(config.defaults.modelDirectory == "~/.esh/models")
        #expect(config.defaults.contextSize == 8192)
        #expect(config.engines.llamaCpp.binary == "/tmp/llama-cli")
        #expect(config.engines.mlx.enabled == false)
        #expect(config.engines.mlx.python == "/tmp/python")
        #expect(config.experimental.ollamaAdapter)
        #expect(config.experimental.llamafile)
        #expect(!config.experimental.transformers)
        #expect(config.experimental.llamaCppServer)
    }

    @Test
    func detectsLocalGGUFAndMLXModelFormats() throws {
        let ggufRoot = Self.temporaryDirectory()
        try Data("GGUF".utf8).write(to: ggufRoot.appendingPathComponent("model-q4_k_m.gguf"))

        let mlxRoot = Self.temporaryDirectory()
        try Data(#"{"model_type":"qwen2"}"#.utf8).write(to: mlxRoot.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: mlxRoot.appendingPathComponent("model.safetensors"))

        let detector = LocalModelFormatDetector()

        #expect(try detector.detectFormat(at: ggufRoot) == .gguf)
        #expect(try detector.detectFormat(at: mlxRoot) == .mlx)
    }

    @Test
    func runtimeSelectionPrefersMLXForMLXFormatOnAppleSilicon() throws {
        let selector = RuntimeSelectionService()
        let decision = try selector.select(
            request: RuntimeSelectionRequest(
                modelID: "qwen3-8b",
                detectedFormat: .mlx,
                preferredEngines: [],
                requestedEngine: nil,
                hostSystem: EngineHostSystem(
                    operatingSystem: "macOS 15.0",
                    architecture: "arm64",
                    isAppleSilicon: true
                ),
                engines: [
                    Self.readyEngine(.llamaCpp, formats: [.gguf]),
                    Self.readyEngine(.mlx, formats: [.mlx])
                ]
            )
        )

        #expect(decision.engine == EngineID.mlx)
        #expect(decision.backend == BackendKind.mlx)
        #expect(decision.explanation.contains("MLX format detected"))
    }

    @Test
    func runtimeSelectionRejectsRequestedEngineWithActionableMessage() throws {
        let selector = RuntimeSelectionService()
        #expect(throws: OrchestrationError.self) {
            _ = try selector.select(
                request: RuntimeSelectionRequest(
                    modelID: "mistral-7b",
                    detectedFormat: .gguf,
                    preferredEngines: [],
                    requestedEngine: .mlx,
                    hostSystem: EngineHostSystem(
                        operatingSystem: "macOS 15.0",
                        architecture: "arm64",
                        isAppleSilicon: true
                    ),
                    engines: [
                        Self.readyEngine(.llamaCpp, formats: [.gguf]),
                        Self.readyEngine(.mlx, formats: [.mlx])
                    ]
                )
            )
        }

        do {
            _ = try selector.select(
                request: RuntimeSelectionRequest(
                    modelID: "mistral-7b",
                    detectedFormat: .gguf,
                    preferredEngines: [],
                    requestedEngine: .mlx,
                    hostSystem: EngineHostSystem(
                        operatingSystem: "macOS 15.0",
                        architecture: "arm64",
                        isAppleSilicon: true
                    ),
                    engines: [
                        Self.readyEngine(.llamaCpp, formats: [.gguf]),
                        Self.readyEngine(.mlx, formats: [.mlx])
                    ]
                )
            )
        } catch {
            #expect(error.localizedDescription.contains("Cannot run mistral-7b with MLX"))
            #expect(error.localizedDescription.contains("Run with GGUF instead"))
            #expect(error.localizedDescription.contains("esh doctor"))
        }
    }

    @Test
    func validationReportSummarizesFormatEngineAndMissingDependency() throws {
        let install = ModelInstall(
            id: "local-gguf",
            spec: ModelSpec(
                id: "local-gguf",
                displayName: "Local GGUF",
                backend: .gguf,
                source: ModelSource(kind: .localPath, reference: "local-gguf")
            ),
            installPath: Self.temporaryDirectory().path,
            sizeBytes: 4_294_967_296,
            backendFormat: "gguf"
        )
        try Data("GGUF".utf8).write(
            to: URL(fileURLWithPath: install.installPath, isDirectory: true)
                .appendingPathComponent("local-q4_k_m.gguf")
        )
        let report = try ModelValidationService(
            formatDetector: LocalModelFormatDetector(),
            runtimeSelector: RuntimeSelectionService()
        ).validate(
            install: install,
            requestedEngine: nil,
            hostSystem: EngineHostSystem(
                operatingSystem: "macOS 15.0",
                architecture: "arm64",
                isAppleSilicon: true
            ),
            engines: [
                EngineDetectionResult(
                    engine: .llamaCpp,
                    installed: false,
                    status: .missing,
                    isOptional: false,
                    platformCompatible: true,
                    formats: [.gguf],
                    suggestedFix: "Install llama.cpp with `brew install llama.cpp`."
                )
            ]
        )

        #expect(report.modelID == "local-gguf")
        #expect(report.detectedFormat == .gguf)
        #expect(report.compatibleEngines == [.llamaCpp])
        #expect(report.selectedEngine == nil)
        #expect(report.missingDependencies.contains("llama.cpp"))
        #expect(report.suggestedFixes.contains(where: { $0.contains("brew install llama.cpp") }))
    }

    @Test
    func validationReportKeepsRequestedEngineSelectionFailure() throws {
        let install = ModelInstall(
            id: "local-gguf",
            spec: ModelSpec(
                id: "local-gguf",
                displayName: "Local GGUF",
                backend: .gguf,
                source: ModelSource(kind: .localPath, reference: "local-gguf")
            ),
            installPath: Self.temporaryDirectory().path,
            sizeBytes: 4_294_967_296,
            backendFormat: "gguf"
        )
        try Data("GGUF".utf8).write(
            to: URL(fileURLWithPath: install.installPath, isDirectory: true)
                .appendingPathComponent("local-q4_k_m.gguf")
        )

        let report = try ModelValidationService().validate(
            install: install,
            requestedEngine: .mlx,
            hostSystem: EngineHostSystem(
                operatingSystem: "macOS 15.0",
                architecture: "arm64",
                isAppleSilicon: true
            ),
            engines: [
                Self.readyEngine(.llamaCpp, formats: [.gguf]),
                Self.readyEngine(.mlx, formats: [.mlx])
            ]
        )

        #expect(report.selectedEngine == nil)
        #expect(report.warnings.contains(where: { $0.contains("Cannot run local-gguf with MLX") }))
        #expect(report.warnings.contains(where: { $0.contains("Run with GGUF instead") }))
    }

    private static func readyEngine(_ engine: EngineID, formats: [ModelFormat]) -> EngineDetectionResult {
        EngineDetectionResult(
            engine: engine,
            installed: true,
            status: .ready,
            isOptional: false,
            platformCompatible: true,
            formats: formats
        )
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
