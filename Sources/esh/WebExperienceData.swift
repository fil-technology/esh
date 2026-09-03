import Foundation
import EshCore

/// Provider for the 2.0 Web Experience data endpoints. Each path composes JSON from the CANONICAL
/// esh services — the browser and web layer contain no routing/fit/scheduler/policy logic (thin
/// client). Returned `Data` is JSON encoded once here and passed through the HTTP handler verbatim.
enum WebExperienceData {
    static func provider(root: PersistenceRoot, toolVersion: String?) -> (@Sendable (WebDataRequest) async throws -> Data) {
        let installs = InstallManager(root: root)
        return { request in
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            switch (request.method, request.path) {
            case ("POST", "/v1/models/install"):
                let body = (try? JSONDecoder().decode(InstallStart.self, from: request.body)) ?? InstallStart()
                let repoID = resolveRepoID(id: body.id, repoID: body.repoID)
                guard let repoID else { throw OpenAICompatibleError.invalidRequest("Provide a model id or repoID to install.") }
                await installs.start(repoID: repoID, variant: body.variant)
                return try enc.encode(["repoID": repoID, "status": "started"])
            case ("GET", "/v1/models/install"):
                let repoID = resolveRepoID(id: request.query["id"], repoID: request.query["repo"] ?? request.query["repoID"]) ?? (request.query["repo"] ?? "")
                guard let status = await installs.status(repoID: repoID) else {
                    return try enc.encode(["repoID": repoID, "phase": "idle"])
                }
                return try enc.encode(status)
            case ("POST", "/v1/models/install/cancel"):
                let body = (try? JSONDecoder().decode(InstallStart.self, from: request.body)) ?? InstallStart()
                if let repoID = resolveRepoID(id: body.id, repoID: body.repoID) { await installs.cancel(repoID: repoID) }
                return try enc.encode(["status": "cancelled"])
            case ("GET", "/v1/doctor"), ("GET", "/v1/engine"), ("GET", "/v1/onboarding"):
                // DoctorReport already composes host, storage, engines, models, and Apple state —
                // the canonical truth for onboarding and the engine inspector.
                let report = DoctorService().report(root: root, version: toolVersion)
                return try enc.encode(report)

            case ("GET", "/v1/schedule"):
                // The real Adaptive Scheduler decision + rationale ("Why this model?"). No policy in JS.
                let q = request.query
                let capRequest = CapabilityRequest(
                    goal: q["goal"].flatMap(CapabilityRequest.Goal.init(cliValue:)) ?? .general,
                    quality: q["quality"].flatMap(CapabilityRequest.Quality.init(cliValue:)) ?? .balanced,
                    latency: q["latency"].flatMap(CapabilityRequest.Latency.init(cliValue:)) ?? .interactive,
                    expectedContextTokens: q["context"].flatMap(Int.init),
                    toolCallingRequired: q["tools"] == "1" || q["tools"] == "true",
                    visionRequired: q["vision"] == "1" || q["vision"] == "true",
                    localOnly: q["allow_cloud"] != "1"
                )
                let host = HostMachineProfileService().currentProfile()
                let decision = SchedulerService().decide(request: capRequest, root: root, host: host)
                return try enc.encode(decision)

            case ("GET", "/v1/config"):
                let config = (try? EshConfigStore().load()) ?? EshConfig()
                return try enc.encode(config)

            case ("POST", "/v1/config"):
                // Merge a partial config patch (only the keys the UI sends) and persist canonically.
                let store = EshConfigStore()
                var config = (try? store.load()) ?? EshConfig()
                if let patch = try? JSONDecoder().decode(WebConfigPatch.self, from: request.body) {
                    if let v = patch.ttsModel { config.defaults.ttsModel = v.isEmpty ? nil : v }
                    if let v = patch.sttModel { config.defaults.sttModel = v.isEmpty ? nil : v }
                    if let v = patch.performanceMode { config.defaults.performanceMode = v }
                    // Per-capability model pins: empty/"auto" removes the pin (= Auto), else set it.
                    if let caps = patch.capabilityModels {
                        for (cap, model) in caps {
                            if model.isEmpty || model == "auto" { config.defaults.capabilityModels[cap] = nil }
                            else { config.defaults.capabilityModels[cap] = model }
                        }
                    }
                }
                try store.save(config)
                return try enc.encode(config)

            case ("GET", "/v1/capability-models"):
                return try enc.encode(capabilityModels(root: root))

            case ("GET", "/v1/catalog"):
                return try enc.encode(catalog(root: root, filter: request.query["filter"]))

            case ("GET", let p) where p.hasPrefix("/v1/catalog/"):
                let id = String(p.dropFirst("/v1/catalog/".count))
                guard let model = catalog(root: root, filter: nil).models.first(where: { $0.id == id }) else {
                    throw OpenAICompatibleError.notFound("No catalog model \(id)")
                }
                return try enc.encode(model)

            default:
                throw OpenAICompatibleError.notFound("No web-data route for \(request.method) \(request.path)")
            }
        }
    }

