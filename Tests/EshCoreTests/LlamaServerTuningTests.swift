import Testing
@testable import EshCore

@Suite struct LlamaServerTuningTests {
    @Test func defaultAddsNoArguments() {
        #expect(LlamaServerTuning.fromEnvironment([:]).arguments.isEmpty)
        #expect(LlamaServerTuning.fromEnvironment([:]).isDefault)
    }

    @Test func ngramSimpleWithDraftMax() {
        let t = LlamaServerTuning.fromEnvironment(["ESH_LLAMA_SPEC_TYPE": "ngram-simple", "ESH_LLAMA_DRAFT_MAX": "24"])
        #expect(t.arguments == ["--spec-type", "ngram-simple", "--draft-max", "24"])
        #expect(t.warnings.isEmpty)
    }

    @Test func kvTypeAppliesToKeysAndValues() {
        let t = LlamaServerTuning.fromEnvironment(["ESH_LLAMA_KV_TYPE": "Q8_0"])
        #expect(t.arguments == ["-ctk", "q8_0", "-ctv", "q8_0"])
        #expect(!t.warnings.isEmpty)
    }

    @Test func unknownOrHostileValuesAreIgnored() {
        let t = LlamaServerTuning.fromEnvironment([
            "ESH_LLAMA_SPEC_TYPE": "ngram-simple --model-draft /tmp/x",
            "ESH_LLAMA_KV_TYPE": "q8_0; rm -rf /",
            "ESH_LLAMA_DRAFT_MAX": "9999",
        ])
        #expect(t.isDefault)
        #expect(t.arguments.isEmpty)
    }

    @Test func draftMaxNeedsASpeculativeType() {
        #expect(LlamaServerTuning.fromEnvironment(["ESH_LLAMA_DRAFT_MAX": "8"]).arguments.isEmpty)
    }

    @Test func riskyModesCarryWarnings() {
        #expect(!LlamaServerTuning(speculative: .ngramMapK).warnings.isEmpty)
        #expect(!LlamaServerTuning(speculative: .ngramMod).warnings.isEmpty)
    }
}
