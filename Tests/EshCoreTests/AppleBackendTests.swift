import Foundation
import Testing
@testable import EshCore

@Suite
struct AppleBackendTests {

    @Test
    func reservedAppleIDsMatchAndNormalIDsDoNot() {
        #expect(AppleProvider.isAppleModelID("apple"))
        #expect(AppleProvider.isAppleModelID("apple-intelligence"))
        #expect(AppleProvider.isAppleModelID("Apple-Foundation"))     // case-insensitive
        #expect(AppleProvider.isAppleModelID("mlx-community/qwen2.5-0.5b") == false)
        #expect(AppleProvider.isAppleModelID("llama-3-8b") == false)
        #expect(AppleProvider.isAppleModelID(nil) == false)
    }

    @Test
    func syntheticInstallIsAppleBackendWithNoFiles() {
        let install = AppleProvider.syntheticInstall()
        #expect(install.spec.backend == .apple)
        #expect(install.id == AppleProvider.canonicalModelID)
        #expect(install.installPath.isEmpty)      // no download, no files
        #expect(install.sizeBytes == 0)
    }

    @Test
    func registryRoutesAppleInstallToAppleBackend() {
        let backend = InferenceBackendRegistry().backend(for: AppleProvider.syntheticInstall())
        #expect(backend.kind == .apple)
    }

    @Test
    func appleBackendKindIsAppleAndCapabilityReportShapes() {
        let report = AppleBackend().capabilityReport(for: AppleProvider.syntheticInstall())
        #expect(report.backend == .apple)
        // Whether ready depends on the host, but direct inference is the advertised feature when ready.
        if report.ready { #expect(report.supportedFeatures.contains(.directInference)) }
    }

    @Test
    func appleStructuredOutputIsApproximatedAndStrictRejected() {
        let resolver = CapabilityResolver()
        let approx = resolver.resolve(responseFormat: .json, backend: .apple)
        #expect(approx.resolution.first(named: "response_format")?.resolution == .approximated)
        let strict = resolver.resolve(responseFormat: EshResponseFormat(kind: .jsonSchema, schema: "{}", strict: true), backend: .apple)
        #expect(strict.resolution.first(named: "response_format")?.resolution == .rejected)
    }

    @Test
    func appleReasoningIsIgnoredHonestly() {
        let outcome = CapabilityResolver().resolve(responseFormat: nil, backend: .apple, reasoningEnabled: true)
        #expect(outcome.resolution.first(named: "reasoning")?.resolution == .ignored)
    }

    // Real on-device Apple generation. Gated: only runs where Apple Intelligence is available AND
    // explicitly enabled, so CI/other hosts stay hermetic.
    @Test
    func realAppleGenerationProducesText() async throws {
        guard ProcessInfo.processInfo.environment["ESH_RUN_APPLE_TESTS"] == "1" else { return }
        guard AppleIntelligenceService().status().available else { return }
        let runtime = try await AppleBackend().loadRuntime(for: AppleProvider.syntheticInstall())
        let session = ChatSession(name: "apple", modelID: AppleProvider.canonicalModelID, backend: .apple,
                                  messages: [Message(role: .user, text: "Reply with exactly one word: pong")])
        var out = ""
        for try await chunk in runtime.generate(session: session, config: GenerationConfig(maxTokens: 16)) {
            out += chunk
        }
        #expect(out.isEmpty == false)
    }
}