    /// Resolve a catalog alias (or a raw HF repo id) to the concrete repo id the downloader needs.
    private static func resolveRepoID(id: String?, repoID: String?) -> String? {
        if let repoID, !repoID.isEmpty { return repoID }
        guard let id, !id.isEmpty else { return nil }
        if let model = RecommendedModelRegistry().resolve(alias: id) { return model.repoID }
        return id.contains("/") ? id : nil
    }

    // MARK: - Catalog composition

    private static func catalog(root: PersistenceRoot, filter: String?) -> WebCatalog {
        let registry = RecommendedModelRegistry()
        let host = HostMachineProfileService().currentProfile()
        let fitService = ModelFitService()
        let benchmarks = ModelBenchmarkLabStore(root: root).load()
        let installed = ((try? FileModelStore(root: root).listInstalls()) ?? [])
        let installedRepoIDs = Set(installed.map { $0.id.lowercased() })

        // `list()` is the full curated catalog (incompatible models are shown, honestly flagged).
        var entries = registry.list()
        if let tag = filter, tag.lowercased() != "recommended", tag.lowercased() != "installed" {
            entries = registry.list(tag: tag)
        }

        let models: [WebCatalogModel] = entries.map { m in
            let fit = fitService.assess(recommendedModel: m, contextTokens: m.contextWindow, host: host, root: root)
            let normalizedID = m.repoID.replacingOccurrences(of: "/", with: "--").lowercased()
            let isInstalled = installedRepoIDs.contains(normalizedID) || installedRepoIDs.contains(m.repoID.lowercased())
            // Measured evidence only when a real local benchmark exists — never fabricated.
            let evidence = benchmarks.evidence(for: normalizedID) ?? benchmarks.evidence(for: m.repoID)
            let measuredTps = evidence?.performance.decodeTokensPerSecondMedian
            return WebCatalogModel(
                id: m.id, name: m.title, repoID: m.repoID,
                summary: m.summary, badge: m.tags.contains("default") ? "Recommended for this Mac" : "",
                capabilities: m.capabilities.map { $0.rawValue },
                backend: m.backend.rawValue, status: m.status.rawValue,
                parameterSize: m.parameterSize, quantization: m.quantization,
                contextWindow: m.contextWindow,
                fitClass: fit.fitClass.rawValue,
                estimatedMemoryGB: m.estimatedMemoryGB,
                downloadGB: m.totalDiskSizeGB,
                recommendedContext: fit.recommendedContext,
                installed: isInstalled,
                measured: measuredTps != nil,
                tokensPerSecond: measuredTps
            )
        }
        var filtered = models
        if filter?.lowercased() == "installed" { filtered = models.filter { $0.installed } }
        return WebCatalog(models: filtered, measuredNote: "● measured on this Mac · others are estimates")
    }
}

