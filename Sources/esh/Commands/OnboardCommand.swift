import Foundation
import Darwin
import EshCore

/// `esh onboard` — guided first-run setup: detect the Mac, choose where large models live
/// (internal or external SSD), pick a hardware-matched model, install it, and finish with the
/// commands to start using esh. Safe to re-run; never traps expert users.
///
///   esh onboard              interactive setup (or a summary when not a TTY)
///   esh onboard --status     print detected environment + onboarding state, make no changes
///   esh onboard --yes        non-interactive: install the top hardware-matched model
enum OnboardCommand {
    static func run(
        arguments: [String],
        root: PersistenceRoot,
        service: ModelService,
        catalogService: ModelCatalogService
    ) async throws {
        let onboarding = OnboardingService()
        let environment = onboarding.detectEnvironment(root: root)
        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0

        if arguments.contains("--status") || (!interactive && !arguments.contains("--yes")) {
            printSummary(environment: environment, root: root, onboarding: onboarding)
            if !interactive && !arguments.contains("--yes") {
                print("")
                print("Run `esh onboard` in an interactive terminal for guided setup, or `esh onboard --yes` to auto-install a recommended model.")
            }
            return
        }

        printWelcome(environment: environment)

        if let help = environment.missingEngineHelp {
            print(help)
            // Still allow storage setup, but installing/validating won't work yet.
        }

        var activeRoot = root

        // --yes: non-interactive auto path.
        if arguments.contains("--yes") {
            let picks = onboarding.recommendations(useCase: .general, environment: environment, limit: 1)
            guard let model = picks.first else {
                print("No hardware-matched model is available to auto-install.")
                return
            }
            print("Installing \(model.id) (\(model.sizeHint))…")
            try await ModelInstallCommand.run(identifier: model.id, service: service, catalogService: catalogService)
            try onboarding.markCompleted(root: activeRoot, selectedModelID: model.id, storageMode: environment.storage.external ? "external" : "internal")
            printFinish(selected: model.id)
            return
        }

        // 1. Storage location
        activeRoot = try chooseStorage(current: activeRoot) ?? activeRoot

        // 2. Existing models
        let installed = (try? service.list()) ?? []
        if !installed.isEmpty {
            print("")
            print("Found \(installed.count) model(s) already installed: \(installed.prefix(5).map(\.id).joined(separator: ", "))")
            if !confirm("Install another recommended model now? [y/N]") {
                try onboarding.markCompleted(root: activeRoot, selectedModelID: installed.first?.id, storageMode: activeRoot.usesExternalAssets ? "external" : "internal")
                printFinish(selected: installed.first?.id)
                return
            }
        }

        // 3. Use case
        let useCase = chooseUseCase()

        // 4. Recommendations (re-detect env in case storage changed)
        let env2 = onboarding.detectEnvironment(root: activeRoot)
        let recommendations = onboarding.recommendations(useCase: useCase, environment: env2, limit: 4)
        guard !recommendations.isEmpty else {
            print("No recommended models fit this Mac right now. Browse the full list with `esh model recommended`.")
            return
        }

        // 5. Pick + install
        guard let selected = chooseModel(recommendations) else {
            print("Setup paused. Re-run `esh onboard` any time.")
            return
        }

        if env2.hasUsableEngine {
            print("")
            print("Installing \(selected.id) (\(selected.sizeHint), needs ~\(selected.memoryHint))…")
            try await ModelInstallCommand.run(identifier: selected.id, service: service, catalogService: catalogService)
        } else {
            print("Storage is set, but no engine is ready yet, so the model was not installed.")
            print(env2.missingEngineHelp ?? "")
        }

        try onboarding.markCompleted(root: activeRoot, selectedModelID: selected.id, storageMode: activeRoot.usesExternalAssets ? "external" : "internal")
        printFinish(selected: selected.id)
    }

    // MARK: - Steps

    private static func chooseStorage(current: PersistenceRoot) throws -> PersistenceRoot? {
        let picker = InteractiveListPicker()
        let externalNote = current.usesExternalAssets ? " (currently: \(current.assetsRootURL.path))" : ""
        switch picker.pick(
            title: "Where should large models live?",
            subtitle: "Model weights can be many gigabytes. Keep them internal, or put them on an external SSD.",
            items: [
                .init(title: "Internal disk", detail: "Default — everything under ~/.esh"),
                .init(title: "External / custom folder", detail: "e.g. /Volumes/AI/esh\(externalNote)"),
                .init(title: "Keep current", detail: current.assetsRootURL.path)
            ],
            primaryHint: "Enter select"
        ) {
        case .selected(0):
            return try StorageService().useInternal(migrateExisting: false, root: current)
        case .selected(1):
            guard let path = prompt("External/custom path for models"), !path.isEmpty else { return current }
            let move = confirm("Move any existing models there now? [y/N]")
            do {
                let newRoot = try StorageService().setAssetsRoot(path, migrateExisting: move, root: current) { print("  \($0)") }
                print("Models will be stored at \(newRoot.assetsRootURL.path)")
                return newRoot
            } catch {
                print("Could not use that path: \(error.localizedDescription)")
                return current
            }
        default:
            return current
        }
    }

