import Foundation

// The unified Hugging Face source facade (HF1–HF7). Composes the existing pure heuristics
// (`ModelFilenameHeuristics`), Model Fit (`ModelFitService`), the injectable HTTP seam, and the Keychain
// credential store into one coherent surface for Studio. One authed repo fetch drives resolve + access +
// candidates; downloads stay on the existing DownloadCoordinator (auth-threaded separately).
public struct HuggingFaceModelSource: Sendable {
    private let http: HFHTTPClient
    private let credentials: HFCredentialStore
    private let fit: ModelFitService
    private let deviceProfileProvider: DeviceProfileProviding
    private let root: PersistenceRoot
    private let apiBase = "https://huggingface.co"

    public init(http: HFHTTPClient = URLSessionHFHTTPClient(),
                credentials: HFCredentialStore = KeychainHFCredentialStore(),
                fit: ModelFitService = ModelFitService(),
                deviceProfileProvider: DeviceProfileProviding = SystemDeviceProfileProvider(),
                root: PersistenceRoot = .default()) {
        self.http = http; self.credentials = credentials; self.fit = fit
        self.deviceProfileProvider = deviceProfileProvider; self.root = root
    }

    // MARK: - Account (HF3)

    /// Account state. Validates a stored token against whoami; offline/unknown keeps the connected view
    /// (we don't downgrade to disconnected on a transient network error).
    public func accountState() async -> HFAccountState {
        guard let token = credentials.loadToken() else { return .disconnected }
        do {
            let resp = try await http.send(authed(request(path: "/api/whoami-v2"), token: token))
            switch resp.statusCode {
            case 200:
                let name = (try? JSONDecoder().decode(WhoAmI.self, from: resp.data))?.name
                return .connected(username: name)
            case 401, 403: return .tokenInvalid
            default: return .connected(username: nil)
            }
        } catch { return .connected(username: nil) }
    }

    /// Validate + store a token in the Keychain. Returns the username on success; throws `.tokenInvalid`
    /// for a rejected token. The token is never returned or logged.
    @discardableResult
    public func connect(token: String) async throws -> String? {
        let resp = try await http.send(authed(request(path: "/api/whoami-v2"), token: token))
        guard resp.statusCode == 200 else {
            if resp.statusCode == 401 || resp.statusCode == 403 { throw HuggingFaceError.tokenInvalid }
            throw HuggingFaceError.networkFailure("whoami HTTP \(resp.statusCode)")
        }
        try credentials.saveToken(token)
        return (try? JSONDecoder().decode(WhoAmI.self, from: resp.data))?.name
    }

    public func disconnect() { credentials.deleteToken() }

    // MARK: - Access (HF2)

    public func accessStatus(_ source: ModelSource) async throws -> ModelAccessStatus {
        let (status, info) = try await fetchRepo(source)
        return try await classifyAccess(source: source, status: status, info: info)
    }

    // MARK: - Resolve (HF2/HF5)

    public func resolve(_ source: ModelSource) async throws -> ModelSourceRecord {
        let (status, info) = try await fetchRepo(source)
        let access = try await classifyAccess(source: source, status: status, info: info)
        guard let info else {
            // Access-only outcomes (401/403/404) with no metadata: surface via a typed throw.
            switch access {
            case .authenticationRequired: throw HuggingFaceError.authenticationRequired
            case .gatedTermsRequired(let url): throw HuggingFaceError.gatedTermsRequired(actionURL: url)
            case .accessDenied, .privateUnauthorized: throw HuggingFaceError.accessDenied
            case .notFound: throw HuggingFaceError.repositoryNotFound
            default: throw HuggingFaceError.repositoryNotFound
            }
        }
        let metadata = self.metadata(source: source, info: info)
        let license = self.license(source: source, info: info)
        return ModelSourceRecord(source: source, metadata: metadata, access: access,
                                 compatibility: compatibility(for: metadata),
                                 license: license, gated: info.gatedValue != .no)
    }

    // MARK: - Candidates + recommendation (HF4)