/// A model row for the Web Experience model browser and picker.
struct WebCatalogModel: Encodable {
    var id: String
    var name: String
    var repoID: String
    var summary: String
    var badge: String
    var capabilities: [String]
    var backend: String
    var status: String
    var parameterSize: String
    var quantization: String
    var contextWindow: Int?
    var fitClass: String
    var estimatedMemoryGB: Double
    var downloadGB: Double
    var recommendedContext: Int?
    var installed: Bool
    var measured: Bool
    var tokensPerSecond: Double?
}

struct WebCatalog: Encodable {
    var models: [WebCatalogModel]
    var measuredNote: String
}

/// Body for POST /v1/models/install and /cancel — a catalog id or a raw HF repo id.
private struct InstallStart: Decodable {
    var id: String?
    var repoID: String?
    var variant: String?
}

/// Partial settings patch the UI can POST to `/v1/config` — only these canonical keys are accepted.
private struct WebConfigPatch: Decodable {
    var ttsModel: String?
    var sttModel: String?
    var performanceMode: String?
    /// capability rawValue → installed model id (or "auto"/"" to clear).
    var capabilityModels: [String: String]?
}

// MARK: - Per-capability model selection (Settings → Models → Task models)

private struct CapModelOption: Encodable { var id: String; var name: String }
private struct CapModelArea: Encodable {
    var key: String        // capability rawValue, or "" for a fixed row
    var label: String
    var current: String    // selected model id, or "auto"
    var options: [CapModelOption]
    var fixed: Bool        // true = single built-in backend, not user-selectable
    var note: String?
}
private struct CapModelsResponse: Encodable {
    var selectable: [CapModelArea]
    var fixed: [CapModelArea]
}

extension WebExperienceData {
    /// Which model performs each capability. Selectable areas are driven by the REAL installed models'
    /// declared capabilities (never a fabricated list); fixed areas name the single built-in backend so the
    /// user understands why there's no choice yet. STT/TTS stay under Voice.
    fileprivate static func capabilityModels(root: PersistenceRoot) -> CapModelsResponse {
        let installs = ((try? FileModelStore(root: root).listInstalls()) ?? [])
        let pins = ((try? EshConfigStore(root: root).load())?.defaults.capabilityModels) ?? [:]
        func nameFor(_ id: String) -> String {
            installs.first(where: { $0.id == id }).map { $0.spec.displayName.isEmpty ? $0.id : $0.spec.displayName } ?? id
        }
        func area(_ key: String, _ label: String, _ filter: ModelCapabilityFilter, note: String?) -> CapModelArea {
            var opts = [CapModelOption(id: "auto", name: "Auto")]
            for m in installs where m.spec.capabilities.supports(capability: filter) {
                opts.append(CapModelOption(id: m.id, name: nameFor(m.id)))
            }
            let cur = pins[key].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
            return CapModelArea(key: key, label: label, current: cur, options: opts, fixed: false, note: note)
        }
        let selectable = [
            area("language.generate", "Chat & reasoning", .chat, note: nil),
            area("vector.generate", "Vector & SVG (JSON scenes)", .chat,
                 note: "Auto prefers the most JSON-reliable on-device model (Apple Intelligence when available)."),
            area("image.understand", "Vision — images & video", .imageUnderstanding,
                 note: "Also used to describe video frames."),
        ]
        func fixedRow(_ label: String, _ model: String) -> CapModelArea {
            CapModelArea(key: "", label: label, current: model, options: [], fixed: true, note: nil)
        }
        let fixed = [
            fixedRow("Image generation", "Z-Image Turbo (mflux)"),
            fixedRow("Image upscaling", "Real-ESRGAN (ONNX)"),
            fixedRow("Speaker diarization", "sherpa-onnx"),
            fixedRow("Text in images (OCR)", "Apple Vision"),
        ]
        return CapModelsResponse(selectable: selectable, fixed: fixed)
    }
}
