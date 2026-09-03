import Foundation
import Testing
@testable import EshCore

private struct MockProvider: CapabilityProvider {
    let descriptor: CapabilityProviderDescriptor
    func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { cont in cont.yield(.done(finishReason: "ok")); cont.finish() }
    }
}

@Suite
struct CapabilityRegistryTests {
    private func provider(_ id: String, _ caps: [CapabilityID], inputs: [ModelModality], outputs: [ModelModality]) -> MockProvider {
        MockProvider(descriptor: CapabilityProviderDescriptor(
            id: id, capabilities: caps, acceptedInputs: inputs, producedOutputs: outputs, backend: .native))
    }

    @Test
    func filtersByCapability() {
        let reg = CapabilityRegistry(providers: [
            provider("text-llm", [.languageGenerate], inputs: [.text], outputs: [.text]),
            provider("embed", [.languageEmbed], inputs: [.text], outputs: [.embedding])
        ])
        let gen = reg.providers(for: .languageGenerate, inputs: [.text], output: .text)
        #expect(gen.map { $0.descriptor.id } == ["text-llm"])
        let emb = reg.providers(for: .languageEmbed, inputs: [.text], output: .embedding)
        #expect(emb.map { $0.descriptor.id } == ["embed"])
    }

    @Test
    func filtersByInputModalitySubset() {
        let reg = CapabilityRegistry(providers: [
            provider("text-only", [.languageGenerate], inputs: [.text], outputs: [.text]),
            provider("vlm", [.languageGenerate], inputs: [.text, .image], outputs: [.text])
        ])
        // An image+text request excludes the text-only provider.
        let both = reg.providers(for: .languageGenerate, inputs: [.text, .image], output: .text)
        #expect(both.map { $0.descriptor.id } == ["vlm"])
        // A text-only request matches both.
        let textOnly = reg.providers(for: .languageGenerate, inputs: [.text], output: .text)
        #expect(Set(textOnly.map { $0.descriptor.id }) == ["text-only", "vlm"])
    }

    @Test
    func filtersByOutputModality() {
        let reg = CapabilityRegistry(providers: [
            provider("svg", [.vectorGenerate], inputs: [.text], outputs: [.image]),
        ])
        #expect(reg.providers(for: .vectorGenerate, inputs: [.text], output: .image).count == 1)
        #expect(reg.providers(for: .vectorGenerate, inputs: [.text], output: .text).isEmpty)
    }

    @Test
    func candidatesDerivesModalitiesFromRequest() {
        var reg = CapabilityRegistry()
        reg.register(provider("vlm", [.imageUnderstand], inputs: [.text, .image], outputs: [.text]))
        let req = ExecutionRequest(
            capability: .imageUnderstand,
            inputs: [.text("what is this?"), .attachment(EshAttachment(kind: .image, uri: "/tmp/a.png"))],
            output: .text)
        #expect(reg.candidates(for: req).map { $0.descriptor.id } == ["vlm"])
    }

    @Test
    func inputModalityMapping() {
        #expect(CapabilityInput.text("x").modality == .text)
        #expect(CapabilityInput.attachment(EshAttachment(kind: .image)).modality == .image)
        #expect(CapabilityInput.attachment(EshAttachment(kind: .audio)).modality == .audio)
        #expect(CapabilityInput(payload: .embedding([1])).modality == .embedding)
        #expect(CapabilityInput(payload: .structured(.string("x"))).modality == .json)
    }

    @Test
    func emptyWhenNoProviderMatches() {
        let reg = CapabilityRegistry(providers: [
            provider("text-llm", [.languageGenerate], inputs: [.text], outputs: [.text])
        ])
        // No provider for image generation → honest empty (no local provider can do this).
        #expect(reg.providers(for: .imageGenerate, inputs: [.text], output: .image).isEmpty)
    }
}