    public func candidateArtifacts(_ source: ModelSource) async throws -> [ModelArtifactCandidate] {
        let (_, infoOpt) = try await fetchRepo(source)
        guard let info = infoOpt else { throw HuggingFaceError.repositoryNotFound }
        let filenames = info.siblings.map(\.rfilename)
        let sizes = Dictionary(info.siblings.map { ($0.rfilename, $0.size ?? 0) }, uniquingKeysWith: { a, _ in a })
        let format = ModelFilenameHeuristics.inferFormat(identifier: source.reference, filenames: filenames)
        let architecture = ModelFilenameHeuristics.inferArchitecture(
            identifier: source.reference, configModelType: nil, tags: info.tags, filenames: filenames)
        let paramB = ModelFilenameHeuristics.inferParameterCountB(identifier: source.reference, filenames: filenames)
        let host = HostMachineProfile(deviceProfile: deviceProfileProvider.currentProfile())

        var candidates: [ModelArtifactCandidate] = []
        switch format {
        case .gguf:
            let variants = ModelFilenameHeuristics.availableVariants(in: filenames, format: format)
            let list = variants.isEmpty ? [nil] : variants.map { Optional($0) }
            for variant in list {
                let sel = ModelFilenameHeuristics.selectGGUFFiles(filenames, variant: variant)
                guard let primary = sel.selected else { continue }
                // `sel.related` already includes the primary; dedupe so a single-file quant isn't counted twice.
                let uniqueFiles = Array(Set([primary] + sel.related))
                let companions = sel.related.filter { $0 != primary }
                let size = uniqueFiles.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
                let bits = ModelFilenameHeuristics.inferEffectiveBits(quantization: variant, format: format)
                let assessment = fit.assess(input: .init(
                    parameterCountB: paramB, effectiveBits: bits, format: format, backend: .gguf,
                    backendSupported: true, architectureSupported: architecture != .unknown,
                    contextTokens: 4096, diskRequiredBytes: size > 0 ? size : nil), host: host, root: root)
                candidates.append(ModelArtifactCandidate(
                    id: variant ?? primary, variant: variant, format: format, backend: .gguf,
                    primaryFile: primary, companionFiles: companions, sizeBytes: size > 0 ? size : nil,
                    fit: assessment))
            }
        case .mlx:
            let size = info.siblings.compactMap(\.size).reduce(0, +)
            let assessment = fit.assess(input: .init(
                parameterCountB: paramB, effectiveBits: ModelFilenameHeuristics.inferEffectiveBits(quantization: nil, format: format),
                format: format, backend: .mlx, backendSupported: true,
                architectureSupported: architecture != .unknown, contextTokens: 4096,
                diskRequiredBytes: size > 0 ? size : nil), host: host, root: root)
            candidates.append(ModelArtifactCandidate(
                id: source.reference, variant: nil, format: format, backend: .mlx,
                primaryFile: "config.json", companionFiles: filenames.filter { $0 != "config.json" },
                sizeBytes: size > 0 ? size : nil, fit: assessment))
        default:
            break   // unknown format → no runnable candidate
        }
        return applyRecommendation(candidates)
    }

    /// esh-owned recommendation: the largest artifact that still fits comfortably/fits; else the lightest
    /// non-unsupported one. Returns candidates with `isRecommended` set on exactly one (when any qualifies).
    public func applyRecommendation(_ candidates: [ModelArtifactCandidate]) -> [ModelArtifactCandidate] {
        guard !candidates.isEmpty else { return candidates }
        func rank(_ c: ModelArtifactCandidate) -> Int { c.sizeBytes.map { Int($0 / 1_000_000) } ?? 0 }
        let fitting = candidates.filter { ($0.fit?.fitClass == .comfortable) || ($0.fit?.fitClass == .fits) }
        let chosen: ModelArtifactCandidate?
        if let best = fitting.max(by: { rank($0) < rank($1) }) {
            chosen = best   // heaviest that still fits well = best quality within safe headroom
        } else {
            chosen = candidates.filter { $0.fit?.fitClass != .unsupported }.min(by: { rank($0) < rank($1) })
        }
        return candidates.map { var c = $0; c.isRecommended = (c.id == chosen?.id); return c }
    }

