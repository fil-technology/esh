import Foundation
import Testing
@testable import EshCore

@Suite
struct VisionModelConfigClassifierTests {
    @Test
    func detectsNanoLlavaByVisionConfig() {
        // nanoLLaVA: name/arch don't say "vision", but config has model_type llava-qwen2 + vision_config.
        let cfg: [String: Any] = ["model_type": "llava-qwen2", "architectures": ["BunnyQwenForCausalLM"],
                                  "vision_config": ["hidden_size": 1152]]
        #expect(VisionModelConfigClassifier.isVisionLanguageModel(config: cfg))
    }

    @Test
    func detectsQwenVLByModelTypeAndArch() {
        #expect(VisionModelConfigClassifier.isVisionLanguageModel(config: ["model_type": "qwen2_vl"]))
        #expect(VisionModelConfigClassifier.isVisionLanguageModel(config: ["architectures": ["Qwen2VLForConditionalGeneration"]]))
        #expect(VisionModelConfigClassifier.isVisionLanguageModel(config: ["model_type": "llava", "image_token_index": 32000]))
    }

    @Test
    func doesNotFlagPlainTextModels() {
        // Llama / Qwen text, and a T5 seq2seq (ForConditionalGeneration must NOT trigger vision).
        #expect(!VisionModelConfigClassifier.isVisionLanguageModel(config: ["model_type": "llama", "architectures": ["LlamaForCausalLM"]]))
        #expect(!VisionModelConfigClassifier.isVisionLanguageModel(config: ["model_type": "qwen2", "architectures": ["Qwen2ForCausalLM"]]))
        #expect(!VisionModelConfigClassifier.isVisionLanguageModel(config: ["model_type": "t5", "architectures": ["T5ForConditionalGeneration"]]))
        #expect(!VisionModelConfigClassifier.isVisionLanguageModel(config: ["model_type": "bert"]))
    }

    @Test
    func classifyInstallReadsConfigJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-vlm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = #"{"model_type":"llava-qwen2","architectures":["BunnyQwenForCausalLM"],"vision_config":{"hidden_size":1152}}"#
        try Data(cfg.utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(VisionModelConfigClassifier.classifyInstall(directory: dir))
        // No config → false, no crash.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("esh-empty-\(UUID().uuidString)", isDirectory: true)
        #expect(!VisionModelConfigClassifier.classifyInstall(directory: empty))
    }
}
