import Foundation
import Testing
import EshCore

// Native (in-process) engines must win a capability over the Python compat bridge, because only native
// paths run under the macOS App Sandbox. Precedence is a registry guarantee, independent of registration
// order — a consumer wires both EshImageGen (native) and the compat provider and the native one is selected.
private struct StubProvider: CapabilityProvider {
    let descriptor: CapabilityProviderDescriptor
    init(id: String, backend: RuntimeKind, capability: CapabilityID = .imageGenerate) {
        descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [capability], acceptedInputs: [.text], producedOutputs: [.image], backend: backend)
    }
    func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite struct CapabilityRegistryPrecedenceTests {
    private func resolved(_ order: [any CapabilityProvider]) -> [any CapabilityProvider] {
        var reg = CapabilityRegistry()
        for p in order { reg.register(p) }
        return reg.providers(for: .imageGenerate, inputs: [.text], output: .image)
    }

    @Test func nativeWinsOverCompatRegardlessOfRegistrationOrder() {
        let native = StubProvider(id: "native", backend: .mlx)
        let compat = StubProvider(id: "compat", backend: .python)
        // Compat registered FIRST — the native provider must still be the selected candidate (`.first`).
        #expect(resolved([compat, native]).first?.descriptor.id == "native")
        // Native registered first — still native.
        #expect(resolved([native, compat]).first?.descriptor.id == "native")
        // Both present: native precedes compat; compat is retained as a fallback, just never first.
        #expect(resolved([compat, native]).map(\.descriptor.id) == ["native", "compat"])
    }

    @Test func loneCompatProviderStillResolves() {
        // Native-first ordering must not drop a lone compat provider where no native engine exists yet.
        let compat = StubProvider(id: "compat", backend: .python)
        #expect(resolved([compat]).first?.descriptor.id == "compat")
    }

    @Test func inProcessDiscriminator() {
        #expect(RuntimeKind.python.isInProcess == false)
        for k: RuntimeKind in [.mlx, .apple, .appleVision, .coreml, .native, .gguf] { #expect(k.isInProcess) }
    }
}
