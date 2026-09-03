import Foundation
import Testing
@testable import EshCore

// A provider that persists an artifact and emits it (mimics the Stage-1 SVG provider shape).
private struct ArtifactMockProvider: CapabilityProvider {
    let descriptor = CapabilityProviderDescriptor(
        id: "svg-mock", capabilities: [.vectorGenerate], acceptedInputs: [.text],
        producedOutputs: [.image], backend: .native, previewMode: .staticSandbox)
    func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
                    let art = Artifact(kind: .svg, mimeType: "image/svg+xml", validation: .valid, preview: .staticSandbox)
                    let saved = try context.artifactStore.save(art, files: ["art.svg": svg])
                    cont.yield(.artifactProduced(saved))
                    cont.yield(.done(finishReason: "stop"))
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite
struct CapabilityExecutionServiceTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-exec-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir), artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    @Test
    func languageGenerateBridgesToInferenceStream() async throws {
        let provider = LanguageGenerateProvider(stream: { _ in
            AsyncThrowingStream { cont in cont.yield("Hello"); cont.yield(", world"); cont.finish() }
        })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(
            ExecutionRequest(capability: .languageGenerate, inputs: [.text("hi")], output: .text))
        #expect(result.text == "Hello, world")
        #expect(result.outputs.isEmpty)
    }

    @Test
    func artifactProviderPersistsAndReturnsTypedOutput() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [ArtifactMockProvider()]), context: ctx)
        let result = try await svc.executeCollecting(
            ExecutionRequest(capability: .vectorGenerate, inputs: [.text("a cat")], output: .svg))
        #expect(result.text == nil)
        #expect(result.outputs.count == 1)
        let art = try #require(result.outputs.first)
        #expect(art.kind == .svg)
        // The artifact was actually persisted and its bytes are retrievable.
        let bytes = try ctx.artifactStore.data(id: art.id, file: art.files.first!.relativePath)
        #expect(bytes != nil)
    }

    @Test
    func unsupportedCapabilityThrowsHonestly() async {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(
                ExecutionRequest(capability: .imageGenerate, inputs: [.text("a fox")], output: .init(modality: .image)))
        }
    }

    @Test
    func adapterMapsInferenceRequestToExecutionAndBack() {
        let ext = ExternalInferenceRequest(
            model: "m",
            messages: [ExternalInferenceMessage(role: .system, text: "sys"),
                       ExternalInferenceMessage(role: .user, text: "hi")],
            generation: GenerationConfig(maxTokens: 128, temperature: 0.5),
            responseFormat: .json)
        let exec = CapabilityAdapters.executionRequest(from: ext)
        #expect(exec.capability == .languageGenerate)
        #expect(exec.inputs.count == 2)
        #expect(exec.output.modality == .json)
        #expect(exec.model == "m")
        // Round trip back to an inference request preserves the essentials.
        let back = CapabilityAdapters.inferenceRequest(from: exec)
        #expect(back.model == "m")
        #expect(back.messages.count == 2)
        #expect(back.messages.first?.role == .system)
        #expect(back.generation.maxTokens == 128)
        #expect(back.responseFormat?.kind == .json)
    }
}
