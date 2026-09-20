import Foundation
import Testing
@testable import EshCore

// HF9 §19 — the mocked Hugging Face source matrix: reference parsing, account/credentials, access
// classification, metadata, candidates + fit + recommendation, and token redaction. All deterministic
// (MockHFHTTPClient + InMemoryHFCredentialStore); no live network.
@Suite
struct HuggingFaceModelSourceTests {

    // MARK: helpers

    private struct FixedDeviceProfileProvider: DeviceProfileProviding {
        let profile: DeviceProfile
        func currentProfile() -> DeviceProfile { profile }
    }

    private func bigMac() -> DeviceProfile {
        DeviceProfile(
            platform: .macOS,
            physicalMemoryBytes: UInt64(64) * 1_073_741_824,
            availableMemoryBytes: UInt64(48) * 1_073_741_824,
            availableMemoryKind: .systemAvailable,
            availableStorageBytes: UInt64(500) * 1_073_741_824,
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            supportsAppleFoundationModels: true,
            osVersion: "test")
    }

    private func makeSource(http: MockHFHTTPClient,
                            creds: HFCredentialStore) -> HuggingFaceModelSource {
        HuggingFaceModelSource(
            http: http, credentials: creds,
            deviceProfileProvider: FixedDeviceProfileProvider(profile: bigMac()),
            root: PersistenceRoot(rootURL: tempDir()))
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: reference parsing (HF1)

    @Test func parsesReferenceForms() {
        #expect(HuggingFaceReference.parse("owner/repo")?.reference == "owner/repo")
        #expect(HuggingFaceReference.parse("https://huggingface.co/owner/repo")?.reference == "owner/repo")
        let tree = HuggingFaceReference.parse("https://huggingface.co/owner/repo/tree/main")
        #expect(tree?.reference == "owner/repo")
        #expect(tree?.revision == "main")
        let blob = HuggingFaceReference.parse("https://huggingface.co/owner/repo/blob/abc123/file.gguf")
        #expect(blob?.revision == "abc123")
        let at = HuggingFaceReference.parse("owner/repo@v2")
        #expect(at?.reference == "owner/repo")
        #expect(at?.revision == "v2")
        #expect(HuggingFaceReference.parse("not a ref") == nil)
        #expect(HuggingFaceReference.parse("single") == nil)
    }

    // MARK: token redaction

    @Test func redactsTokens() {
        let redacted = HFTokenRedaction.redact("failed with hf_ABC123def in header")
        #expect(!redacted.contains("hf_ABC123def"))
        #expect(redacted.contains("hf_***"))
    }

    // MARK: credentials store

    @Test func inMemoryCredentialRoundTrip() throws {
        let store = InMemoryHFCredentialStore()
        #expect(store.loadToken() == nil)
        try store.saveToken("hf_secret")
        #expect(store.loadToken() == "hf_secret")
        store.deleteToken()
        #expect(store.loadToken() == nil)
    }

    // MARK: account (HF3)

    @Test func accountStateDisconnectedWithoutToken() async {
        let src = makeSource(http: MockHFHTTPClient(), creds: InMemoryHFCredentialStore())
        #expect(await src.accountState() == .disconnected)
    }

    @Test func accountStateConnectedResolvesUsername() async {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/api/whoami-v2", .init(statusCode: 200, json: #"{"name":"alice"}"#))
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore(token: "hf_good"))
        #expect(await src.accountState() == .connected(username: "alice"))
        #expect(http.lastAuthorization == "Bearer hf_good")
    }

