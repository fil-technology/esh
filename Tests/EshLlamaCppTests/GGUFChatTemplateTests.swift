import Testing
@testable import EshLlamaCpp

// Model-free tests of the embedded path's Jinja chat-template rendering (#41).
private let qwenStyle = """
{%- if messages[0]['role'] == 'system' %}{{- '<|im_start|>system\\n' + messages[0]['content'] + '<|im_end|>\\n' }}\
{%- else %}{{- '<|im_start|>system\\nYou are Qwen, created by Alibaba Cloud. You are a helpful assistant.<|im_end|>\\n' }}{%- endif %}
{%- for message in messages %}{%- if message.role != 'system' %}\
{{- '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>' + '\\n' }}{%- endif %}{%- endfor %}
{%- if add_generation_prompt %}{{- '<|im_start|>assistant\\n' }}{%- endif %}
"""

private let llama3Style = """
{{- bos_token }}{% for message in messages %}<|start_header_id|>{{ message['role'] }}<|end_header_id|>

{{ message['content'] | trim }}<|eot_id|>{% endfor %}{% if add_generation_prompt %}<|start_header_id|>assistant<|end_header_id|>

{% endif %}
"""

@Test func ggufTemplateAppliesTheModelsDefaultSystemPrompt() throws {
    let out = try #require(GGUFChatTemplate.render(template: qwenStyle, turns: [.init(role: "user", content: "Hi")],
                                                   bosToken: nil, eosToken: "<|im_end|>"))
    #expect(out == "<|im_start|>system\nYou are Qwen, created by Alibaba Cloud. You are a helpful assistant.<|im_end|>\n"
                 + "<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n")
}

@Test func ggufTemplateKeepsAnExplicitSystemPrompt() throws {
    let out = try #require(GGUFChatTemplate.render(
        template: qwenStyle, turns: [.init(role: "system", content: "Be terse."), .init(role: "user", content: "Hi")],
        bosToken: nil, eosToken: nil))
    #expect(out.hasPrefix("<|im_start|>system\nBe terse.<|im_end|>\n"))
    #expect(!out.contains("You are Qwen"))
}

@Test func ggufTemplateBOSIsNotDoubledWhenTheTokenizerAddsOne() throws {
    let out = try #require(GGUFChatTemplate.render(template: llama3Style, turns: [.init(role: "user", content: " Hi ")],
                                                   bosToken: "<|begin_of_text|>", eosToken: "<|eot_id|>"))
    #expect(out.hasPrefix("<|begin_of_text|><|start_header_id|>user<|end_header_id|>\n\nHi<|eot_id|>"))
    let stripped = GGUFChatTemplate.strippingTemplateBOS(out, bosToken: "<|begin_of_text|>", tokenizerAddsBOS: true)
    #expect(stripped.hasPrefix("<|start_header_id|>user"))
    // kept when the tokenizer does not add BOS itself
    #expect(GGUFChatTemplate.strippingTemplateBOS(out, bosToken: "<|begin_of_text|>", tokenizerAddsBOS: false) == out)
}

@Test func ggufTemplateThatCannotRenderFallsBack() {
    #expect(GGUFChatTemplate.render(template: "{% for m in messages %}{{ m.content ", turns: [.init(role: "user", content: "x")],
                                    bosToken: nil, eosToken: nil) == nil)
    #expect(GGUFChatTemplate.render(template: "{{ raise_exception('unsupported role') }}",
                                    turns: [.init(role: "user", content: "x")], bosToken: nil, eosToken: nil) == nil)
    #expect(GGUFChatTemplate.render(template: "", turns: [.init(role: "user", content: "x")],
                                    bosToken: nil, eosToken: nil) == nil)
}
