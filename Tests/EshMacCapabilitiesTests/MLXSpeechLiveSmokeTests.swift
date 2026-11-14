import Foundation
import Testing
import EshCore
@testable import EshRuntime
@testable import EshMacCapabilities

#if os(macOS)
// LIVE synth -> transcribe smoke for the mlx_audio speech engines, through the REAL stack: the shipped manifest
// (its declared pip packages), EshManagedPythonHost's real provisioning (inspect -> pip install -> re-inspect),
// the SDK-bundled bridge script, the host's request mapping (catalog defaults: Kokoro's voice), and artifact
// persistence — then the produced WAV is transcribed back and must contain the sentence.
//
// This is the test that would have caught e4fff2d (NameError `os`, missing `misaki`, swallowed mlx_audio
// errors). It needs network + ~1 GB of weights, so it is opt-in:
//
//     scripts/smoke-mlx-speech.sh            # creates a fresh py3.11 venv and runs this test
//
// or directly: ESH_MLX_SPEECH_SMOKE_PYTHON=<fresh venv>/bin/python3 swift test --filter MLXSpeechLiveSmoke
// Optional: ESH_MLX_SPEECH_SMOKE_ASSETS=<dir> to keep weights on an external volume between runs.
@Suite(.serialized) struct MLXSpeechLiveSmokeTests {
    static let sentence = "The quick brown fox jumps over the lazy dog."

    @Test func synthesizeThenTranscribeRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let python = env["ESH_MLX_SPEECH_SMOKE_PYTHON"], !python.isEmpty else { return }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("esh-speech-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let assets = env["ESH_MLX_SPEECH_SMOKE_ASSETS"].map { URL(fileURLWithPath: $0) } ?? state
        let root = PersistenceRoot(stateRootURL: state, assetsRootURL: assets)
        let host = EshManagedPythonHost(pythonPath: python, bridgeScriptsDir: nil, root: root)   // bundled bridge
        let context = ExecutionContext(root: root, artifactStore: FileArtifactStore(root: root))
        let manifests = MacCapabilities.manifests()
        let tts = CompatibilityCapabilityProvider(manifest: manifests.first { $0.id == .speechSynthesize }!, host: host, supported: true)
        let stt = CompatibilityCapabilityProvider(manifest: manifests.first { $0.id == .speechTranscribe }!, host: host, supported: true)

        // 1. Synthesize with NO model/voice options: the engine must provision itself and the catalog default
        //    (Kokoro) must get its required voice from the validated known-good defaults.
        let speech = try await run(tts, ExecutionRequest(capability: .audioSynthesizeSpeech, inputs: [.text(Self.sentence)],
                                                         output: OutputSpec(modality: .audio)), context: context)
        #expect(speech.kind == .audio)
        let wavData = try #require(try context.artifactStore.data(id: speech.id, file: speech.entrypoint ?? "output.wav"))
        #expect(wavData.count > 20_000, "synthesized WAV is suspiciously small (\(wavData.count) bytes)")
        let wav = state.appendingPathComponent("smoke.wav")
        try wavData.write(to: wav)

        // 2. After provisioning, live per-model readiness must report the default TTS model READY.
        let rows = await tts.modelOptionAvailability(for: .audioSynthesizeSpeech)
        let def = try #require(rows.first { $0.option.isDefault })
        #expect(def.readiness == .ready, "default TTS model not ready after a successful run: \(def.readiness)")

        // 3. Transcribe it back with the default STT model.
        let transcript = try await run(stt, ExecutionRequest(
            capability: .audioTranscribe,
            inputs: [.init(payload: .attachment(EshAttachment(kind: .audio, uri: wav.absoluteString)))],
            output: OutputSpec(modality: .text)), context: context)
        let textData = try #require(try context.artifactStore.data(id: transcript.id, file: transcript.entrypoint ?? "output.txt"))
        let text = String(decoding: textData, as: UTF8.self)
        let score = Self.wordOverlap(expected: Self.sentence, got: text)
        #expect(score >= 0.6, "round-trip transcript '\(text)' overlaps only \(score) with '\(Self.sentence)'")
    }

    private func run(_ provider: CompatibilityCapabilityProvider, _ request: ExecutionRequest,
                     context: ExecutionContext) async throws -> Artifact {
        var artifact: Artifact?
        var failure: String?
        for try await event in provider.execute(ResolvedExecutionRequest(request: request), context: context) {
            switch event {
            case .artifactProduced(let a): artifact = a
            case .failed(let message): failure = message
            default: break
            }
        }
        if let failure { Issue.record("\(provider.descriptor.id) failed: \(failure)") }
        return try #require(artifact, "\(provider.descriptor.id) produced no artifact")
    }

    static func wordOverlap(expected: String, got: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        }
        let exp = words(expected)
        let have = Set(words(got))
        guard !exp.isEmpty else { return 0 }
        return Double(exp.filter { have.contains($0) }.count) / Double(exp.count)
    }
}
#endif
