import SwiftUI
import EshCore      // value types the SDK returns (BackendKind, AppleProvider ids, Message, GenerationConfig)
import EshRuntime   // the public esh SDK — the ONLY way this probe reaches inference

// esh iOS integration probe (M4). Intentionally tiny; a verification harness, not a product.
// It exercises the exact path a real app uses:
//   EshIOSProbe → EshRuntime → InferenceBackendRegistry → AppleBackend → AppleBackendRuntime
//                → AppleIntelligenceService → FoundationModels
// It never instantiates AppleBackend / AppleIntelligenceService / LanguageModelSession directly.

@main
struct EshIOSProbeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    private let runtime = EshRuntime()               // default platform assembly (iOS → Apple FM only)

    @Published var prompt: String = "Reply with exactly one word: pong"
    @Published var availability: String = "—"
    @Published var deviceProfileText: String = "—"
    @Published var output: String = ""
    @Published var selection: String = "—"
    @Published var localOnly: String = "—"
    @Published var elapsed: String = "—"
    @Published var error: String = ""
    @Published var running: Bool = false

    private var task: Task<Void, Never>?

    func refreshCapabilities() {
        Task { @MainActor in
            let snap = await runtime.capabilities()
            let ai = snap.appleIntelligence
            availability = "Apple FM: \(ai.availability.rawValue) (available=\(ai.available), onDevice=\(ai.onDevice))\n\(ai.detail)"
            print("ESH-M4 availability=\(ai.availability.rawValue) available=\(ai.available) hasReadyBackend=\(snap.hasReadyBackend)")
        }
    }

    func generate() {
        guard !running else { return }
        running = true; error = ""; output = ""; selection = "—"; elapsed = "—"
        let req = EshGenerationRequest(prompt: prompt, constraints: .localOnly)
        task = Task { @MainActor in
            let start = ContinuousClock.now
            do {
                let result = try await runtime.generate(req)
                let d = start.duration(to: .now)
                output = result.text
                selection = "backend=\(result.selection.backend.rawValue)  model=\(result.selection.modelID)\nreason=\(result.selection.reason)"
                localOnly = "localOnly satisfied: \(result.selection.localOnlySatisfied)"
                elapsed = "\(d)"
                let ttft = result.metrics.ttftMilliseconds.map { String(format: "%.1f ms", $0) } ?? "n/a"
                print("ESH-M4 firstCall elapsed=\(d) backend=\(result.selection.backend.rawValue) model=\(result.selection.modelID) ttft=\(ttft) text=\(result.text.prefix(80))")
            } catch let e as EshRuntimeError {
                error = "Typed error: \(e.localizedDescription)"
                print("ESH-M4 typedError=\(e)")
            } catch is CancellationError {
                error = "Cancelled."
                print("ESH-M4 cancelled")
            } catch {
                self.error = "Error: \(error.localizedDescription)"
                print("ESH-M4 error=\(error)")
            }
            running = false
        }
    }

    func cancel() { task?.cancel() }

    /// Full non-interactive probe sequence for device validation via `devicectl … process launch --console`.
    /// Prints `ESH-M4 …` lines: environment, availability, two generations (first/warm latency), selection,
    /// metrics, and an honest typed status when Apple FM is unavailable.
    func autoProbe() async {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("ESH-M4 os=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) device=\(await Self.deviceModel())")
        let snap = await runtime.capabilities()
        let ai = snap.appleIntelligence
        availability = "Apple FM: \(ai.availability.rawValue) (available=\(ai.available), onDevice=\(ai.onDevice))\n\(ai.detail)"
        print("ESH-M4 availability=\(ai.availability.rawValue) available=\(ai.available) onDevice=\(ai.onDevice) hasReadyBackend=\(snap.hasReadyBackend) detail=\(ai.detail)")

        // M5: real device profile through the public SDK.
        let dp = await runtime.deviceProfile()
        func gb(_ b: UInt64?) -> String { b.map { String(format: "%.2f GB", Double($0) / 1_073_741_824) } ?? "unknown" }
        deviceProfileText = """
        platform=\(dp.platform.rawValue) model=\(dp.deviceModel ?? "?") os=\(dp.osVersion)
        physicalMemory=\(gb(dp.physicalMemoryBytes))
        availableMemory=\(gb(dp.availableMemoryBytes)) (\(dp.availableMemoryKind.rawValue))
        freeStorage=\(gb(dp.availableStorageBytes))
        thermal=\(dp.thermalState?.rawValue ?? "unknown")  lowPower=\(dp.lowPowerModeEnabled.map(String.init) ?? "unknown")
        appleFM=\(dp.supportsAppleFoundationModels)
        """
        print("ESH-M5 platform=\(dp.platform.rawValue) model=\(dp.deviceModel ?? "?") os=\(dp.osVersion) physicalBytes=\(dp.physicalMemoryBytes) availableBytes=\(dp.availableMemoryBytes.map(String.init) ?? "nil") availableKind=\(dp.availableMemoryKind.rawValue) storageBytes=\(dp.availableStorageBytes.map(String.init) ?? "nil") thermal=\(dp.thermalState?.rawValue ?? "nil") lowPower=\(dp.lowPowerModeEnabled.map(String.init) ?? "nil") appleFM=\(dp.supportsAppleFoundationModels)")
        guard ai.available else {
            print("ESH-M4 RESULT=UNAVAILABLE reason=\(ai.availability.rawValue)")
            error = "Apple Intelligence unavailable: \(ai.availability.rawValue)"
            return
        }
        let req = EshGenerationRequest(prompt: prompt, constraints: .localOnly)
        func once(_ label: String) async {
            let start = ContinuousClock.now
            do {
                let r = try await runtime.generate(req)
                let d = start.duration(to: .now)
                output = r.text
                selection = "backend=\(r.selection.backend.rawValue)  model=\(r.selection.modelID)\nreason=\(r.selection.reason)"
                localOnly = "localOnly satisfied: \(r.selection.localOnlySatisfied)"
                elapsed = "\(d)"
                let ttft = r.metrics.ttftMilliseconds.map { String(format: "%.1f", $0) } ?? "n/a"
                print("ESH-M4 \(label) elapsed=\(d) backend=\(r.selection.backend.rawValue) model=\(r.selection.modelID) reason=\"\(r.selection.reason)\" localOnly=\(r.selection.localOnlySatisfied) ttftMs=\(ttft) text=\"\(r.text.replacingOccurrences(of: "\n", with: " ").prefix(120))\"")
            } catch {
                print("ESH-M4 \(label) ERROR=\(error)")
                self.error = "\(error)"
            }
        }
        await once("firstCall")
        await once("secondCall")
        print("ESH-M4 RESULT=PASS")
    }

    private static func deviceModel() async -> String {
        var sysinfo = utsname(); uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw in
            raw.prefix { $0 != 0 }.map { Character(UnicodeScalar(UInt8($0))) }
        }
        return String(machine)
    }
}

struct ContentView: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Runtime availability") { Text(model.availability).font(.footnote.monospaced()) }
                Section("Device profile") { Text(model.deviceProfileText).font(.footnote.monospaced()) }
                Section("Prompt") {
                    TextField("Prompt", text: $model.prompt, axis: .vertical)
                    HStack {
                        Button(model.running ? "Generating…" : "Generate") { model.generate() }
                            .disabled(model.running)
                        if model.running { Button("Cancel", role: .cancel) { model.cancel() } }
                    }
                }
                Section("Result") {
                    Text(model.output.isEmpty ? "—" : model.output)
                    Text(model.selection).font(.footnote.monospaced())
                    Text(model.localOnly).font(.footnote)
                    Text("elapsed: \(model.elapsed)").font(.footnote.monospaced())
                    if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("esh iOS Probe")
            .task { await model.autoProbe() }
        }
    }
}
