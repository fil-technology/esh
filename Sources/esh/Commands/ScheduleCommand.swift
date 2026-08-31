import Foundation
import EshCore

/// `esh schedule` — the Adaptive Intelligence Scheduler (M9). Given a capability request under
/// constraints (not a specific model), pick the best installed model + optimization plan on this
/// Mac, with recorded rationale.
///
///   esh schedule --goal coding --quality high --context 40000 --tools [--json]
enum ScheduleCommand {
    static func run(arguments: [String], root: PersistenceRoot) throws {
        let json = arguments.contains("--json")
        let goal = CommandSupport.optionalValue(flag: "--goal", in: arguments).flatMap(CapabilityRequest.Goal.init(cliValue:)) ?? .general
        let quality = CommandSupport.optionalValue(flag: "--quality", in: arguments).flatMap(CapabilityRequest.Quality.init(cliValue:)) ?? .balanced
        let latency = CommandSupport.optionalValue(flag: "--latency", in: arguments).flatMap(CapabilityRequest.Latency.init(cliValue:)) ?? .interactive
        let context = CommandSupport.optionalValue(flag: "--context", in: arguments).flatMap(Int.init)

        let request = CapabilityRequest(
            goal: goal,
            quality: quality,
            latency: latency,
            expectedContextTokens: context,
            toolCallingRequired: arguments.contains("--tools"),
            visionRequired: arguments.contains("--vision"),
            localOnly: !arguments.contains("--allow-cloud")
        )

        let host = HostMachineProfileService().currentProfile()
        let decision = SchedulerService().decide(request: request, root: root, host: host)

        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(decision), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }

        if let model = decision.selectedModelID {
            print("Selected: \(model) [\(decision.backend?.rawValue ?? "?")]  ·  mode \(decision.performanceMode.rawValue)  ·  fit \(decision.fitClass ?? "?")")
            if let profile = decision.executionProfile { print("Plan: \(profile.summaryLine)") }
        } else if decision.appleIntelligenceSuggested {
            print("Suggestion: use Apple Intelligence (esh apple) — no installed model fits, zero downloads.")
        } else {
            print("No suitable local model. Install one: esh model recommended --for-this-mac")
        }
        print("Why:")
        for r in decision.rationale { print("  - \(r)") }
        for w in decision.warnings { print("  ! \(w)") }
    }
}
