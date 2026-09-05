import Foundation

/// Aggregated, machine-readable health report for esh. Produced by `esh doctor` (human + `--json`)
/// so Ashex and other external tooling have a single stable schema for diagnosing the most common
/// installation/runtime failures from one command.
public struct DoctorReport: Codable, Sendable {
    public var status: String            // "ok" | "degraded"
    public var version: String?
    public var macOS: String
    public var host: HostMachineProfile
    public var storage: StorageReport
    public var engines: [EngineStatus]
    public var models: DoctorModelsReport
    public var appleIntelligence: AppleIntelligenceStatus
    public var audio: AudioRuntimeStatus
    public var stateRoot: String
    public var configPath: String

    public init(
        status: String,
        version: String?,
        macOS: String,
        host: HostMachineProfile,
        storage: StorageReport,
        engines: [EngineStatus],
        models: DoctorModelsReport,
        appleIntelligence: AppleIntelligenceStatus,
        audio: AudioRuntimeStatus,
        stateRoot: String,
        configPath: String
    ) {
        self.status = status
        self.version = version
        self.macOS = macOS
        self.host = host
        self.storage = storage
        self.engines = engines
        self.models = models
        self.appleIntelligence = appleIntelligence
        self.audio = audio
        self.stateRoot = stateRoot
        self.configPath = configPath
    }
}

/// State of the generative-audio backends. SFX (AudioGen) runs in an ISOLATED Python runtime kept off the
/// main venv; music (MusicGen) runs in the bridge. Both cache weights under the assets root (SSD), never the
/// internal HF cache. Reported so the neural audio provider is observable and installable as first-class.
public struct AudioRuntimeStatus: Codable, Sendable {
    /// Path to the isolated AudioGen venv python, if discoverable (env override or a known managed path).
    public var isolatedRuntimePath: String?
    public var sfxModelInstalled: Bool     // facebook/audiogen-medium present under the assets cache
    public var musicModelInstalled: Bool   // facebook/musicgen-small present under the assets cache

    public init(isolatedRuntimePath: String?, sfxModelInstalled: Bool, musicModelInstalled: Bool) {
        self.isolatedRuntimePath = isolatedRuntimePath
        self.sfxModelInstalled = sfxModelInstalled
        self.musicModelInstalled = musicModelInstalled
    }
}

public struct DoctorModelsReport: Codable, Sendable {
    public var installedCount: Int
    /// Ids of installs whose payload directory is missing or empty (interrupted/corrupt installs).
    public var incomplete: [String]
    public var defaultModel: String?

    public init(installedCount: Int, incomplete: [String], defaultModel: String?) {
        self.installedCount = installedCount
        self.incomplete = incomplete
        self.defaultModel = defaultModel
    }
}

public struct DoctorService: Sendable {
    public init() {}

    public func report(root: PersistenceRoot, version: String?) -> DoctorReport {
        let engines = (try? EngineOrchestratorService(root: root).listEngines()) ?? []
        let requiredReady = engines.filter(\.required).allSatisfy(\.ready)

        let storage = StorageService().report(root: root)
        let models = modelsReport(root: root)

        // Degraded if a required engine is down OR the configured assets volume is unavailable.
        let storageOK = storage.status != "unavailable"
        let status = (requiredReady && storageOK) ? "ok" : "degraded"

        return DoctorReport(
            status: status,
            version: version,
            macOS: Self.macOSVersionString(),
            host: HostMachineProfileService().currentProfile(),
            storage: storage,
            engines: engines,
            models: models,
            appleIntelligence: AppleIntelligenceService().status(),
            audio: audioRuntimeStatus(root: root),
            stateRoot: root.stateRootURL.path,
            configPath: root.stateRootURL.appendingPathComponent("config.toml").path
        )
    }

    private func modelsReport(root: PersistenceRoot) -> DoctorModelsReport {
        let store = FileModelStore(root: root)
        // If the assets volume is unavailable we cannot enumerate installs reliably; report 0
        // rather than guessing.
        let installs = (try? store.listInstalls()) ?? []
        let fileManager = FileManager.default
        var incomplete: [String] = []
        for install in installs {
            let path = install.installPath
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDir)
            let empty = ((try? fileManager.contentsOfDirectory(atPath: path))?.isEmpty ?? true)
            if !exists || !isDir.boolValue || empty {
                incomplete.append(install.id)
            }
        }
        let defaultModel = (try? RoutingConfigurationStore(root: root).load())?.mainModel
        return DoctorModelsReport(
            installedCount: installs.count,
            incomplete: incomplete,
            defaultModel: defaultModel
        )
    }

    /// Probe the generative-audio backends: is the isolated SFX runtime discoverable, and are the model
    /// weights cached under the assets root? Pure on-disk / env checks — no downloads, no subprocess.
    private func audioRuntimeStatus(root: PersistenceRoot) -> AudioRuntimeStatus {
        let fm = FileManager.default
        var isolated: String?
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["ESH_AUDIOGEN_PYTHON"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append("/Volumes/Sviat SSD/esh-runtime/audio/audiogen-mlx/venv/bin/python")
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".esh/runtime/audio/audiogen-mlx/venv/bin/python"))
        for c in candidates where fm.fileExists(atPath: c) { isolated = c; break }

        let audioCache = root.cachesURL.appendingPathComponent("audio-models/hub", isDirectory: true)
        let sfx = fm.fileExists(atPath: audioCache.appendingPathComponent("models--facebook--audiogen-medium").path)
        let music = fm.fileExists(atPath: audioCache.appendingPathComponent("models--facebook--musicgen-small").path)
        return AudioRuntimeStatus(isolatedRuntimePath: isolated, sfxModelInstalled: sfx, musicModelInstalled: music)
    }

    public static func macOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
