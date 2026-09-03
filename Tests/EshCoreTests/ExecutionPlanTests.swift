import Foundation
import Testing
@testable import EshCore

@Suite
struct ExecutionPlanTests {
    @Test
    func singleStepPlanRoundTrips() throws {
        let plan = ExecutionPlan.single(
            capability: .languageGenerate,
            inputModalities: [.text],
            outputModality: .text,
            providerID: "mlx-llm",
            modelID: "qwen",
            backend: .mlx,
            rationale: ["selected qwen [mlx] — fit comfortable"],
            evidenceBacked: true,
            privilegeLevel: .artifactOnly)
        #expect(plan.singleStep?.providerID == "mlx-llm")
        #expect(!plan.isPipeline)
        let data = try JSONEncoder().encode(plan)
        let back = try JSONDecoder().decode(ExecutionPlan.self, from: data)
        #expect(back == plan)
    }

    @Test
    func multiStepPipelineWiresStepOutputs() throws {
        // video → (keyframes→VLM) + (audio→STT) → reasoning
        let plan = ExecutionPlan(
            capability: .videoUnderstand,
            inputModalities: [.video, .text],
            outputModality: .json,
            steps: [
                ExecutionStep(providerID: "vlm", modelID: "qwen-vl", backend: .python),
                ExecutionStep(providerID: "stt", modelID: "parakeet", backend: .python),
                ExecutionStep(providerID: "reasoner", modelID: "qwen", backend: .mlx, consumesOutputOf: 0)
            ],
            rationale: ["keyframes→VLM + audio→STT → reasoning"],
            privilegeLevel: .validated)
        #expect(plan.isPipeline)
        #expect(plan.steps.count == 3)
        #expect(plan.steps[2].consumesOutputOf == 0)
        let back = try JSONDecoder().decode(ExecutionPlan.self, from: try JSONEncoder().encode(plan))
        #expect(back == plan)
    }
}
