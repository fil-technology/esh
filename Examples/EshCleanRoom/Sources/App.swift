import SwiftUI
import UIKit
import EshRuntime      // the public SDK facade
import EshLlamaCpp     // optional embedded GGUF (adds EshRuntime.withEmbeddedGGUF + the .gguf backend)

// Clean-room consumer (M10 #1). A fresh iOS app that integrates esh ONLY through its public SwiftPM
// products. It imports NO EshCore/EshMacRuntime internals, constructs NO registry/backend, and handles
// NO model paths. This is exactly the code a real app developer writes.

@main
struct EshCleanRoomApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor
final class Model: ObservableObject {
    @Published var log = "idle"

    /// Non-interactive sequence for device validation via `devicectl … process launch --console`.
    func autoRun() async {
        UIApplication.shared.isIdleTimerDisabled = true
        print("CLEANROOM begin")
        await runAppleFM()
        await runManagedGGUF()
        print("CLEANROOM done")
    }

    /// Apple Foundation Models — the zero-setup path.
    func runAppleFM() async {
        let runtime = EshRuntime()
        do {
            let r = try await runtime.generate(prompt: "Reply with exactly one word: pong")
            log = "AppleFM backend=\(r.selection.backend.rawValue) text=\(r.text.prefix(40))"
            print("CLEANROOM appleFM ok backend=\(r.selection.backend.rawValue) text=\(r.text.replacingOccurrences(of: "\n", with: " ").prefix(60))")
        } catch let e as EshRuntimeError {
            log = "AppleFM typed error: \(e.errorDescription ?? "")"
            print("CLEANROOM appleFM typedError=\(e)")
        } catch {
            log = "AppleFM error: \(error)"
            print("CLEANROOM appleFM error=\(error)")
        }
    }

    /// Managed embedded GGUF — install a curated model, then pin it. No paths, no llama.cpp knowledge.
    func runManagedGGUF() async {
        let runtime = EshRuntime.withEmbeddedGGUF()
        let model = LocalModelDescriptor.qwen05B
        do {
            let repairs = await runtime.reconcileLocalModels()   // repair interrupted state at launch
            print("CLEANROOM reconcile consistent=\(repairs.isConsistent) recovered=\(repairs.recoveredRecords)")
            let plan = await runtime.installPlan(for: model)
            print("CLEANROOM plan fit=\(plan.fit) suitable=\(plan.suitable) downloadMB=\(plan.downloadBytes/1_048_576) freeMB=\(plan.availableStorageBytes.map { $0/1_048_576 } ?? -1)")
            let already = await runtime.localModels().first { $0.descriptor.id == model.id }?.state == .installed
            if !already {
                try await runtime.install(model) { p in
                    if Int(p*100) % 25 == 0 { print("CLEANROOM download \(Int(p*100))%") }
                }
            }
            let r = try await runtime.generate(.init(prompt: "Reply with exactly one word: pong",
                                                     constraints: .pinned(model.id)))
            log = "GGUF backend=\(r.selection.backend.rawValue) text=\(r.text.prefix(40))"
            print("CLEANROOM gguf ok backend=\(r.selection.backend.rawValue) model=\(r.selection.modelID) text=\(r.text.replacingOccurrences(of: "\n", with: " ").prefix(60))")
        } catch let e as EshRuntimeError {
            log = "GGUF typed error: \(e.errorDescription ?? "")"
            print("CLEANROOM gguf typedError=\(e)")
        } catch {
            log = "GGUF error: \(error)"
            print("CLEANROOM gguf error=\(error)")
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    var body: some View {
        VStack(spacing: 16) {
            Text("esh clean-room").font(.headline)
            Text(model.log).font(.footnote.monospaced()).padding()
        }
        .padding()
        .task { await model.autoRun() }
    }
}