    private static func chooseUseCase() -> RecommendedModelRegistry.UseCase {
        let prompt = InteractiveChoicePrompt()
        let key = prompt.choose(
            title: "What will you mostly use esh for?",
            message: "This tailors the recommended models to your Mac.",
            choices: [
                .init(key: "g", label: "General"),
                .init(key: "c", label: "Coding"),
                .init(key: "f", label: "Fast"),
                .init(key: "b", label: "Best quality")
            ],
            footer: "←/→ navigate • enter confirm • esc general"
        )
        switch key {
        case "c": return .coding
        case "f": return .fast
        case "b": return .bestForThisMac
        default: return .general
        }
    }

    private static func chooseModel(_ models: [RecommendedModel]) -> RecommendedModel? {
        let picker = InteractiveListPicker()
        let items = models.map { model in
            InteractiveListPicker.Item(
                title: "\(model.id)  [\(model.status.rawValue)]",
                detail: "\(model.tier.displayName) | \(model.contextHint) ctx | \(model.memoryHint) | \(model.sizeHint) | \(model.capabilities.map(\.rawValue).joined(separator: ","))"
            )
        }
        switch picker.pick(
            title: "Recommended models for this Mac",
            subtitle: "Enter installs the selected model.",
            items: items,
            primaryHint: "Enter install"
        ) {
        case .selected(let index): return models.indices.contains(index) ? models[index] : nil
        default: return nil
        }
    }

    // MARK: - Output

    private static func printWelcome(environment: OnboardingEnvironment) {
        print("Welcome to esh — a local-first AI runtime. Everything runs on your Mac; nothing is sent to the cloud.")
        print("")
        print("Detected: \(environment.host.chipDescription ?? "Apple Silicon"), macOS \(environment.macOS)"
            + (environment.host.totalMemoryGB.map { String(format: ", %.0f GB RAM", $0) } ?? ""))
        let engines = [environment.mlxReady ? "MLX" : nil, environment.llamaCppReady ? "llama.cpp" : nil].compactMap { $0 }
        print("Engines ready: \(engines.isEmpty ? "none" : engines.joined(separator: ", "))")
        if environment.appleIntelligence.available {
            print("Apple Intelligence: available on this Mac (a zero-download on-device option; full esh integration is coming).")
        }
        print("")
    }

    private static func printSummary(environment: OnboardingEnvironment, root: PersistenceRoot, onboarding: OnboardingService) {
        let state = OnboardingStateStore(root: root).load()
        print("onboarding: \(state.completed ? "completed" : "not completed")")
        print("chip: \(environment.host.chipDescription ?? "Apple Silicon")")
        print("macos: \(environment.macOS)")
        if let total = environment.host.totalMemoryGB {
            print(String(format: "memory: %.0f GB total, ~%.0f GB usable for models", total, environment.host.safeBudgetGB ?? 0))
        }
        print("engines: mlx=\(environment.mlxReady ? "ready" : "not_ready") llama.cpp=\(environment.llamaCppReady ? "ready" : "not_ready")")
        print("apple_intelligence: \(environment.appleIntelligence.available ? "available" : environment.appleIntelligence.availability.rawValue)")
        print("storage: \(environment.storage.assetsRoot) (\(environment.storage.status))")
        print("installed_models: \(environment.installedModelCount)")
        if let help = environment.missingEngineHelp { print(""); print(help) }
        print("")
        print("Recommended for this Mac (general use):")
        for model in onboarding.recommendations(useCase: .general, environment: environment, limit: 3) {
            print("  \(model.id)  \(model.sizeHint)  \(model.contextHint) ctx  \(model.capabilities.map(\.rawValue).joined(separator: ","))")
        }
    }

    private static func printFinish(selected: String?) {
        print("")
        print("✓ Setup complete\(selected.map { ", \($0) ready" } ?? "").")
        print("Next:")
        print("  esh              open the interactive menu")
        print("  esh chat         start a chat" + (selected.map { " (e.g. esh chat --model \($0))" } ?? ""))
        print("  esh serve        run a local OpenAI-compatible API")
        print("  esh storage show / esh doctor   inspect storage and health")
    }

    // MARK: - Prompt helpers

    private static func prompt(_ label: String) -> String? {
        InteractiveTextPrompt().capture(label: label)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func confirm(_ message: String) -> Bool {
        let prompt = InteractiveChoicePrompt()
        return prompt.choose(
            title: "Confirm",
            message: message,
            choices: [.init(key: "y", label: "Yes"), .init(key: "n", label: "No")],
            footer: "←/→ navigate • enter confirm • esc no"
        ) == "y"
    }
}
