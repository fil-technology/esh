import Foundation

public struct CacheBuildResult: Sendable {
    public var artifact: CacheArtifact
    public var payload: Data

    public init(artifact: CacheArtifact, payload: Data) {
        self.artifact = artifact
        self.payload = payload
    }
}

public struct CacheBuildContext: Sendable {
    public let packageID: UUID
    public let task: String
    public let taskFingerprint: String
    public let fileCount: Int
    public let reused: Bool
    public let policyReason: String?

    public init(
        packageID: UUID,
        task: String,
        taskFingerprint: String,
        fileCount: Int,
        reused: Bool,
        policyReason: String? = nil
    ) {
        self.packageID = packageID
        self.task = task
        self.taskFingerprint = taskFingerprint
        self.fileCount = fileCount
        self.reused = reused
        self.policyReason = policyReason
    }
}

public struct CacheService: Sendable {
    private let cacheStore: CacheStore

    public init(cacheStore: CacheStore) {
        self.cacheStore = cacheStore
    }

    public func buildArtifact(
        runtime: BackendRuntime,
        session: ChatSession,
        install: ModelInstall,
        codec: CacheSnapshotCodec,
        compressor: CacheCompressor,
        artifactMode: CacheMode? = nil,
        context: CacheBuildContext? = nil
    ) async throws -> CacheBuildResult {
        try await runtime.prepare(session: session)
        let snapshot = try await runtime.exportRuntimeCache()
        let encodedSnapshot = try codec.encode(snapshot: snapshot)
        let compression = try await compressor.compress(encodedSnapshot)
        let manifest = CacheManifest(
            backend: runtime.backend,
            modelID: install.id,
            tokenizerID: install.spec.tokenizerID,
            architectureFingerprint: install.spec.architectureFingerprint ?? Fingerprint.sha256([install.id, install.backendFormat]),
            runtimeVersion: install.runtimeVersion ?? "mlx-vlm-0.4.3+mlx-lm-bridge-v2",
            cacheFormatVersion: codec.formatVersion,
            compressorVersion: compressor.version,
            cacheMode: artifactMode ?? compressor.mode,
            sessionID: session.id,
            sessionName: session.name,
            contextPackageID: context?.packageID,
            contextTask: context?.task,
            contextTaskFingerprint: context?.taskFingerprint,
            contextFileCount: context?.fileCount,
            contextReused: context?.reused,
            policyReason: context?.policyReason
        )
        let artifact = CacheArtifact(
            manifest: manifest,
            artifactPath: "",
            sizeBytes: compression.compressedSize,
            snapshotSizeBytes: compression.originalSize,
            metrics: await runtime.metrics
        )
        try cacheStore.saveArtifact(artifact, payload: compression.data)
        return CacheBuildResult(artifact: artifact, payload: compression.data)
    }

    public func loadArtifact(
        id: UUID,
        runtime: BackendRuntime,
        codec: CacheSnapshotCodec,
        compressor: CacheCompressor,
        checker: CompatibilityChecking
    ) async throws -> CacheArtifact {
        let (artifact, payload) = try cacheStore.loadArtifact(id: id)
        try checker.validate(manifest: artifact.manifest)
        try await runtime.validateCacheCompatibility(artifact.manifest)
        let snapshotData = try await compressor.decompress(payload)
        let snapshot = try codec.decode(data: snapshotData)
        try await runtime.importRuntimeCache(snapshot)
        return artifact
    }

    public func listArtifacts() throws -> [CacheArtifact] {
        try cacheStore.listArtifacts()
    }

    public func loadArtifactForRuntime(
        id: UUID,
        runtime: BackendRuntime,
        install: ModelInstall,
        codec: CacheSnapshotCodec,
        compressor: CacheCompressor,
        checker: CompatibilityChecking
    ) async throws -> CacheArtifact {
        _ = install
        return try await loadArtifact(
            id: id,
            runtime: runtime,
            codec: codec,
            compressor: compressor,
            checker: checker
        )
    }
}
