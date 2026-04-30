import Foundation

public struct HuggingFaceModelDownloader: ModelDownloader, Sendable {
    private struct ModelInfo: Decodable {
        struct Sibling: Decodable {
            var rfilename: String
            var size: Int64?
        }

        var id: String
        var sha: String?
        var libraryName: String?
        var tags: [String]?
        var siblings: [Sibling]?

        private enum CodingKeys: String, CodingKey {
            case id = "id"
            case sha
            case libraryName = "library_name"
            case tags
            case siblings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeIfPresent(String.self, forKey: .id)
                ?? container.decode(String.self, forKey: .id)
            self.sha = try container.decodeIfPresent(String.self, forKey: .sha)
            self.libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
            self.tags = try container.decodeIfPresent([String].self, forKey: .tags)
            self.siblings = try container.decodeIfPresent([Sibling].self, forKey: .siblings)
        }
    }

    private let modelStore: ModelStore
    private let coordinator: DownloadCoordinator
    private let session: URLSession
    private let retryPolicy: NetworkRetryPolicy

    public init(
        modelStore: ModelStore,
        coordinator: DownloadCoordinator = .init(),
        session: URLSession = .shared,
        retryPolicy: NetworkRetryPolicy = .default
    ) {
        self.modelStore = modelStore
        self.coordinator = coordinator
        self.session = session
        self.retryPolicy = retryPolicy
    }

    public func install(
        source: ModelSource,
        suggestedID: String?,
        variant: String? = nil,
        progress: @escaping @Sendable (DownloadState) -> Void
    ) async throws -> ModelManifest {
        guard source.kind == .huggingFace else {
            throw StoreError.invalidManifest("Hugging Face downloader only supports Hugging Face sources.")
        }

        let reporter = ClosureProgressReporter(callback: progress)
        reporter.emit(DownloadState(phase: .resolving, message: "Resolving model metadata"))

        let info = try await fetchModelInfo(repoID: source.reference)
        let installID = suggestedID ?? sanitizedInstallID(from: source.reference)
        let installDirectory = try modelStore.prepareInstallDirectory(id: installID)
        let revision = source.revision ?? info.sha ?? "main"
        let modelPlan = try modelPlan(
            for: info.siblings ?? [],
            identifier: source.reference,
            tags: info.tags ?? [],
            libraryName: info.libraryName,
            variant: variant
        )
        guard modelPlan.files.isEmpty == false else {
            throw StoreError.invalidManifest("No downloadable files were found for \(source.reference).")
        }
        let plan = DownloadPlan(
            repoID: source.reference,
            revision: revision,
            files: modelPlan.files.map { .init(path: $0.rfilename, sizeBytes: $0.size) }
        )

        let downloadedFiles: [String]
        do {
            downloadedFiles = try await coordinator.download(
                plan: plan,
                into: installDirectory,
                reporter: reporter
            )
            try verifyInstall(
                files: modelPlan.files,
                downloadedFiles: downloadedFiles,
                installDirectory: installDirectory,
                backend: modelPlan.backend
            )
        } catch {
            try? FileManager.default.removeItem(at: installDirectory)
            throw error
        }

        reporter.emit(DownloadState(phase: .verifying, message: "Verifying install"))

        let actualSize = directorySize(at: installDirectory)
        let resolvedSize = max(actualSize, modelPlan.files.compactMap(\.size).reduce(0, +))
        let baseModelID = try resolvedBaseModelID(
            installDirectory: installDirectory,
            isAdapter: modelPlan.isAdapter
        )

        let install = ModelInstall(
            id: installID,
            spec: ModelSpec(
                id: installID,
                displayName: source.reference,
                backend: modelPlan.backend,
                source: source,
                localPath: installDirectory.path,
                baseModelID: baseModelID,
                architectureFingerprint: modelPlan.architectureFingerprint,
                variant: modelPlan.variant,
                task: modelPlan.task,
                inputModalities: modelPlan.inputModalities,
                outputModalities: modelPlan.outputModalities,
                capabilities: modelPlan.capabilities
            ),
            installPath: installDirectory.path,
            sizeBytes: resolvedSize,
            backendFormat: modelPlan.backendFormat,
            runtimeVersion: nil
        )
        let manifest = ModelManifest(install: install, files: downloadedFiles)
        try modelStore.save(manifest: manifest)

        reporter.emit(DownloadState(phase: .installed, bytesDownloaded: install.sizeBytes, totalBytes: install.sizeBytes, message: "Installed"))
        return manifest
    }

