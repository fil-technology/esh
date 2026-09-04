import Foundation
import Testing
@testable import EshCore

@Suite
struct ProjectArtifactV2Tests {
    @Test func manifestRoundTripsThroughMetadata() throws {
        let manifest = ProjectManifestV2(
            projectType: .threejs,
            runtimeRequirements: RuntimeRequirements(kind: .browserModule,
                                                     importMap: ["three": "vendor/three/three.module.js"]),
            dependencies: [ResolvedDependency(name: "three", version: "r168",
                                              integritySHA256: "abc123", source: .vendored, scope: .browser)],
            permissions: ProjectPermissions(network: .none),
            previewConfiguration: PreviewConfig(previewMode: .managed, privilege: .previewSandboxed,
                                                sandboxFlags: ["allow-scripts"], csp: "default-src 'self'"),
            sourceArtifacts: [])
        // Bridge into Artifact.metadata and back out.
        let jv = try manifest.asJSONValue()
        let artifact = Artifact(kind: .webProject, mimeType: "text/html", entrypoint: "index.html",
                                metadata: [ProjectManifestV2.metadataKey: jv], preview: .staticSandbox)
        let decoded = try #require(ProjectManifestV2.from(metadata: artifact.metadata))
        #expect(decoded.projectType == .threejs)
        #expect(decoded.runtimeRequirements.kind == .browserModule)
        #expect(decoded.runtimeRequirements.importMap?["three"] == "vendor/three/three.module.js")
        #expect(decoded.dependencies.first?.name == "three")
        #expect(decoded.dependencies.first?.integritySHA256 == "abc123")
        #expect(decoded.previewConfiguration.previewMode == .managed)
        #expect(decoded.schemaVersion == ProjectManifestV2.currentSchemaVersion)
    }

    @Test func networkAllowlistRoundTrips() throws {
        let m = ProjectManifestV2(projectType: .threejs,
                                  runtimeRequirements: RuntimeRequirements(kind: .browserModule),
                                  permissions: ProjectPermissions(network: .allowlist(["earthquake.usgs.gov"])),
                                  previewConfiguration: PreviewConfig(previewMode: .managed, privilege: .previewSandboxed))
        let decoded = try #require(ProjectManifestV2.from(metadata: [ProjectManifestV2.metadataKey: try m.asJSONValue()]))
        if case .allowlist(let hosts) = decoded.permissions.network {
            #expect(hosts == ["earthquake.usgs.gov"])
        } else { Issue.record("network policy did not round-trip as allowlist") }
    }

    @Test func v1ArtifactWithoutProjectMetadataStillDecodes() {
        // A v1 .webProject (no "project" key) must NOT produce a v2 manifest, and must not crash.
        let v1 = Artifact(kind: .webProject, mimeType: "text/html", entrypoint: "index.html",
                          metadata: ["fileCount": .int(3), "files": .array([.string("index.html")])],
                          preview: .staticSandbox)
        #expect(ProjectManifestV2.from(metadata: v1.metadata) == nil)
    }

    @Test func staticWebDefaultsAreLeastPrivilege() {
        let rt = RuntimeRequirements.browserStatic
        #expect(rt.kind == .browserStatic)
        #expect(rt.importMap == nil)
        #expect(!rt.needsBuild && !rt.needsServer)
        let perms = ProjectPermissions.sandboxedNoNetwork
        if case .none = perms.network {} else { Issue.record("default network should be .none") }
        #expect(perms.filesystem == .sandboxOnly)
    }
}
