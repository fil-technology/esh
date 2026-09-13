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

    // M2: the iOS platform assembly wires Apple Foundation Models ONLY. Prove that (a) explicit Apple
    // and Auto (Apple is the sole backend) resolve to AppleBackend, and (b) a pinned non-Apple model
    // format is never silently substituted with Apple — it resolves to nil so the caller fails honestly.
    @Test
    func iOSAppleOnlyAssemblyResolvesAppleAndNeverSubstitutesForPinnedNonApple() {
        let registry = InferenceBackendRegistry(backends: [.apple: AppleBackend()])
        // Explicit Apple provider / Auto with Apple as the only candidate → AppleBackend.
        #expect(registry.resolve(.apple)?.kind == .apple)
        #expect(registry.backend(for: AppleProvider.syntheticInstall()).kind == .apple)
        // A pinned downloaded-model format is NOT available on an Apple-only device and is NOT
        // substituted with Apple. `.onnx` normally falls back to `.mlx`; absent here it is nil too.
        #expect(registry.resolve(.mlx) == nil)
        #expect(registry.resolve(.gguf) == nil)
        #expect(registry.resolve(.onnx) == nil)
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

    // M2 physical-device measurement harness. Runs the FULL esh path
    //   InferenceBackendRegistry → AppleBackend → AppleBackendRuntime → AppleIntelligenceService → FoundationModels
    // and prints measured results (prefixed `ESH-M2` for log capture). Gated by ESH_RUN_APPLE_TESTS=1;
    // on a device without Apple Intelligence it records the honest typed status and returns.
    @Test
    func appleDeviceInferenceMeasured() async throws {
        guard ProcessInfo.processInfo.environment["ESH_RUN_APPLE_TESTS"] == "1" else { return }
        let status = AppleIntelligenceService().status()
        print("ESH-M2 availability=\(status.availability.rawValue) available=\(status.available) onDevice=\(status.onDevice) detail=\(status.detail)")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("ESH-M2 os=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        guard status.available else {
            print("ESH-M2 RESULT=SKIP reason=apple-fm-unavailable")
            return
        }
        // Exercise the esh registry assembly (Apple-only is valid on iOS; default init on macOS).
        let registry = InferenceBackendRegistry(backends: [.apple: AppleBackend()])
        let install = AppleProvider.syntheticInstall()
        let backend = registry.backend(for: install)
        #expect(backend.kind == .apple)
        let runtime = try await backend.loadRuntime(for: install)
        func run() async throws -> (String, Int, Duration) {
            let session = ChatSession(name: "m2", modelID: AppleProvider.canonicalModelID, backend: .apple,
                                      messages: [Message(role: .user, text: "Reply with exactly one word: pong")])
            var text = ""; var chunks = 0
            let start = ContinuousClock.now
            for try await c in runtime.generate(session: session, config: GenerationConfig(maxTokens: 16)) { text += c; chunks += 1 }
            return (text, chunks, start.duration(to: .now))
        }
        let (t1, c1, d1) = try await run()
        print("ESH-M2 firstCall ms=\(d1) chunks=\(c1) backend=\(runtime.backend.rawValue) model=\(runtime.modelID) text=\(t1.prefix(80))")
        #expect(!t1.isEmpty)
        let (_, c2, d2) = try await run()
        print("ESH-M2 secondCall ms=\(d2) chunks=\(c2)")
        let m = await runtime.metrics
        print("ESH-M2 metrics ttftMs=\(String(describing: m.ttftMilliseconds)) finish=\(String(describing: m.finishReason)) streamed=\(c1 <= 1 ? "single-chunk" : "streamed")")
        print("ESH-M2 RESULT=PASS")
    }
}