    private func fetchModelInfo(repoID: String) async throws -> ModelInfo {
        let encoded = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoID
        guard let url = URL(string: "https://huggingface.co/api/models/\(encoded)") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await NetworkRequestExecutor.data(
            session: session,
            request: URLRequest(url: url),
            retryPolicy: retryPolicy
        )
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StoreError.invalidManifest("Failed to resolve model \(repoID): HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(ModelInfo.self, from: data)
    }

    private func verifyInstall(
        files: [ModelInfo.Sibling],
        downloadedFiles: [String],
        installDirectory: URL,
        backend: BackendKind
    ) throws {
        let expectedFiles = Set(files.map(\.rfilename))
        let actualFiles = Set(downloadedFiles)
        guard expectedFiles == actualFiles else {
            throw StoreError.invalidManifest("Install verification failed because the downloaded file list did not match the planned file list.")
        }

        for file in files {
            let fileURL = installDirectory.appendingPathComponent(file.rfilename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw StoreError.invalidManifest("Install verification failed because \(file.rfilename) is missing.")
            }

            if let expectedSize = file.size {
                let actualSize = ResumeSupport.existingSize(at: fileURL)
                guard actualSize == expectedSize else {
                    throw StoreError.invalidManifest(
                        "Install verification failed for \(file.rfilename): expected \(expectedSize) bytes, found \(actualSize)."
                    )
                }
            }
        }

        switch backend {
        case .mlx:
            guard files.contains(where: { $0.rfilename.lowercased().hasSuffix(".safetensors") }) else {
                throw StoreError.invalidManifest("Install verification failed because no MLX weight files were downloaded.")
            }
            guard files.contains(where: {
                let filename = $0.rfilename.lowercased()
                return filename == "config.json"
                    || filename.hasSuffix("/config.json")
                    || filename == "adapter_config.json"
                    || filename.hasSuffix("/adapter_config.json")
            }) else {
                throw StoreError.invalidManifest("Install verification failed because no config.json or adapter_config.json was downloaded.")
            }
        case .gguf:
            guard files.contains(where: { $0.rfilename.lowercased().hasSuffix(".gguf") }) else {
                throw StoreError.invalidManifest("Install verification failed because no GGUF file was downloaded.")
            }
        case .onnx:
            break
        }
    }

    private func modelPlan(
        for siblings: [ModelInfo.Sibling],
        identifier: String,
        tags: [String],
        libraryName: String?,
        variant: String?
    ) throws -> (
        backend: BackendKind,
        backendFormat: String,
        files: [ModelInfo.Sibling],
        architectureFingerprint: String?,
        variant: String?,
        task: ModelTask,
        inputModalities: [ModelModality],
        outputModalities: [ModelModality],
        capabilities: ModelCapabilities,
        isAdapter: Bool
    ) {
        let filenames = siblings.map(\.rfilename)
        let format = ModelFilenameHeuristics.inferFormat(identifier: identifier, filenames: filenames)
        let architecture = ModelFilenameHeuristics.inferArchitecture(
            identifier: identifier,
            configModelType: nil,
            tags: tags,
            filenames: filenames
        )
        let isAdapter = ModelFilenameHeuristics.inferAdapter(
            identifier: identifier,
            tags: tags,
            filenames: filenames,
            libraryName: libraryName
        )

        if format == .gguf {
            let selection = ModelFilenameHeuristics.selectGGUFFiles(filenames, variant: variant)
            guard selection.selected != nil else {
                throw StoreError.invalidManifest(selection.warning ?? "Could not choose a GGUF file to install.")
            }
            let selectedFiles = Set(selection.related)
            let files = siblings.filter { sibling in
                selectedFiles.contains(sibling.rfilename) || auxiliaryFileAllowed(sibling.rfilename)
            }
            return (
                backend: .gguf,
                backendFormat: "gguf",
                files: files,
                architectureFingerprint: architecture == .unknown ? nil : architecture.rawValue,
                variant: variant?.uppercased() ?? ModelFilenameHeuristics.inferQuantization(identifier: "", filenames: Array(selectedFiles), format: .gguf),
                task: .text,
                inputModalities: [.text],
                outputModalities: [.text],
                capabilities: .textGeneration,
                isAdapter: false
            )
        }

        guard format == .mlx else {
            throw StoreError.invalidManifest(
                "Unsupported Hugging Face repo layout. MLX installs need config.json or adapter_config.json with safetensors; GGUF installs need a .gguf file."
            )
        }

        let loweredFilenames = filenames.map { $0.lowercased() }
        let hasSafetensors = loweredFilenames.contains { $0.hasSuffix(".safetensors") }
        let hasModelConfig = loweredFilenames.contains { $0 == "config.json" || $0.hasSuffix("/config.json") }
        let hasAdapterConfig = loweredFilenames.contains { $0 == "adapter_config.json" || $0.hasSuffix("/adapter_config.json") }
        guard hasSafetensors, hasModelConfig || hasAdapterConfig else {
            throw StoreError.invalidManifest(
                "Unsupported MLX repo layout. Expected safetensors plus config.json or adapter_config.json."
            )
        }

        let files = siblings.filter { sibling in
            let file = sibling.rfilename.lowercased()
            return file.hasSuffix(".json")
                || file.hasSuffix(".safetensors")
                || file.hasSuffix(".txt")
                || file.hasSuffix(".model")
        }
        return (
            backend: .mlx,
            backendFormat: "mlx",
            files: files,
            architectureFingerprint: architecture == .unknown ? nil : architecture.rawValue,
            variant: variant ?? (isAdapter ? "adapter" : nil),
            task: .text,
            inputModalities: [.text],
            outputModalities: [.text],
            capabilities: .textGeneration,
            isAdapter: isAdapter
        )
    }

    private func auxiliaryFileAllowed(_ filename: String) -> Bool {
        let file = filename.lowercased()
        return file.hasSuffix(".json")
            || file.hasSuffix(".txt")
            || file.hasSuffix(".model")
    }

    private func sanitizedInstallID(from repoID: String) -> String {
        repoID
            .lowercased()
            .replacingOccurrences(of: "/", with: "--")
            .replacingOccurrences(of: " ", with: "-")
    }

    private func resolvedBaseModelID(installDirectory: URL, isAdapter: Bool) throws -> String? {
        guard isAdapter else {
            return nil
        }

        let adapterConfigURL = installDirectory.appendingPathComponent("adapter_config.json")
        guard FileManager.default.fileExists(atPath: adapterConfigURL.path) else {
            throw StoreError.invalidManifest("Adapter install is missing adapter_config.json.")
        }

        let data = try Data(contentsOf: adapterConfigURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseModelID = object["base_model_name_or_path"] as? String,
              baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw StoreError.invalidManifest("Adapter install is missing base_model_name_or_path in adapter_config.json.")
        }
        return baseModelID
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let fileSize = values?.fileSize else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }
}
