import Foundation

// esh 2.1 UCMR — ProjectArtifact v2 (Managed Project Runtime, Tier A/B). ADDITIVE: the canonical `Artifact`
// (Artifact.swift) is unchanged; a v2 project carries this typed manifest inside `metadata["project"]`, so
// v1 `.webProject` artifacts (no such key) keep decoding exactly as before. Execution keys off the GENERIC
// `runtimeRequirements` abstraction, never off framework names — `projectType` is a descriptive label only.

/// Descriptive project label (what kind of project the model produced). NOT the execution key — see
/// `RuntimeRequirements.kind` for how the project actually runs.
public enum ProjectType: String, Codable, Hashable, Sendable, CaseIterable {
    case staticWeb = "static-web"       // Tier A: html/css/js, no modules (project.generate today)
    case threejs                        // Tier B: browser ES-module 3D (Three.js) via import map
    case browserModule = "browser-module" // Tier B: generic browser ES-module project
    case react                          // Tier C (future)
    case vite                           // Tier C (future)
    case nextjs                         // Tier C (future)
    case future                         // reserved
}

/// How a project actually executes. Generic on purpose: two frameworks can share a runtime kind, and a
/// runtime kind can host several project types. The runtime + validators read THIS, not `projectType`.
public struct RuntimeRequirements: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case browserStatic = "browser-static"   // Tier A: plain files in the sandboxed iframe, no modules
        case browserModule = "browser-module"   // Tier B: ES modules + import map, still browser-only, no Node
        case nodeManaged = "node-managed"       // Tier C (future): needs Node dev/build server + OS sandbox
    }
    public var kind: Kind
    /// ES-module import map (module specifier → in-bundle RELATIVE path) for Tier B. nil for Tier A.
    public var importMap: [String: String]?
    public var needsBuild: Bool     // Tier C
    public var needsServer: Bool    // Tier C

    public init(kind: Kind, importMap: [String: String]? = nil, needsBuild: Bool = false, needsServer: Bool = false) {
        self.kind = kind
        self.importMap = importMap
        self.needsBuild = needsBuild
        self.needsServer = needsServer
    }
    public static let browserStatic = RuntimeRequirements(kind: .browserStatic)
}

/// One resolved dependency the project relies on — pinned + integrity-verified + (for Tier B) vendored
/// offline by esh. Generated code never triggers an install of an unpinned/unknown package.
public struct ResolvedDependency: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        case vendored   // served by esh from the offline curated cache (Tier B default)
        case registry   // Tier C (future): installed from a pinned registry mirror, sandboxed
    }
    public enum Scope: String, Codable, Hashable, Sendable {
        case browser    // loaded in the browser (ES module / script)
        case node       // Tier C build/runtime dependency
    }
    public var name: String
    public var version: String
    public var integritySHA256: String?
    public var source: Source
    public var scope: Scope

    public init(name: String, version: String, integritySHA256: String? = nil,
                source: Source = .vendored, scope: Scope = .browser) {
        self.name = name
        self.version = version
        self.integritySHA256 = integritySHA256
        self.source = source
        self.scope = scope
    }
}

/// What the project is permitted to do at run time. Least-privilege by default: no network, sandbox-only FS.
public struct ProjectPermissions: Codable, Hashable, Sendable {
    public enum Network: Codable, Hashable, Sendable {
        case none                       // default — CSP connect-src 'none'
        case loopback                   // Tier C dev server on 127.0.0.1 only
        case allowlist([String])        // explicit, user-approved remote hosts (e.g. a live data feed)
    }
    public enum Filesystem: String, Codable, Hashable, Sendable {
        case sandboxOnly = "sandbox-only"
    }
    public var network: Network
    public var filesystem: Filesystem

    public init(network: Network = .none, filesystem: Filesystem = .sandboxOnly) {
        self.network = network
        self.filesystem = filesystem
    }
    public static let sandboxedNoNetwork = ProjectPermissions()
}

