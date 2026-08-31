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
        self.stateRoot = stateRoot
        self.configPath = configPath
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

    public static func macOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
