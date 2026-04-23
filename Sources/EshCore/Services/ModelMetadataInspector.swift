import Foundation

public struct ModelMetadataInspector: Sendable {
    private struct RepoInfo: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }

        let id: String
        let pipelineTag: String?
        let tags: [String]?
        let siblings: [Sibling]?
    }

    private let session: URLSession
    private let retryPolicy: NetworkRetryPolicy

    public init(
        session: URLSession = .shared,
        retryPolicy: NetworkRetryPolicy = .default
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
    }

    public func inspect(
        repoID: String,
        backendPreference: ModelCheckBackendPreference,
        offline: Bool,
        variant: String? = nil
    ) async throws -> ModelMetadata {
        if offline {
            return inferMetadata(
                repoID: repoID,
                filenames: [],
                tags: [],
                configModelType: nil,
                backendPreference: backendPreference,
                variant: variant,
                notes: [],
                warnings: ["Offline mode uses filename heuristics only."]
            )
        }

        let info = try await fetchRepoInfo(repoID: repoID)
        let filenames = (info.siblings ?? []).map(\.rfilename)
        let tags = normalizedTags(tags: info.tags ?? [], pipelineTag: info.pipelineTag)
        let configModelType = try await fetchConfigModelType(repoID: repoID)
        let totalSizeBytes = (info.siblings ?? []).compactMap(\.size).reduce(0, +)

        var metadata = inferMetadata(
            repoID: repoID,
            filenames: filenames,
            tags: tags,
            configModelType: configModelType,
            backendPreference: backendPreference,
            variant: variant,
            notes: totalSizeBytes > 0 ? ["Estimated from Hugging Face metadata before download."] : [],
            warnings: []
        )

        if totalSizeBytes > 0 {
            metadata.estimatedWeightsGB = round1(Double(totalSizeBytes) / 1_073_741_824)
        }
        return metadata
    }

    private func inferMetadata(
        repoID: String,
        filenames: [String],
        tags: [String],
        configModelType: String?,
        backendPreference: ModelCheckBackendPreference,
        variant: String?,
        notes: [String],
        warnings: [String]
    ) -> ModelMetadata {
        let format = ModelFilenameHeuristics.inferFormat(identifier: repoID, filenames: filenames)
        let architecture = ModelFilenameHeuristics.inferArchitecture(
            identifier: repoID,
            configModelType: configModelType,
            tags: tags,
            filenames: filenames
        )
        let parameterCountB = ModelFilenameHeuristics.inferParameterCountB(identifier: repoID, filenames: filenames)
        let quantization = ModelFilenameHeuristics.inferQuantization(identifier: repoID, filenames: filenames, format: format)
        let availableVariants = ModelFilenameHeuristics.availableVariants(in: filenames, format: format)
        let effectiveBits = ModelFilenameHeuristics.inferEffectiveBits(quantization: quantization, format: format)
        let multimodal = ModelFilenameHeuristics.inferMultimodal(identifier: repoID, tags: tags, configModelType: configModelType)
        let ggufSelection = ModelFilenameHeuristics.selectGGUFFiles(filenames, variant: variant)
        var metadataWarnings = warnings
        if let ggufWarning = ggufSelection.warning {
            metadataWarnings.append(ggufWarning)
        }

        let inferredBackend = backendPreference.resolvedBackend ?? {
            switch format {
            case .mlx: return .mlx
            case .gguf: return .gguf
            case .unknown: return nil
            }
        }()

        return ModelMetadata(
            sourceIdentifier: repoID,
            displayName: repoID,
            backend: inferredBackend,
            format: format,
            architecture: architecture,
            parameterCountB: parameterCountB,
            quantization: quantization,
            availableVariants: availableVariants,
            selectedVariant: variant?.isEmpty == false ? variant?.uppercased() : quantization,
            effectiveBits: effectiveBits,
            ggufFileCount: filenames.filter { $0.lowercased().hasSuffix(".gguf") }.count,
            selectedGGUFFile: ggufSelection.selected,
            isSplitGGUF: ggufSelection.isSplit,
            isMultimodal: multimodal,
            notes: notes,
            warnings: metadataWarnings
        )
    }

    private func fetchRepoInfo(repoID: String) async throws -> RepoInfo {
        let encoded = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoID
        guard let url = URL(string: "https://huggingface.co/api/models/\(encoded)") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await NetworkRequestExecutor.data(
            session: session,
            request: URLRequest(url: url),
            retryPolicy: retryPolicy
        )
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StoreError.invalidManifest("Failed to fetch model metadata: HTTP \(http.statusCode).")
        }
        return try JSONCoding.decoder.decode(RepoInfo.self, from: data)
    }

    private func fetchConfigModelType(repoID: String) async throws -> String? {
        var url = URL(string: "https://huggingface.co")!
        for component in repoID.split(separator: "/").map(String.init) {
            url.append(path: component)
        }
        url.append(path: "raw")
        url.append(path: "main")
        url.append(path: "config.json")

        let (data, response) = try await NetworkRequestExecutor.data(
            session: session,
            request: URLRequest(url: url),
            retryPolicy: retryPolicy
        )
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                break
            case 404:
                return nil
            default:
                throw StoreError.invalidManifest("Failed to fetch config.json: HTTP \(http.statusCode).")
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = object["model_type"] as? String {
            return value
        }
        if let architectures = object["architectures"] as? [String], let first = architectures.first {
            return first
        }
        return nil
    }

    private func normalizedTags(tags: [String], pipelineTag: String?) -> [String] {
        var values = tags
        if let pipelineTag, values.contains(pipelineTag) == false {
            values.insert(pipelineTag, at: 0)
        }
        return values
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
