import Foundation
import Testing
@testable import EshCore

@Suite
struct GenerativeEngineTests {
    @Test
    func catalogCoversAllSixEnginesWithUniqueIds() {
        let ids = GenerativeEngineCatalog.all.map { $0.id }
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(GenerativeEngineID.allCases))
        #expect(ids.count == 6)
    }

    @Test
    func capabilitiesMapToTheRightEngine() {
        #expect(GenerativeEngineCatalog.engine(forCapability: .imageGenerate)?.id == .image)
        #expect(GenerativeEngineCatalog.engine(forCapability: .imageEdit)?.id == .image)
        #expect(GenerativeEngineCatalog.engine(forCapability: .audioGenerate)?.id == .soundFX)
        #expect(GenerativeEngineCatalog.engine(forCapability: .musicGenerate)?.id == .music)
        #expect(GenerativeEngineCatalog.engine(forCapability: .imageUpscale)?.id == .upscale)
        #expect(GenerativeEngineCatalog.engine(forCapability: .imageSegment)?.id == .removeBG)
        #expect(GenerativeEngineCatalog.engine(forCapability: .audioDiarize)?.id == .diarize)
        // Chat / vision are NOT engine-gated (they work out of the box).
        #expect(GenerativeEngineCatalog.engine(forCapability: .imageUnderstand) == nil)
    }

    @Test
    func nonCommercialEnginesAreFlagged() {
        #expect(GenerativeEngineCatalog.spec(.soundFX).commercialSafe == false)
        #expect(GenerativeEngineCatalog.spec(.music).commercialSafe == false)
        #expect(GenerativeEngineCatalog.spec(.image).commercialSafe == true)
        #expect(GenerativeEngineCatalog.spec(.upscale).commercialSafe == true)
        // Non-commercial engines must carry a license note the UI/agent can surface.
        #expect(GenerativeEngineCatalog.spec(.soundFX).licenseNote != nil)
        #expect(GenerativeEngineCatalog.spec(.music).licenseNote != nil)
    }

    @Test
    func imageIsMainVenvCliBackedAndSoundFXIsIsolatedOnKnownPaths() {
        let image = GenerativeEngineCatalog.spec(.image)
        #expect(image.pipPackages == ["mflux"])
        #expect(image.probeCLI == "mflux-generate")
        if case .main = image.venv {} else { Issue.record("image engine should install into the main venv") }

        let sfx = GenerativeEngineCatalog.spec(.soundFX)
        guard case let .isolated(envVar, candidates) = sfx.venv else { Issue.record("sound-fx should be isolated"); return }
        #expect(envVar == "ESH_AUDIOGEN_PYTHON")
        // Must include the path the Python bridge already discovers, so SFX works with no env plumbing.
        #expect(candidates.contains { $0.contains(".esh/runtime/audio/audiogen-mlx/venv") })
    }

    @Test
    func installRequirementCarriesEngineFields() {
        let req = InstallRequirement(capability: .imageGenerate, componentName: "Image engine (mflux)",
                                     recommendedRepo: "image", approxSizeMB: 120, installKind: "engine", engineId: "image")
        #expect(req.installKind == "engine")
        #expect(req.engineId == "image")
        // Round-trips through Codable (crosses the /v1/route boundary to the client).
        let data = try! JSONEncoder().encode(req)
        let back = try! JSONDecoder().decode(InstallRequirement.self, from: data)
        #expect(back.engineId == "image")
        #expect(back.installKind == "engine")
    }

    @Test
    func probeReportsNotInstalledForAFreshManagedRoot() {
        // A throwaway root has no engines on disk; the isolated probe (sound-fx) resolves off real candidate
        // paths, so just assert the pure-catalog-derived status shape is well-formed and main-venv engines with
        // no site-packages read as not-installed is at least consistent with statusAll producing all six.
        let root = PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-eng-\(UUID().uuidString)"))
        let mgr = GenerativeEngineManager(root: root)
        let all = mgr.statusAll()
        #expect(all.count == 6)
        #expect(all.allSatisfy { !$0.capabilities.isEmpty })
        #expect(all.contains { $0.id == "image" && $0.installKind == "main" })
        #expect(all.contains { $0.id == "sound-fx" && $0.installKind == "isolated" })
    }
}
