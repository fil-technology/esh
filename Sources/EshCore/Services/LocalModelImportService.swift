import Foundation

public struct DetectedLocalModel: Sendable, Equatable {
    public var backend: BackendKind
    /// Regular files that make up the model (relative names are derived on import).
    public var files: [URL]
    public var isDirectory: Bool
}

public struct LocalModelScanResult: Sendable, Equatable {
    /// Ids newly registered from unmanifested model directories under the store.
    public var registered: [String]
    /// Install directory ids that hold no valid model (interrupted/partial downloads).
    public var orphans: [String]

    public init(registered: [String] = [], orphans: [String] = []) {
        self.registered = registered
        self.orphans = orphans
    }
}

/// Import local model directories/GGUF files as first-class installs (no re-download), discover
/// models already present under the store (e.g. on external storage), and clean up orphaned
/// partial-download directories.
public struct LocalModelImportService: Sendable {
    public init() {}

    // MARK: - Detection

    /// Determine whether `url` (a directory or a `.gguf` file) is a usable local model.
    public func detect(at url: URL) -> DetectedLocalModel? {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        if !isDir.boolValue {
            return url.pathExtension.lowercased() == "gguf"
                ? DetectedLocalModel(backend: .gguf, files: [url], isDirectory: false)
                : nil
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let regularFiles = contents.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let names = Set(regularFiles.map { $0.lastPathComponent.lowercased() })

        let ggufFiles = regularFiles.filter { $0.pathExtension.lowercased() == "gguf" }
        if !ggufFiles.isEmpty {
            // Include tokenizer/config sidecars if present.
            let sidecars = regularFiles.filter { ["json", "txt", "model"].contains($0.pathExtension.lowercased()) }
            return DetectedLocalModel(backend: .gguf, files: ggufFiles + sidecars, isDirectory: true)
        }

        let hasSafetensors = regularFiles.contains { $0.pathExtension.lowercased() == "safetensors" }
        let hasConfig = names.contains("config.json") || names.contains("adapter_config.json")
        if hasSafetensors && hasConfig {
            return DetectedLocalModel(backend: .mlx, files: regularFiles, isDirectory: true)
        }
        return nil
    }

    // MARK: - Import

    /// Copy (or move) a local model into the store and register it. Returns the install.
    @discardableResult
    public func importModel(
        from source: URL,
        id explicitID: String? = nil,
        move: Bool = false,
        root: PersistenceRoot,
        store: FileModelStore? = nil
    ) throws -> ModelInstall {
        try StorageService().ensureAssetsAvailable(root: root)
        guard let detected = detect(at: source) else {
            throw StoreError.invalidManifest(
                "No MLX (config.json + safetensors) or GGUF model was found at \(source.path)."
            )
        }
        let modelStore = store ?? FileModelStore(root: root)
        let id = sanitize(explicitID ?? source.deletingPathExtension().lastPathComponent)
        let installURL = try modelStore.prepareInstallDirectory(id: id)

        var relativeFiles: [String] = []
        let fileManager = FileManager.default
        for file in detected.files {
            let destination = installURL.appendingPathComponent(file.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if move {
                do {
                    try fileManager.moveItem(at: file, to: destination)
                } catch {
                    try fileManager.copyItem(at: file, to: destination)
                }
            } else {
                try fileManager.copyItem(at: file, to: destination)
            }
            relativeFiles.append(destination.lastPathComponent)
        }

        let size = directorySize(at: installURL)
        let spec = ModelSpec(
            id: id,
            displayName: source.lastPathComponent,
            backend: detected.backend,
            source: ModelSource(kind: .localPath, reference: source.path),
            localPath: installURL.path,
            variant: nil
        )
        let install = ModelInstall(
            id: id,
            spec: spec,
            installPath: installURL.path,
            sizeBytes: size,
            backendFormat: detected.backend.rawValue
        )
        try modelStore.save(manifest: ModelManifest(install: install, files: relativeFiles))
        return install
    }

    // MARK: - Scan / discover

    /// Inspect the store's `installs/` directory: register any unmanifested directory that holds a
    /// valid model, and list the ids of directories that are empty/partial (orphans).
    public func scanStore(root: PersistenceRoot) throws -> LocalModelScanResult {
        try StorageService().ensureAssetsAvailable(root: root)
        let installsURL = root.modelsURL.appendingPathComponent("installs", isDirectory: true)
        let store = FileModelStore(root: root)
        let known = Set((try? store.listInstalls().map(\.id)) ?? [])
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: installsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return LocalModelScanResult()
        }

        var result = LocalModelScanResult()
        for entry in entries {
            let id = entry.lastPathComponent
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if known.contains(id) { continue }
            if detect(at: entry) != nil {
                // A valid model directory without a manifest — register it in place.
                let detected = detect(at: entry)!
                let size = directorySize(at: entry)
                let spec = ModelSpec(
                    id: id,
                    displayName: id,
                    backend: detected.backend,
                    source: ModelSource(kind: .localPath, reference: entry.path),
                    localPath: entry.path
                )
                let install = ModelInstall(
                    id: id,
                    spec: spec,
                    installPath: entry.path,
                    sizeBytes: size,
                    backendFormat: detected.backend.rawValue
                )
                let files = ((try? fileManager.contentsOfDirectory(atPath: entry.path)) ?? [])
                try store.save(manifest: ModelManifest(install: install, files: files))
                result.registered.append(id)
            } else {
                result.orphans.append(id)
            }
        }
        return result
    }

    /// Import every detected model directly under `directory` (for bulk-registering a folder of
    /// downloaded models).
    @discardableResult
    public func importDirectory(_ directory: URL, root: PersistenceRoot, move: Bool = false) throws -> [ModelInstall] {
        let fileManager = FileManager.default
        var installs: [ModelInstall] = []
        if detect(at: directory) != nil {
            installs.append(try importModel(from: directory, move: move, root: root))
            return installs
        }
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for entry in entries where detect(at: entry) != nil {
            installs.append(try importModel(from: entry, move: move, root: root))
        }
        return installs
    }

    /// Delete orphaned install directories that hold no valid model.
    @discardableResult
    public func cleanupOrphans(root: PersistenceRoot, ids: [String]) throws -> [String] {
        let installsURL = root.modelsURL.appendingPathComponent("installs", isDirectory: true)
        let fileManager = FileManager.default
        var removed: [String] = []
        for id in ids {
            let url = installsURL.appendingPathComponent(id, isDirectory: true)
            // Never remove a directory that has a manifest.
            if (try? FileModelStore(root: root).loadManifest(id: id)) != nil { continue }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                removed.append(id)
            }
        }
        return removed
    }

    // MARK: - Helpers

    private func sanitize(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let mapped = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "local-model" : trimmed
    }

    private func directorySize(at url: URL) -> Int64 {
        StorageService().directorySize(at: url)
    }
}
