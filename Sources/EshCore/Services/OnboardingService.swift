import Foundation

/// Persisted onboarding state, so esh knows whether first-run setup has completed and future
/// releases can add migration steps.
public struct OnboardingState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var completed: Bool
    public var completedAtISO8601: String?
    public var selectedModelID: String?
    public var storageMode: String?    // "internal" | "external"

    public init(
        version: Int = OnboardingState.currentVersion,
        completed: Bool = false,
        completedAtISO8601: String? = nil,
        selectedModelID: String? = nil,
        storageMode: String? = nil
    ) {
        self.version = version
        self.completed = completed
        self.completedAtISO8601 = completedAtISO8601
        self.selectedModelID = selectedModelID
        self.storageMode = storageMode
    }
}

public struct OnboardingStateStore: Sendable {
    public static let fileName = "onboarding.json"
    private let stateRootURL: URL

    public init(root: PersistenceRoot = .default()) {
        self.stateRootURL = root.stateRootURL
    }

    public var stateURL: URL { stateRootURL.appendingPathComponent(Self.fileName) }

    public func load() -> OnboardingState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONCoding.decoder.decode(OnboardingState.self, from: data) else {
            return OnboardingState()
        }
        return state
    }

    public func save(_ state: OnboardingState) throws {
        try FileManager.default.createDirectory(at: stateRootURL, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}

/// A snapshot of the machine + esh install used to drive onboarding decisions.
public struct OnboardingEnvironment: Sendable {
    public var host: HostMachineProfile
    public var macOS: String
    public var mlxReady: Bool
    public var llamaCppReady: Bool
    public var storage: StorageReport
    public var installedModelCount: Int
    public var installedModelIDs: [String]
    public var appleIntelligence: AppleIntelligenceStatus

    public var hasUsableEngine: Bool { mlxReady || llamaCppReady }
    /// True when the user could get a first result with zero downloads via Apple Intelligence.
    public var hasZeroDownloadOption: Bool { appleIntelligence.available }

    public var missingEngineHelp: String? {
        guard !hasUsableEngine else { return nil }
        return """
        No local inference engine is ready.
          • MLX (Apple Silicon): run `esh doctor` to see the Python/MLX status.
          • llama.cpp (GGUF): install with `brew install llama.cpp`.
        Run `esh doctor` for details, then `esh onboard` again.
        """
    }
}

/// Pure, testable core of onboarding: environment detection, recommendations, and state.
/// The interactive prompts live in the `esh` OnboardCommand; this type holds the logic so it can
/// be reused by a future GUI and unit-tested without a TTY.
public struct OnboardingService: Sendable {
    private let registry: RecommendedModelRegistry

    public init(registry: RecommendedModelRegistry = RecommendedModelRegistry()) {
        self.registry = registry
    }

    public func detectEnvironment(root: PersistenceRoot) -> OnboardingEnvironment {
        let engines = (try? EngineOrchestratorService(root: root).listEngines()) ?? []
        let mlxReady = engines.first { $0.id == .mlx }?.ready ?? false
        let llamaReady = engines.first { $0.id == .llamaCpp }?.ready ?? false
        let installs = (try? FileModelStore(root: root).listInstalls()) ?? []
        return OnboardingEnvironment(
            host: HostMachineProfileService().currentProfile(),
            macOS: DoctorService.macOSVersionString(),
            mlxReady: mlxReady,
            llamaCppReady: llamaReady,
            storage: StorageService().report(root: root, computeSizes: false),
            installedModelCount: installs.count,
            installedModelIDs: installs.map(\.id),
            appleIntelligence: AppleIntelligenceService().status()
        )
    }

    /// Recommend models for the given use case, preferring a backend the host can actually run.
    public func recommendations(
        useCase: RecommendedModelRegistry.UseCase,
        environment: OnboardingEnvironment,
        limit: Int = 4
    ) -> [RecommendedModel] {
        // Prefer MLX on Apple Silicon when ready; fall back to GGUF when only llama.cpp is ready.
        let backend: BackendKind?
        if environment.mlxReady {
            backend = .mlx
        } else if environment.llamaCppReady {
            backend = .gguf
        } else {
            backend = nil
        }
        var models = registry.recommend(
            useCase: useCase,
            host: environment.host,
            backend: backend,
            limit: limit
        )
        // If nothing fits the safe budget, offer the smallest options regardless of budget so the
        // user is never left with an empty list.
        if models.isEmpty {
            models = registry.recommend(useCase: .lowMemory, host: nil, backend: backend, limit: limit)
        }
        return models
    }

    public func markCompleted(
        root: PersistenceRoot,
        selectedModelID: String?,
        storageMode: String,
        now: Date = Date()
    ) throws {
        let formatter = ISO8601DateFormatter()
        let state = OnboardingState(
            version: OnboardingState.currentVersion,
            completed: true,
            completedAtISO8601: formatter.string(from: now),
            selectedModelID: selectedModelID,
            storageMode: storageMode
        )
        try OnboardingStateStore(root: root).save(state)
    }

    public func hasCompleted(root: PersistenceRoot) -> Bool {
        OnboardingStateStore(root: root).load().completed
    }
}