    // MARK: - Internals

    struct WhoAmI: Decodable { let name: String? }

    /// Decoded HF `api/models/{repo}` payload.
    struct RepoInfo {
        var id: String
        var sha: String?
        var isPrivate: Bool
        var gatedValue: Gated
        var tags: [String]
        var libraryName: String?
        var siblings: [Sibling]
        var license: String?
        struct Sibling { var rfilename: String; var size: Int64? }
        enum Gated: Equatable { case no, auto, manual }
    }

    private func request(path: String) -> URLRequest {
        URLRequest(url: URL(string: apiBase + path)!)
    }
    private func authed(_ request: URLRequest, token: String?) -> URLRequest {
        var r = request
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    /// One authed repo fetch. Returns (statusCode, decoded info?) — info is nil on non-200.
    private func fetchRepo(_ source: ModelSource) async throws -> (Int, RepoInfo?) {
        guard source.kind == .huggingFace else { throw HuggingFaceError.invalidReference(source.reference) }
        var path = "/api/models/\(source.reference)"
        if let rev = source.revision { path += "/revision/\(rev)" }
        // `blobs=true` makes siblings carry real per-file sizes (LFS weights under `lfs.size`), which the
        // candidate list, Model Fit, and recommendation all depend on.
        path += "?blobs=true"
        let resp = try await http.send(authed(request(path: path), token: credentials.loadToken()))
        guard resp.statusCode == 200 else { return (resp.statusCode, nil) }
        return (200, decodeRepo(resp.data))
    }

    private func classifyAccess(source: ModelSource, status: Int, info: RepoInfo?) async throws -> ModelAccessStatus {
        let hasToken = credentials.loadToken() != nil
        switch status {
        case 404: return .notFound
        case 401: return .authenticationRequired
        case 403:
            guard hasToken else { return .authenticationRequired }
            return .accessDenied   // token present but forbidden (gated-not-accepted or private-unauthorized)
        case 200:
            guard let info else { return .publicAccess }
            if info.isPrivate { return .privateAuthorized }   // we can see it → we have access
            if info.gatedValue != .no {
                // Metadata is public for gated repos; check actual file access.
                return await gatedFileAccess(source: source, info: info)
            }
            return .publicAccess
        default:
            return .notFound
        }
    }

    /// For a gated repo whose metadata is visible: probe a real file to see if this account may download it.
    private func gatedFileAccess(source: ModelSource, info: RepoInfo) async -> ModelAccessStatus {
        let url = HuggingFaceReference.modelCardURL(source)
        guard let file = info.siblings.first(where: { $0.rfilename.hasSuffix(".gguf") || $0.rfilename == "config.json" })?.rfilename
                ?? info.siblings.first?.rfilename else {
            return .gatedTermsRequired(actionURL: url)
        }
        let rev = source.revision ?? info.sha ?? "main"
        var req = URLRequest(url: URL(string: "\(apiBase)/\(source.reference)/resolve/\(rev)/\(file)")!)
        req.httpMethod = "HEAD"
        let authedReq = authed(req, token: credentials.loadToken())
        guard let resp = try? await http.send(authedReq) else { return .gatedTermsRequired(actionURL: url) }
        switch resp.statusCode {
        case 200, 206, 302: return .publicAccess              // terms accepted / access granted
        case 401: return .authenticationRequired
        default: return .gatedTermsRequired(actionURL: url)   // 403 etc: must accept/request on the web
        }
    }

    private func metadata(source: ModelSource, info: RepoInfo) -> ModelMetadata {
        let filenames = info.siblings.map(\.rfilename)
        let format = ModelFilenameHeuristics.inferFormat(identifier: source.reference, filenames: filenames)
        let architecture = ModelFilenameHeuristics.inferArchitecture(
            identifier: source.reference, configModelType: nil, tags: info.tags, filenames: filenames)
        let quant = ModelFilenameHeuristics.inferQuantization(identifier: source.reference, filenames: filenames, format: format)
        let variants = ModelFilenameHeuristics.availableVariants(in: filenames, format: format)
        let sel = ModelFilenameHeuristics.selectGGUFFiles(filenames, variant: nil)
        let adapter = ModelFilenameHeuristics.inferAdapter(
            identifier: source.reference, tags: info.tags, filenames: filenames, libraryName: info.libraryName)
        var m = ModelMetadata(sourceIdentifier: source.reference, displayName: source.reference,
                              format: format, architecture: architecture)
        m.parameterCountB = ModelFilenameHeuristics.inferParameterCountB(identifier: source.reference, filenames: filenames)
        m.quantization = quant
        m.availableVariants = variants
        m.effectiveBits = ModelFilenameHeuristics.inferEffectiveBits(quantization: quant, format: format)
        m.ggufFileCount = filenames.filter { $0.lowercased().hasSuffix(".gguf") }.count
        m.selectedGGUFFile = sel.selected
        m.isSplitGGUF = sel.isSplit
        m.isAdapter = adapter
        m.baseModelID = adapter ? ModelFilenameHeuristics.inferBaseModelID(tags: info.tags) : nil
        let totalGB = Double(info.siblings.compactMap(\.size).reduce(0, +)) / 1_073_741_824
        if totalGB > 0 { m.estimatedWeightsGB = (totalGB * 10).rounded() / 10 }
        m.backend = format == .gguf ? .gguf : (format == .mlx ? .mlx : nil)
        return m
    }

    private func license(source: ModelSource, info: RepoInfo) -> HFLicenseInfo {
        let card = HuggingFaceReference.modelCardURL(source)
        guard let id = info.license, !id.isEmpty else { return HFLicenseInfo(modelCardURL: card) }
        return HFLicenseInfo(identifier: id, name: id, modelCardURL: card)
    }

    /// Truthful source-compatibility verdict. "verified" is reserved for the curated catalog; a raw HF resolve
    /// is at most "compatible".
    public func compatibility(for m: ModelMetadata) -> SourceCompatibility {
        if m.format == .unknown { return .unknown(reason: "Could not determine the model format from this repository.") }
        if m.backend == nil { return .unsupported(reason: "No installed runtime supports this model's format.") }
        if m.isAdapter { return .experimental(reason: "This is a LoRA/adapter and needs a compatible base model.") }
        if m.architecture == .unknown {
            return .experimental(reason: "Recognized format but the architecture could not be verified.")
        }
        return .compatible
    }

    private func decodeRepo(_ data: Data) -> RepoInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let siblings = (obj["siblings"] as? [[String: Any]] ?? []).map { sib -> RepoInfo.Sibling in
            // LFS-tracked weights report their real size under `lfs.size`; small files use top-level `size`.
            let lfsSize = (sib["lfs"] as? [String: Any])?["size"] as? NSNumber
            let size = lfsSize ?? (sib["size"] as? NSNumber)
            return RepoInfo.Sibling(rfilename: sib["rfilename"] as? String ?? "", size: size?.int64Value)
        }.filter { !$0.rfilename.isEmpty }
        let gated: RepoInfo.Gated
        switch obj["gated"] {
        case let b as Bool: gated = b ? .manual : .no
        case let s as String: gated = (s == "auto") ? .auto : (s == "manual" ? .manual : .no)
        default: gated = .no
        }
        let license = (obj["cardData"] as? [String: Any])?["license"] as? String
            ?? (obj["license"] as? String)
        return RepoInfo(
            id: obj["id"] as? String ?? "",
            sha: obj["sha"] as? String,
            isPrivate: obj["private"] as? Bool ?? false,
            gatedValue: gated,
            tags: obj["tags"] as? [String] ?? [],
            libraryName: obj["library_name"] as? String,
            siblings: siblings,
            license: license)
    }
}
