import Foundation

// esh 2.1 — Stage 4.3: detect vision-language models from their config.json (architecture / model_type /
// vision fields), NOT from name strings. Fixes VLMs being installed as text-only (e.g. nanoLLaVA:
// model_type "llava-qwen2", architecture "BunnyQwenForCausalLM" — name-matching missed it, but its config
// carries a top-level `vision_config`). Pure + unit-testable over a parsed config dict.
public enum VisionModelConfigClassifier {
    /// Strong-to-weak signals a config.json is a VLM.
    public static func isVisionLanguageModel(config: [String: Any]) -> Bool {
        // 1) A top-level vision_config block is the most reliable signal (present for LLaVA/Bunny/Qwen-VL/…).
        if config["vision_config"] is [String: Any] { return true }
        // 2) VLM-specific config keys.
        for key in ["image_token_index", "image_token_id", "mm_vision_tower", "vision_tower", "visual"] where config[key] != nil {
            return true
        }
        // 3) model_type patterns.
        let mt = (config["model_type"] as? String ?? "").lowercased()
        if visionModelTypeNeedles.contains(where: { mt.contains($0) }) { return true }
        // 4) architecture class-name patterns.
        let archs = (config["architectures"] as? [Any])?.compactMap { $0 as? String } ?? []
        if archs.contains(where: { a in let l = a.lowercased(); return visionArchNeedles.contains { l.contains($0) } }) {
            return true
        }
        return false
    }

    /// Read an installed model's config.json and classify. Returns false if it can't be read/parsed.
    public static func classifyInstall(directory: URL) -> Bool {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return isVisionLanguageModel(config: obj)
    }

    // Deliberately vision-specific to avoid false positives on text seq2seq models (e.g. "ForConditional
    // Generation" alone is NOT included — T5/BART use it).
    static let visionModelTypeNeedles = ["llava", "vl", "vlm", "mllama", "idefics", "paligemma", "internvl",
                                         "smolvlm", "bunny", "cogvlm", "pixtral", "phi3_v", "phi-3-v", "moondream"]
    static let visionArchNeedles = ["llava", "vlforcausallm", "vlforconditional", "vl_for", "vision", "idefics",
                                    "paligemma", "mllama", "bunny", "pixtral", "internvl", "smolvlm", "moondream"]
}
