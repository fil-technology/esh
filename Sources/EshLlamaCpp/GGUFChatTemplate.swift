import Foundation
import Jinja

/// Renders a GGUF's embedded chat template (`tokenizer.chat_template`, a Jinja template) the way Hugging Face's
/// `apply_chat_template`, swift-transformers, mlx-lm and llama-server (`--jinja`) do, so the embedded path sends the
/// model the same prompt they do (issue #41). llama.cpp's C `llama_chat_apply_template` does NOT run Jinja: it maps a
/// template to a hard-coded format, which drops template logic such as Qwen's default system prompt.
///
/// Returns nil when the template can't be rendered (unsupported syntax, a `raise_exception` for an unsupported role,
/// an empty result); the caller then falls back to `llama_chat_apply_template`.
enum GGUFChatTemplate {
    struct Turn: Sendable {
        let role: String
        let content: String
    }

    static func render(template: String, turns: [Turn], bosToken: String?, eosToken: String?,
                       addGenerationPrompt: Bool = true) -> String? {
        do {
            // Same block handling as transformers / swift-transformers (`trim_blocks`, `lstrip_blocks`).
            let compiled = try Template(template, with: .init(lstripBlocks: true, trimBlocks: true))
            var context: [String: Value] = [
                "messages": .array(turns.map { ["role": .string($0.role), "content": .string($0.content)] }),
                "add_generation_prompt": .boolean(addGenerationPrompt),
            ]
            if let bosToken { context["bos_token"] = .string(bosToken) }
            if let eosToken { context["eos_token"] = .string(eosToken) }
            let rendered = try compiled.render(context)
            return rendered.isEmpty ? nil : rendered
        } catch {
            return nil
        }
    }

    /// The rendered prompt, minus a leading BOS the template wrote itself when the tokenizer will add one anyway
    /// (`add_bos_token`), so the model never sees a doubled BOS.
    static func strippingTemplateBOS(_ prompt: String, bosToken: String?, tokenizerAddsBOS: Bool) -> String {
        guard tokenizerAddsBOS, let bosToken, !bosToken.isEmpty, prompt.hasPrefix(bosToken) else { return prompt }
        return String(prompt.dropFirst(bosToken.count))
    }
}
