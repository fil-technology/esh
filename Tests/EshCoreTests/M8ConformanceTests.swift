import Foundation
import Testing
@testable import EshCore

/// M8 Inference Contract v2 — cross-backend conformance. Asserts the contract's honesty invariants
/// hold uniformly across backends at the capability-resolution + serialization layer (no live model
/// needed). Real-inference conformance for MLX lives in `MLXPersistentWorkerTests` (gated).
@Suite
struct M8ConformanceTests {
    private let resolver = CapabilityResolver()

    // MARK: - Capability-resolution honesty matrix

    @Test
    func textIsAlwaysAppliedOnEveryBackend() {
        for backend in BackendKind.allCases {
            let outcome = resolver.resolve(responseFormat: .text, backend: backend)
            #expect(outcome.resolution.first(named: "response_format")?.resolution == .applied)
        }
    }

    @Test
    func strictStructuredOutputIsNativeOnGGUFAndRejectedElsewhere() {
        let schema = #"{"type":"object"}"#
        for backend in BackendKind.allCases {
            let outcome = resolver.resolve(
                responseFormat: EshResponseFormat(kind: .jsonSchema, schema: schema, strict: true),
                backend: backend)
            let res = outcome.resolution.first(named: "response_format")?.resolution
            if backend == .gguf {
                #expect(res == .applied)                 // native constrained decoding
                #expect(outcome.nativeJSONSchema == schema)
                #expect(outcome.resolution.hasRejections == false)
            } else {
                #expect(res == .rejected)                // honest: no native constraint, strict set
                #expect(outcome.systemInstructionAugmentation == nil)  // no silent prompt substitution
            }
        }
    }

    @Test
    func toolsAreRejectedHonestlyOnEveryBackend() {
        for backend in BackendKind.allCases {
            let outcome = resolver.resolve(
                responseFormat: nil, backend: backend,
                tools: [EshToolDefinition(name: "get_weather")])
            let opt = outcome.resolution.first(named: "tools")
            #expect(opt?.resolution == .rejected)
            #expect(opt?.detail?.isEmpty == false)
        }
    }

    @Test
    func unsupportedStructuredBehaviorIsNeverSilent() {
        // A non-strict json request on a non-native backend must be labeled approximated (not applied)
        // and carry a prompt augmentation — visibly, never pretending it was native.
        let outcome = resolver.resolve(responseFormat: .json, backend: .mlx)
        let opt = outcome.resolution.first(named: "response_format")
        #expect(opt?.resolution == .approximated)
        #expect(outcome.systemInstructionAugmentation != nil)
        #expect(opt?.detail?.contains("not guaranteed") == true)
    }

    // MARK: - Canonical serialization round-trips

    @Test
    func fullRequestRoundTripsWithAllContractFields() throws {
        let request = ExternalInferenceRequest(
            model: "m",
            messages: [
                ExternalInferenceMessage(role: .system, text: "be brief"),
                ExternalInferenceMessage(role: .user, text: "hello")
            ],
            generation: GenerationConfig(maxTokens: 64, temperature: 0.3, topP: 0.9, topK: 40,
                                         minP: 0.05, repetitionPenalty: 1.1, seed: 7, enableThinking: true),
            responseFormat: EshResponseFormat(kind: .jsonSchema, schema: "{}", strict: true),
            tools: [EshToolDefinition(name: "search", description: "web", parametersSchemaJSON: "{}")],
            toolChoice: .required,
            attachments: [EshAttachment(kind: .image, mimeType: "image/png", uri: "/tmp/a.png")]
        )
        let data = try JSONCoding.encoder.encode(request)
        let decoded = try JSONCoding.decoder.decode(ExternalInferenceRequest.self, from: data)
        #expect(decoded.responseFormat?.strict == true)
        #expect(decoded.tools?.first?.name == "search")
        #expect(decoded.toolChoice?.mode == .required)
        #expect(decoded.attachments?.first?.kind == .image)
        #expect(decoded.generation.topK == 40)
        #expect(decoded.generation.seed == 7)
        #expect(decoded.generation.enableThinking == true)
    }

    @Test
    func responseCarriesExecutionProfileUsageAndResolutionCoherently() throws {
        var profile = ExecutionProfile(backend: .mlx, model: "m", performanceMode: .auto, workload: .chat)
        profile.residency = RuntimeResidency.weightsResident.rawValue
        profile.cacheHit = true
        let response = ExternalInferenceResponse(
            modelID: "m", backend: .mlx,
            integration: ExternalInferenceIntegration(mode: "direct", cacheMode: .raw),
            outputText: "ok", metrics: Metrics(promptTokens: 10, generationTokens: 5, cacheHit: true),
            capabilityResolution: CapabilityResolution(options: [
                ResolvedOption(name: "response_format", resolution: .applied, detail: "text")
            ]),
            executionProfile: profile,
            usage: EshUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15)
        )
        let data = try JSONCoding.encoder.encode(response)
        let decoded = try JSONCoding.decoder.decode(ExternalInferenceResponse.self, from: data)
        #expect(decoded.executionProfile?.residency == "weights-resident")
        #expect(decoded.executionProfile?.cacheHit == true)
        #expect(decoded.usage?.totalTokens == 15)
        #expect(decoded.usage?.monetaryCostUSD == 0)
        #expect(decoded.capabilityResolution?.first(named: "response_format")?.resolution == .applied)
    }

    // MARK: - Apple provider in the capability contract

    @Test
    func appleProviderParticipatesWithOnDeviceOnlyGuarantees() throws {
        let root = PersistenceRoot(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("esh-apple-\(UUID().uuidString)", isDirectory: true))
        let response = try ExternalCapabilitiesService(modelStore: FileModelStore(root: root))
            .describe(toolVersion: "test")
        let apple = try #require(response.appleProvider)
        // Safety-critical invariants: on-device only, never cloud/PCC, never auto-substituted.
        #expect(apple.permitsCloudOrPCC == false)
        #expect(apple.neverAutoSelected == true)
        #expect(apple.limitations.isEmpty == false)   // limitations listed, not hidden
        if apple.available { #expect(apple.onDevice == true) }
    }

    @Test
    func capabilitiesResponseWithoutAppleProviderStillDecodes() throws {
        // Backward compatibility: a pre-Apple capabilities JSON (no appleProvider key).
        let json = Data(#"{"schemaVersion":"esh.capabilities.v1","tool":"esh","commands":[],"backends":[],"installedModels":[]}"#.utf8)
        let decoded = try JSONCoding.decoder.decode(ExternalCapabilitiesResponse.self, from: json)
        #expect(decoded.appleProvider == nil)
    }

    @Test
    func localUsageHasZeroMonetaryCostWithProvenance() {
        let usage = EshUsage(inputTokens: 3, outputTokens: 4, totalTokens: 7)
        #expect(usage.monetaryCostUSD == 0)
        #expect(usage.costProvenance.isEmpty == false)
        #expect(usage.available.contains("inputTokens"))
    }
}
