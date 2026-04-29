import Foundation
import EshCore
import Metal
import TTSMLX

enum AudioSpeechGenerator {
    struct SynthesisRequest {
        var text: String
        var model: String?
        var voice: String?
        var language: String?
        var outputURL: URL
        var forceOverwrite: Bool
        var profile: TTSGenerationProfile?
        var maxTokens: Int?
        var temperature: Float?
        var topP: Float?
        var hfToken: String?
    }

    struct SynthesisResult {
        var url: URL
        var modelID: String
        var sampleRate: Int
    }

    static func synthesize(
        _ request: SynthesisRequest,
        currentDirectoryURL: URL,
        progressHandler: @escaping @Sendable (TTSProgressUpdate) -> Void = { _ in }
    ) async throws -> SynthesisResult {
        let model = try resolveModel(request.model)

        if FileManager.default.fileExists(atPath: request.outputURL.path) {
            if request.forceOverwrite {
                try FileManager.default.removeItem(at: request.outputURL)
            } else {
            throw StoreError.invalidManifest("Output file already exists at \(request.outputURL.path).")
            }
        }

        try ensureMLXMetalLibrary(currentDirectoryURL: currentDirectoryURL)
        try ensureMetalDeviceAvailable()

        let modelCacheURL = currentDirectoryURL.appendingPathComponent(".esh/tts-models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelCacheURL, withIntermediateDirectories: true)
        setenv("HF_HUB_CACHE", modelCacheURL.path, 1)
        let modelStore = TTSModelStore(cacheRoots: [modelCacheURL])
        let synthesizer = TTSSpeechSynthesizer(modelStore: modelStore)
        let result = try await synthesizer.synthesize(
            request.text,
            using: model,
            options: TTSSynthesisOptions(
                language: request.language.map(TTSLanguage.init(_:)),
                voice: request.voice.map(TTSVoice.init(_:)),
                outputURL: request.outputURL,
                generationProfile: request.profile,
                maxTokens: request.maxTokens,
                temperature: request.temperature,
                topP: request.topP,
                hfToken: request.hfToken
            ),
            progressHandler: progressHandler
        )

        return SynthesisResult(url: result.url, modelID: result.modelID, sampleRate: result.sampleRate)
    }

    static func generateResponse(
        _ request: OpenAIAudioSpeechRequest,
        currentDirectoryURL: URL
    ) async throws -> OpenAIAudioSpeechResponse {
        let filenameStem = sanitizedFilenameStem(voice: request.voice, model: request.model)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenameStem)-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let result = try await synthesize(
            SynthesisRequest(
                text: request.input,
                model: request.model,
                voice: request.voice,
                language: request.language,
                outputURL: temporaryURL,
                forceOverwrite: false,
                profile: nil,
                maxTokens: request.maxTokens,
                temperature: request.temperature.map(Float.init),
                topP: request.topP.map(Float.init),
                hfToken: ProcessInfo.processInfo.environment["HF_TOKEN"]
            ),
            currentDirectoryURL: currentDirectoryURL
        )
        let audioData = try Data(contentsOf: result.url)

        return OpenAIAudioSpeechResponse(
            audioData: audioData,
            contentType: "audio/wav",
            filename: "\(filenameStem).wav",
            modelID: result.modelID,
            sampleRate: result.sampleRate
        )
    }

    private static func sanitizedFilenameStem(voice: String?, model: String?) -> String {
        let base = (voice?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? voice! : model) ?? "speech"
        let scalarView = base.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(scalarView).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "speech" : trimmed.lowercased()
    }

    private static func resolveModel(_ requestedModel: String?) throws -> TTSModelDescriptor {
        let models = TTSMLX.supportedModels
        guard let requestedModel else {
            guard let first = models.first else {
                throw StoreError.notFound("TTSMLX did not report any supported MLX TTS models.")
            }
            return first
        }

        let normalized = requestedModel.lowercased()
        if let model = models.first(where: { model in
            model.id.lowercased() == normalized
                || model.displayName.lowercased() == normalized
                || model.id.components(separatedBy: "/").last?.lowercased() == normalized
        }) {
            return model
        }

        let available = models.map(\.id).joined(separator: ", ")
        throw StoreError.notFound("Unknown MLX TTS model \(requestedModel). Available models: \(available)")
    }

    private static func ensureMLXMetalLibrary(currentDirectoryURL: URL) throws {
        guard let executablePath = CommandLine.arguments.first else { return }
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
        let colocatedLibrary = executableDirectory.appendingPathComponent("mlx.metallib")
        let fallbackLibrary = executableDirectory.appendingPathComponent("default.metallib")

        if FileManager.default.fileExists(atPath: colocatedLibrary.path)
            || FileManager.default.fileExists(atPath: fallbackLibrary.path) {
            return
        }

        guard let shaderRoot = findMLXShaderRoot(currentDirectoryURL: currentDirectoryURL) else {
            throw StoreError.invalidManifest(
                """
                MLX Metal runtime library is missing and mlx-swift shader sources were not found under .build/checkouts.
                Run `swift package resolve` and `swift build`, then retry audio generation.
                """
            )
        }

        let outputDirectory = currentDirectoryURL.appendingPathComponent(".build/esh-metal", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let moduleCacheDirectory = currentDirectoryURL.appendingPathComponent(".build/clang-module-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleCacheDirectory, withIntermediateDirectories: true)
        let generatedLibrary = outputDirectory.appendingPathComponent("mlx.metallib")

        let metalFiles = try collectMetalFiles(in: shaderRoot)
        guard metalFiles.isEmpty == false else {
            throw StoreError.invalidManifest("No MLX Metal shader files were found at \(shaderRoot.path).")
        }

        print("Preparing MLX Metal runtime library...")
        var arguments = [
            "metal",
            "-std=metal3.1",
            "-fmodules-cache-path=\(moduleCacheDirectory.path)",
            "-I",
            shaderRoot.path,
            "-I",
            shaderRoot.deletingLastPathComponent().path,
            "-o",
            generatedLibrary.path
        ]
        arguments.append(contentsOf: metalFiles.map(\.path))

        let output = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
        )
        guard output.exitCode == 0 else {
            let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
            throw StoreError.invalidManifest("Could not build MLX Metal runtime library: \(stderr)")
        }

        if FileManager.default.fileExists(atPath: colocatedLibrary.path) {
            try FileManager.default.removeItem(at: colocatedLibrary)
        }
        try FileManager.default.copyItem(at: generatedLibrary, to: colocatedLibrary)
    }

    private static func ensureMetalDeviceAvailable() throws {
        let devices = MTLCopyAllDevices()
        if !devices.isEmpty || MTLCreateSystemDefaultDevice() != nil {
            return
        }

        throw StoreError.invalidManifest(
            """
            No Metal GPU device is visible to this process. MLX TTS requires Apple Metal access.
            Try running from a normal macOS Terminal session on Apple Silicon.
            """
        )
    }

    private static func findMLXShaderRoot(currentDirectoryURL: URL) -> URL? {
        let candidates = [
            currentDirectoryURL
                .appendingPathComponent(".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal", isDirectory: true),
            currentDirectoryURL
                .appendingPathComponent(".build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels", isDirectory: true)
        ]

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func collectMetalFiles(in shaderRoot: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: shaderRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "metal" else { continue }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