    @Test func accountStateTokenInvalid() async {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/api/whoami-v2", .init(statusCode: 401))
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore(token: "hf_bad"))
        #expect(await src.accountState() == .tokenInvalid)
    }

    @Test func connectValidatesAndStoresToken() async throws {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/api/whoami-v2", .init(statusCode: 200, json: #"{"name":"bob"}"#))
        let creds = InMemoryHFCredentialStore()
        let src = makeSource(http: http, creds: creds)
        let name = try await src.connect(token: "hf_ok")
        #expect(name == "bob")
        #expect(creds.loadToken() == "hf_ok")
    }

    @Test func connectRejectsInvalidToken() async {
        let http = MockHFHTTPClient()
        http.stub(url: "https://huggingface.co/api/whoami-v2", .init(statusCode: 403))
        let creds = InMemoryHFCredentialStore()
        let src = makeSource(http: http, creds: creds)
        await #expect(throws: HuggingFaceError.tokenInvalid) { try await src.connect(token: "hf_no") }
        #expect(creds.loadToken() == nil)   // rejected token is never stored
    }

    // MARK: access (HF2)

    private func stubRepo(_ http: MockHFHTTPClient, ref: String, json: String, status: Int = 200) {
        // The source requests `?blobs=true` for real per-file sizes; match by prefix so the query is covered.
        http.stub(prefix: "https://huggingface.co/api/models/\(ref)", .init(statusCode: status, json: json))
    }

    @Test func accessPublic() async throws {
        let http = MockHFHTTPClient()
        stubRepo(http, ref: "owner/pub", json: #"{"id":"owner/pub","private":false,"gated":false,"siblings":[{"rfilename":"config.json"}]}"#)
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore())
        let access = try await src.accessStatus(ModelSource(kind: .huggingFace, reference: "owner/pub"))
        #expect(access == .publicAccess)
    }

    @Test func accessPrivateAuthorized() async throws {
        let http = MockHFHTTPClient()
        stubRepo(http, ref: "owner/priv", json: #"{"id":"owner/priv","private":true,"gated":false,"siblings":[{"rfilename":"config.json"}]}"#)
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore(token: "hf_x"))
        let access = try await src.accessStatus(ModelSource(kind: .huggingFace, reference: "owner/priv"))
        #expect(access == .privateAuthorized)
    }

    @Test func accessGatedTermsRequiredWhenFileForbidden() async throws {
        let http = MockHFHTTPClient()
        stubRepo(http, ref: "owner/gated", json: #"{"id":"owner/gated","sha":"deadbeef","private":false,"gated":true,"siblings":[{"rfilename":"config.json"}]}"#)
        // Metadata is visible, but the actual file HEAD is forbidden → must accept terms on the web.
        http.stub(prefix: "https://huggingface.co/owner/gated/resolve/", .init(statusCode: 403))
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore(token: "hf_x"))
        let access = try await src.accessStatus(ModelSource(kind: .huggingFace, reference: "owner/gated"))
        if case .gatedTermsRequired = access {} else { Issue.record("expected gatedTermsRequired, got \(access)") }
    }

    @Test func accessGatedGrantedWhenFileReadable() async throws {
        let http = MockHFHTTPClient()
        stubRepo(http, ref: "owner/gated2", json: #"{"id":"owner/gated2","sha":"c0ffee","private":false,"gated":true,"siblings":[{"rfilename":"config.json"}]}"#)
        http.stub(prefix: "https://huggingface.co/owner/gated2/resolve/", .init(statusCode: 200))
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore(token: "hf_x"))
        let access = try await src.accessStatus(ModelSource(kind: .huggingFace, reference: "owner/gated2"))
        #expect(access == .publicAccess)   // terms already accepted for this account
    }

    @Test func accessNotFound() async throws {
        let http = MockHFHTTPClient()
        stubRepo(http, ref: "owner/missing", json: "{}", status: 404)
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore())
        let access = try await src.accessStatus(ModelSource(kind: .huggingFace, reference: "owner/missing"))
        #expect(access == .notFound)
    }

    @Test func accessAuthRequiredWithoutToken() async throws {
        let http = MockHFHTTPClient()
        stubRepo(http, ref: "owner/x", json: "{}", status: 403)
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore())   // no token
        let access = try await src.accessStatus(ModelSource(kind: .huggingFace, reference: "owner/x"))
        #expect(access == .authenticationRequired)
    }

    @Test func accessDeniedWithTokenButForbidden() async throws {
        let http = MockHFHTTPClient()
        stubRepo(http, ref: "owner/x", json: "{}", status: 403)
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore(token: "hf_x"))
        let access = try await src.accessStatus(ModelSource(kind: .huggingFace, reference: "owner/x"))
        #expect(access == .accessDenied)
    }

    // MARK: resolve (HF2/HF5) — metadata + license + compatibility

    @Test func resolveSurfacesLicenseAndCompatibility() async throws {
        let http = MockHFHTTPClient()
        stubRepo(http, ref: "acme/foo-gguf", json: #"""
        {"id":"acme/foo-gguf","sha":"abc","private":false,"gated":false,
         "cardData":{"license":"apache-2.0"},
         "siblings":[{"rfilename":"foo.Q4_K_M.gguf","size":1000000000}]}
        """#)
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore())
        let record = try await src.resolve(ModelSource(kind: .huggingFace, reference: "acme/foo-gguf"))
        #expect(record.license.identifier == "apache-2.0")
        #expect(record.access == .publicAccess)
        #expect(record.metadata.format == .gguf)
        #expect(record.gated == false)
        // GGUF with a supported backend and known-ish arch → at least "compatible" (never "verified" for raw HF).
        if case .verified = record.compatibility { Issue.record("raw HF resolve must not be 'verified'") }
    }

    // MARK: candidates + fit + recommendation (HF4)

    @Test func candidatesEnumerateQuantsWithFitAndOneRecommendation() async throws {
        let http = MockHFHTTPClient()
        // Param hint ("1B") so Model Fit resolves (not .unknown); sizes come from `lfs.size`.
        stubRepo(http, ref: "acme/bar-1B-gguf", json: #"""
        {"id":"acme/bar-1B-gguf","sha":"abc","private":false,"gated":false,
         "siblings":[
           {"rfilename":"bar-1B.Q4_K_M.gguf","lfs":{"size":2000000000}},
           {"rfilename":"bar-1B.Q8_0.gguf","lfs":{"size":4000000000}}
         ]}
        """#)
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore())
        let candidates = try await src.candidateArtifacts(ModelSource(kind: .huggingFace, reference: "acme/bar-1B-gguf"))
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.fit != nil })
        // Sizes are the real per-file sizes, not double-counted.
        #expect(Set(candidates.compactMap(\.sizeBytes)) == [2_000_000_000, 4_000_000_000])
        #expect(candidates.filter { $0.isRecommended }.count == 1)
        // A ~1B model fits comfortably on a 64 GB Mac, so the recommendation is the heaviest that fits well.
        let recommended = try #require(candidates.first { $0.isRecommended })
        #expect(recommended.sizeBytes == 4_000_000_000)
        #expect(recommended.fit?.fitClass == .comfortable)
    }

    @Test func recommendationFallsBackToLightestWhenFitUnknown() async throws {
        let http = MockHFHTTPClient()
        // No param hint → Model Fit is .unknown → conservative pick is the lightest non-unsupported artifact.
        stubRepo(http, ref: "acme/bar-gguf", json: #"""
        {"id":"acme/bar-gguf","sha":"abc","private":false,"gated":false,
         "siblings":[
           {"rfilename":"bar.Q4_K_M.gguf","lfs":{"size":2000000000}},
           {"rfilename":"bar.Q8_0.gguf","lfs":{"size":4000000000}}
         ]}
        """#)
        let src = makeSource(http: http, creds: InMemoryHFCredentialStore())
        let candidates = try await src.candidateArtifacts(ModelSource(kind: .huggingFace, reference: "acme/bar-gguf"))
        let recommended = try #require(candidates.first { $0.isRecommended })
        #expect(recommended.sizeBytes == 2_000_000_000)
    }
}
