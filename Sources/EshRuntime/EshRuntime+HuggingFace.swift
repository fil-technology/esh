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

    /// The Hugging Face account state (`disconnected` / `connected(username:)` / `tokenInvalid` / `expired`).
    /// Validates the stored credential against `whoami`; a transient network error keeps the connected view.
    /// An expired OAuth credential is refreshed when possible, else reported as `.expired`.
    func huggingFaceAccountState() async -> HFAccountState {
        await hfSource().accountState()
    }

    /// **Advanced fallback.** Validate a manually created personal access token against `whoami` and, on
    /// success, store it in the Keychain as a PAT credential. Returns the username when available. Throws
    /// `HuggingFaceError.tokenInvalid` for a rejected token. OAuth (`beginHuggingFaceOAuth`) is the primary UX.
    /// The token is never returned, logged, or persisted anywhere but the Keychain.
    @discardableResult
    func connectHuggingFace(token: String) async throws -> String? {
        try await hfSource().connect(token: token)
    }

    /// Remove the stored credential (PAT or OAuth) from the Keychain and drop any pending OAuth sessions
    /// (sign out). Local deletion always succeeds; it does not depend on any remote revocation call.
    func disconnectHuggingFace() {
        hfSource().disconnect()
        clearAllPendingOAuth()
    }

    // MARK: - OAuth sign-in (rc.24 — primary UX; esh owns the protocol, the app owns the browser)

    /// Begin an Authorization Code + PKCE sign-in for a **public** OAuth client (no secret). esh generates the
    /// PKCE verifier + `state`, holds them in a transient in-memory session, and returns the authorization URL
    /// for the consumer app to open in a browser (e.g. `ASWebAuthenticationSession`). The consumer never sees
    /// the PKCE verifier or state. Throws `oauthConfigurationInvalid` for an empty client ID / scopes.
    func beginHuggingFaceOAuth(configuration: HFOAuthConfiguration) async throws -> HFAuthorizationRequest {
        guard !configuration.clientID.trimmingCharacters(in: .whitespaces).isEmpty,
              !configuration.scopes.isEmpty else {
            throw HuggingFaceError.oauthConfigurationInvalid
        }
        let pkce = HFOAuthPKCE.generate()
        let state = HFOAuthRandom.urlSafeToken(byteCount: 32)
        let session = HFPendingOAuthSession(id: UUID().uuidString, state: state,
                                            verifier: pkce.verifier, configuration: configuration)
        storePendingOAuth(session)
        let url = HFOAuthURLBuilder.authorizationURL(configuration: configuration, state: state, challenge: pkce.challenge)
        return HFAuthorizationRequest(id: session.id, authorizationURL: url)
    }

    /// Complete sign-in: the consumer passes the browser callback URL plus the `id` from `beginHuggingFaceOAuth`.
    /// esh validates the session + `state`, extracts the code, performs the public-client token exchange, stores
    /// the OAuth credential in the Keychain (atomically replacing any prior credential), and returns the account
    /// state. A failed exchange leaves any previously working credential intact. Typed `HuggingFaceError` on
    /// denial/mismatch/expiry/exchange failure.
    @discardableResult
    func completeHuggingFaceOAuth(callbackURL: URL, requestID: String) async throws -> HFAccountState {
        guard let session = takePendingOAuth(requestID) else { throw HuggingFaceError.oauthSessionNotFound }
        guard !session.isExpired() else { throw HuggingFaceError.oauthSessionExpired }
        let callback = try HFOAuthCallback.parse(callbackURL, redirectURI: session.configuration.redirectURI)
        if let error = callback.error {
            throw error == "access_denied" ? HuggingFaceError.oauthAccessDenied : HuggingFaceError.oauthTokenExchangeFailed
        }
        guard callback.state == session.state else { throw HuggingFaceError.oauthStateMismatch }
        guard let code = callback.code, !code.isEmpty else { throw HuggingFaceError.oauthCallbackInvalid }
        return try await hfSource().completeOAuth(code: code, session: session)
    }

    /// Cancel a pending sign-in (e.g. the user dismissed the browser). Idempotent.
    func cancelHuggingFaceOAuth(requestID: String) {
        removePendingOAuth(requestID)
    }

    /// Proactively refresh an expired OAuth credential if a refresh token is available; returns the resulting
    /// account state (`.expired` when it cannot be refreshed). Safe to call at launch.
    @discardableResult
    func refreshHuggingFaceOAuthIfNeeded() async -> HFAccountState {
        _ = try? await hfSource().ensureFreshCredential()
        return await hfSource().accountState()
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
        let src = hfSource()
        _ = try? await src.ensureFreshCredential()   // best-effort refresh; public reads still work when signed out
        return try await src.resolve(source)
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
        let src = hfSource()
        _ = try? await src.ensureFreshCredential()
        return try await src.candidateArtifacts(source)
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
        _ = try? await hfSource().ensureFreshCredential()
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
        try await hfSource().ensureFreshCredential()   // enforce a usable credential before downloading
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
        try await hfSource().ensureFreshCredential()   // enforce a usable credential before downloading
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
