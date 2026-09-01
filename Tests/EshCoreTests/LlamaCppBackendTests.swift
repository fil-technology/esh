import Foundation
import Testing
@testable import EshCore

@Suite
struct LlamaCppBackendTests {
    // Regression guard for blocker B3: recent llama.cpp builds split the tools — `llama-cli` is
    // interactive-only and rejects `--no-conversation`, which left esh hanging on the `>` prompt.
    // The one-shot completion run MUST use the non-interactive flags (via `llama-completion`).

    @Test
    func completionArgumentsAreNonInteractive() {
        let args = LlamaCppRuntime.completionArguments(
            modelPath: "/models/m.gguf",
            prompt: "User: hi\nAssistant:",
            config: GenerationConfig(maxTokens: 32, temperature: 0.5)
        )
        #expect(args.contains("--no-conversation"))   // do not drop into interactive chat mode
        #expect(args.contains("--no-display-prompt"))  // stdout = generated tokens only
        #expect(args.contains("--simple-io"))          // no TTY control sequences
        #expect(args.contains("-p"))
        #expect(args.contains("/models/m.gguf"))
        // Must NOT accidentally request conversation mode.
        #expect(args.contains("--conversation") == false)
        #expect(args.contains("-cnv") == false)
    }

    @Test
    func nativeConstrainedDecodingFlagsAreWired() {
        let jsonArgs = LlamaCppRuntime.completionArguments(
            modelPath: "/m.gguf", prompt: "p",
            config: GenerationConfig(jsonSchema: #"{"type":"object"}"#)
        )
        #expect(jsonArgs.contains("--json-schema"))
        #expect(jsonArgs.contains(#"{"type":"object"}"#))

        let grammarArgs = LlamaCppRuntime.completionArguments(
            modelPath: "/m.gguf", prompt: "p",
            config: GenerationConfig(grammar: "root ::= \"yes\" | \"no\"")
        )
        #expect(grammarArgs.contains("--grammar"))

        // JSON schema takes precedence when both are somehow present.
        let bothArgs = LlamaCppRuntime.completionArguments(
            modelPath: "/m.gguf", prompt: "p",
            config: GenerationConfig(jsonSchema: #"{"type":"object"}"#, grammar: "root ::= \"x\"")
        )
        #expect(bothArgs.contains("--json-schema"))
        #expect(bothArgs.contains("--grammar") == false)
    }

    @Test
    func samplingControlsPassThrough() {
        let args = LlamaCppRuntime.completionArguments(
            modelPath: "/m.gguf", prompt: "p",
            config: GenerationConfig(maxTokens: 16, temperature: 0.9, topP: 0.8, topK: 40,
                                     minP: 0.05, repetitionPenalty: 1.1, seed: 7)
        )
        for flag in ["--top-p", "--top-k", "--min-p", "--repeat-penalty", "--seed", "--temp", "-n"] {
            #expect(args.contains(flag), "missing \(flag)")
        }
    }

    @Test
    func runtimeNotFoundMessageMentionsCompletionBinary() {
        #expect(LlamaCppBackend.runtimeNotFoundMessage.contains("llama-completion"))
    }
}
