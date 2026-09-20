import Foundation
import EshCore

// HF9 — the public Hugging Face facade on EshRuntime. Composes the existing HF source (metadata/access/
// candidates/recommendation), the Keychain credential store, the existing search catalog, and the existing
// installer — threading the connected token into every authed path (repo metadata, gated file probe, search,
// download Authorization header). The raw token lives only in the Keychain; this surface exposes account
// STATE, never the token, and records install provenance without credentials.
public extension EshRuntime {

    // MARK: - Configuration (optional; production defaults to Keychain + URLSession)

    /// Override the HF credential store and/or HTTP client (tests, or a host with a bespoke secure store).
    /// Production leaves both nil → Keychain generic-password store + `URLSession.shared`.
    func configureHuggingFace(credentials: HFCredentialStore? = nil, http: HFHTTPClient? = nil) {
        if let credentials { hfCredentialStoreOverride = credentials }
        if let http { hfHTTPClientOverride = http }
    }

    // MARK: - Account (HF3)

    /// The Hugging Face account state (`disconnected` / `connected(username:)` / `tokenInvalid`). Validates a
    /// stored token against `whoami`; a transient network error keeps the connected view.
    func huggingFaceAccountState() async -> HFAccountState {
        await hfSource().accountState()
    }

    /// Validate a personal access token against `whoami` and, on success, store it in the Keychain. Returns
    /// the account username when available. Throws `HuggingFaceError.tokenInvalid` for a rejected token. The
    /// token is never returned, logged, or persisted anywhere but the Keychain.
    @discardableResult
    func connectHuggingFace(token: String) async throws -> String? {
        try await hfSource().connect(token: token)
    }

    /// Remove the stored token from the Keychain (sign out). No-op when not connected.
    func disconnectHuggingFace() {
        hfSource().disconnect()
    }

    // MARK: - Reference parsing (HF1)

    /// Parse any accepted Hugging Face reference ("owner/repo", a huggingface.co URL, "owner/repo@rev") into
    /// a `ModelSource`. Returns nil when the string is not a resolvable repo id.
    nonisolated func parseHuggingFaceReference(_ raw: String) -> ModelSource? {
        HuggingFaceReference.parse(raw)
    }

    // MARK: - Access + resolve (HF2/HF5)

    /// Normalized access state for a repo (public / auth-required / gated-terms / private / not-found …).
    func huggingFaceAccess(_ source: ModelSource) async throws -> ModelAccessStatus {
        try await hfSource().accessStatus(source)
    }

    /// Resolve a repo to its metadata + access + license + compatibility. Throws a typed `HuggingFaceError`
    /// when the repo can't be read (auth/gated/denied/not-found).
    func resolveHuggingFace(_ source: ModelSource) async throws -> ModelSourceRecord {
        try await hfSource().resolve(source)
    }

    /// Convenience: parse a raw reference then resolve it. Throws `.invalidReference` on an unparseable string.
    func resolveHuggingFace(reference raw: String) async throws -> ModelSourceRecord {
        guard let source = HuggingFaceReference.parse(raw) else {
            throw HuggingFaceError.invalidReference(raw)
        }
        return try await resolveHuggingFace(source)
    }

    // MARK: - Candidates + recommendation (HF4)

    /// The installable artifacts (e.g. GGUF quants, or the single MLX layout) for a repo, each with its own
    /// Model Fit and exactly one flagged `isRecommended`.
    func huggingFaceArtifactCandidates(_ source: ModelSource) async throws -> [ModelArtifactCandidate] {
        try await hfSource().candidateArtifacts(source)
    }

    /// Re-apply esh's recommendation to a candidate list (e.g. after the host re-filters it). Pure — it reads
    /// only the candidates' own Model Fit, so it needs no account/HTTP state.
    nonisolated func recommendHuggingFaceArtifact(from candidates: [ModelArtifactCandidate]) -> [ModelArtifactCandidate] {
        HuggingFaceModelSource().applyRecommendation(candidates)
    }

    // MARK: - Search (HF5)

    /// Search Hugging Face for installable models. When connected, the account's private/gated repos are
    /// included. Results reuse the existing `ModelSearchResult` shape.
    func searchHuggingFace(query: String, limit: Int = 20) async throws -> [ModelSearchResult] {
        let creds = hfCredentials()
        let catalog = HuggingFaceModelCatalog(authorizationToken: { creds.loadToken() })
        return try await catalog.search(query: query, limit: limit)
    }

    // MARK: - Install (HF6)