/// How the artifact should be previewed — activates the previously-dormant `.managed` mode / privilege.
public struct PreviewConfig: Codable, Hashable, Sendable {
    public var previewMode: PreviewDescriptor.Mode
    public var privilege: PrivilegeLevel
    /// Extra iframe `sandbox` tokens beyond the baseline `allow-scripts` (never `allow-same-origin`).
    public var sandboxFlags: [String]
    /// Content-Security-Policy to serve with the artifact (defense-in-depth beyond the iframe sandbox).
    public var csp: String?

    public init(previewMode: PreviewDescriptor.Mode, privilege: PrivilegeLevel,
                sandboxFlags: [String] = ["allow-scripts"], csp: String? = nil) {
        self.previewMode = previewMode
        self.privilege = privilege
        self.sandboxFlags = sandboxFlags
        self.csp = csp
    }
}

/// The v2 project manifest, stored in `Artifact.metadata["project"]`. Additive; absent on v1 artifacts.
public struct ProjectManifestV2: Codable, Hashable, Sendable {
    public static let metadataKey = "project"
    public static let currentSchemaVersion = "esh.project.v2"

    public var schemaVersion: String
    public var projectType: ProjectType
    public var runtimeRequirements: RuntimeRequirements
    public var dependencies: [ResolvedDependency]
    public var permissions: ProjectPermissions
    public var previewConfiguration: PreviewConfig
    /// Artifacts this project was derived from (generalizes provenance.sourceArtifactID to a list).
    public var sourceArtifacts: [UUID]

    public init(projectType: ProjectType,
                runtimeRequirements: RuntimeRequirements,
                dependencies: [ResolvedDependency] = [],
                permissions: ProjectPermissions = .sandboxedNoNetwork,
                previewConfiguration: PreviewConfig,
                sourceArtifacts: [UUID] = [],
                schemaVersion: String = ProjectManifestV2.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.projectType = projectType
        self.runtimeRequirements = runtimeRequirements
        self.dependencies = dependencies
        self.permissions = permissions
        self.previewConfiguration = previewConfiguration
        self.sourceArtifacts = sourceArtifacts
    }

    // Tolerant decode: older/partial manifests still load with sane defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? ProjectManifestV2.currentSchemaVersion
        self.projectType = try c.decodeIfPresent(ProjectType.self, forKey: .projectType) ?? .staticWeb
        self.runtimeRequirements = try c.decodeIfPresent(RuntimeRequirements.self, forKey: .runtimeRequirements) ?? .browserStatic
        self.dependencies = try c.decodeIfPresent([ResolvedDependency].self, forKey: .dependencies) ?? []
        self.permissions = try c.decodeIfPresent(ProjectPermissions.self, forKey: .permissions) ?? .sandboxedNoNetwork
        self.previewConfiguration = try c.decodeIfPresent(PreviewConfig.self, forKey: .previewConfiguration)
            ?? PreviewConfig(previewMode: .staticSandbox, privilege: .previewSandboxed)
        self.sourceArtifacts = try c.decodeIfPresent([UUID].self, forKey: .sourceArtifacts) ?? []
    }
}

// MARK: - Bridging to Artifact.metadata (JSONValue) — round-trips through Codable JSON.

public extension ProjectManifestV2 {
    /// Encode this manifest as a `JSONValue` for `Artifact.metadata["project"]`.
    func asJSONValue() throws -> JSONValue {
        let data = try JSONCoding.encoder.encode(self)
        return try JSONCoding.decoder.decode(JSONValue.self, from: data)
    }
    /// Extract a v2 manifest from an artifact's metadata, if present and decodable.
    static func from(metadata: [String: JSONValue]) -> ProjectManifestV2? {
        guard let value = metadata[metadataKey] else { return nil }
        guard let data = try? JSONCoding.encoder.encode(value) else { return nil }
        return try? JSONCoding.decoder.decode(ProjectManifestV2.self, from: data)
    }
}
