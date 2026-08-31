import Foundation
import Testing
@testable import EshCore

@Suite
struct CapabilityResolverTests {
    private let resolver = CapabilityResolver()

    @Test
    func textIsAppliedWithNoAugmentation() {
        let outcome = resolver.resolve(responseFormat: .text, backend: .mlx)
        #expect(outcome.resolution.first(named: "response_format")?.resolution == .applied)
        #expect(outcome.systemInstructionAugmentation == nil)
    }

    @Test
    func jsonIsApproximatedViaInstruction() {
        let outcome = resolver.resolve(responseFormat: .json, backend: .mlx)
        let opt = outcome.resolution.first(named: "response_format")
        #expect(opt?.resolution == .approximated)     // honest: not native constrained decoding
        #expect(outcome.systemInstructionAugmentation != nil)
        #expect(outcome.systemInstructionAugmentation?.contains("JSON") == true)
    }

    @Test
    func strictJSONIsRejectedNotApproximated() {
        let outcome = resolver.resolve(responseFormat: EshResponseFormat(kind: .json, strict: true), backend: .mlx)
        #expect(outcome.resolution.first(named: "response_format")?.resolution == .rejected)
        #expect(outcome.systemInstructionAugmentation == nil)   // no silent approximation under strict
    }

    @Test
    func jsonSchemaIsApproximatedAndCarriesSchema() {
        let schema = #"{"type":"object","properties":{"name":{"type":"string"}}}"#
        let outcome = resolver.resolve(responseFormat: EshResponseFormat(kind: .jsonSchema, schema: schema), backend: .mlx)
        #expect(outcome.resolution.first(named: "response_format")?.resolution == .approximated)
        #expect(outcome.systemInstructionAugmentation?.contains(schema) == true)
    }

    @Test
    func strictJSONSchemaIsRejected() {
        let schema = #"{"type":"object"}"#
        let outcome = resolver.resolve(responseFormat: EshResponseFormat(kind: .jsonSchema, schema: schema, strict: true), backend: .mlx)
        #expect(outcome.resolution.first(named: "response_format")?.resolution == .rejected)
    }

    @Test
    func grammarIsRejectedNotSilentlyIgnored() {
        let outcome = resolver.resolve(responseFormat: EshResponseFormat(kind: .grammar, grammar: "root ::= \"x\""), backend: .mlx)
        let opt = outcome.resolution.first(named: "response_format")
        #expect(opt?.resolution == .rejected)         // no silent pretending
        #expect(opt?.detail?.isEmpty == false)
        #expect(outcome.systemInstructionAugmentation == nil)
    }

    @Test
    func noResponseFormatYieldsEmptyResolution() {
        let outcome = resolver.resolve(responseFormat: nil, backend: .mlx)
        #expect(outcome.resolution.isEmpty)
    }

    @Test
    func requestAndResponseRoundTripWithNewFields() throws {
        let request = ExternalInferenceRequest(
            model: "m",
            messages: [ExternalInferenceMessage(role: .user, text: "hi")],
            responseFormat: EshResponseFormat(kind: .jsonSchema, schema: "{}")
        )
        let reqData = try JSONCoding.encoder.encode(request)
        let decodedReq = try JSONCoding.decoder.decode(ExternalInferenceRequest.self, from: reqData)
        #expect(decodedReq.responseFormat?.kind == .jsonSchema)

        let response = ExternalInferenceResponse(
            modelID: "m", backend: .mlx,
            integration: ExternalInferenceIntegration(mode: "direct", cacheMode: .raw),
            outputText: "{}", metrics: Metrics(),
            capabilityResolution: CapabilityResolution(options: [ResolvedOption(name: "response_format", resolution: .transformed)])
        )
        let respData = try JSONCoding.encoder.encode(response)
        let decodedResp = try JSONCoding.decoder.decode(ExternalInferenceResponse.self, from: respData)
        #expect(decodedResp.capabilityResolution?.first(named: "response_format")?.resolution == .transformed)
    }

    @Test
    func legacyRequestWithoutResponseFormatStillDecodes() throws {
        // Backward compatibility: an infer request JSON from before M8 (no responseFormat key).
        let json = Data(#"{"schemaVersion":"esh.infer.request.v1","messages":[{"role":"user","text":"hi"}],"generation":{"maxTokens":128,"temperature":0.7}}"#.utf8)
        let decoded = try JSONCoding.decoder.decode(ExternalInferenceRequest.self, from: json)
        #expect(decoded.responseFormat == nil)
        #expect(decoded.messages.count == 1)
    }
}