    /// Begin installing one Hugging Face artifact and return a controllable session (rich `events` stream +
    /// pause/resume/cancel). Access is validated first (a gated/private-unauthorized repo throws before any
    /// download). The download honors the configured external storage root, carries the connected token, and
    /// records credential-free provenance (repo, revision/SHA, files, format, quantization, size, license,
    /// gated/private) on the resulting install.
    func installHuggingFaceSession(_ source: ModelSource,
                                   candidate: ModelArtifactCandidate? = nil,
                                   suggestedID: String? = nil) async throws -> ModelDownloadHandle {
        let record = try await resolveHuggingFace(source)
        try Self.ensureInstallable(record)
        let context = HFInstallProvenanceContext(
            licenseIdentifier: record.license.identifier,
            gated: record.gated,
            isPrivate: record.access == .privateAuthorized)
        let downloader = makeHFDownloader(context: context)
        let root = persistenceRootRef()
        let store = FileModelStore(root: root)
        let installID = suggestedID ?? HuggingFaceModelDownloader.installID(for: source.reference)
        let variant = candidate?.variant
        let expected = Self.expectedBytes(candidate: candidate, record: record)
        let handle = ModelDownloadHandle(
            id: installID, expectedBytes: expected,
            stateInstall: { onState in
                _ = try await downloader.install(source: source, suggestedID: installID,
                                                 variant: variant, progress: onState)
            },
            discardPartial: { try? store.removeInstall(id: installID) })
        await handle.start()
        return handle
    }

    /// One-shot install of a Hugging Face artifact (awaits completion). Returns the recorded `ModelInstall`
    /// with its HF provenance. For pause/resume/cancel, use `installHuggingFaceSession(_:)`.
    @discardableResult
    func installHuggingFaceArtifact(_ source: ModelSource,
                                    candidate: ModelArtifactCandidate? = nil,
                                    suggestedID: String? = nil,
                                    onProgress: (@Sendable (DownloadState) -> Void)? = nil) async throws -> ModelInstall {
        let record = try await resolveHuggingFace(source)
        try Self.ensureInstallable(record)
        let context = HFInstallProvenanceContext(
            licenseIdentifier: record.license.identifier,
            gated: record.gated,
            isPrivate: record.access == .privateAuthorized)
        let downloader = makeHFDownloader(context: context)
        let installID = suggestedID ?? HuggingFaceModelDownloader.installID(for: source.reference)
        let manifest = try await downloader.install(
            source: source, suggestedID: installID, variant: candidate?.variant,
            progress: { state in onProgress?(state) })
        return manifest.install
    }

    // MARK: - Internals

    private func hfCredentials() -> HFCredentialStore {
        hfCredentialStoreOverride ?? KeychainHFCredentialStore()
    }
    private func hfHTTP() -> HFHTTPClient {
        hfHTTPClientOverride ?? URLSessionHFHTTPClient()
    }
    private func hfSource() -> HuggingFaceModelSource {
        HuggingFaceModelSource(http: hfHTTP(), credentials: hfCredentials(),
                               deviceProfileProvider: deviceProfileProviderRef(),
                               root: persistenceRootRef())
    }
    private func makeHFDownloader(context: HFInstallProvenanceContext?) -> HuggingFaceModelDownloader {
        let root = persistenceRootRef()
        let store = FileModelStore(root: root)
        let creds = hfCredentials()
        let coordinator = DownloadCoordinator(authorizationToken: { creds.loadToken() })
        return HuggingFaceModelDownloader(
            modelStore: store, coordinator: coordinator, storageRoot: root,
            authorizationToken: { creds.loadToken() }, provenanceContext: context)
    }

    /// Fail fast on non-installable access states so no partial download is attempted.
    private static func ensureInstallable(_ record: ModelSourceRecord) throws {
        switch record.access {
        case .authenticationRequired: throw HuggingFaceError.authenticationRequired
        case .gatedTermsRequired(let url): throw HuggingFaceError.gatedTermsRequired(actionURL: url)
        case .accessRequestPending, .accessDenied, .privateUnauthorized: throw HuggingFaceError.accessDenied
        case .notFound: throw HuggingFaceError.repositoryNotFound
        case .publicAccess, .privateAuthorized: break
        }
    }

    private static func expectedBytes(candidate: ModelArtifactCandidate?, record: ModelSourceRecord) -> Int64 {
        if let s = candidate?.sizeBytes, s > 0 { return s }
        if let gb = record.metadata.estimatedWeightsGB, gb > 0 { return Int64(gb * 1_073_741_824) }
        return 0
    }
}
