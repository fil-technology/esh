import SwiftUI
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

    // Apple Foundation Models — the zero-setup path.
    func runAppleFM() {
        Task {
            let runtime = EshRuntime()
            do {
                let r = try await runtime.generate(prompt: "Reply with exactly one word: pong")
                log = "AppleFM backend=\(r.selection.backend.rawValue) text=\(r.text.prefix(40))"
                print("CLEANROOM appleFM ok backend=\(r.selection.backend.rawValue) text=\(r.text.prefix(40))")
            } catch let e as EshRuntimeError {
                log = "AppleFM typed error: \(e.errorDescription ?? "")"
                print("CLEANROOM appleFM typedError=\(e)")
            } catch {
                log = "AppleFM error: \(error)"
                print("CLEANROOM appleFM error=\(error)")
            }
        }
    }

    // Managed embedded GGUF — install a curated model, then pin it. No paths, no llama.cpp knowledge.
    func runManagedGGUF() {
        Task {
            let runtime = EshRuntime.withEmbeddedGGUF()
            let model = LocalModelDescriptor.qwen05B
            do {
                _ = await runtime.reconcileLocalModels()                 // repair any interrupted state at launch
                let plan = await runtime.installPlan(for: model)
                print("CLEANROOM plan fit=\(plan.fit) suitable=\(plan.suitable) downloadMB=\(plan.downloadBytes/1_048_576)")
                if !(await runtime.localModels().first { $0.descriptor.id == model.id }?.state == .installed) {
                    try await runtime.install(model) { p in print("CLEANROOM download \(Int(p*100))%") }
                }
                let r = try await runtime.generate(.init(prompt: "Reply with exactly one word: pong",
                                                         constraints: .pinned(model.id)))
                log = "GGUF backend=\(r.selection.backend.rawValue) text=\(r.text.prefix(40))"
                print("CLEANROOM gguf ok backend=\(r.selection.backend.rawValue) text=\(r.text.prefix(40))")
            } catch {
                log = "GGUF error: \(error)"
                print("CLEANROOM gguf error=\(error)")
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    var body: some View {
        VStack(spacing: 16) {
            Text("esh clean-room").font(.headline)
            Button("Run Apple FM") { model.runAppleFM() }
            Button("Run managed GGUF") { model.runManagedGGUF() }
            Text(model.log).font(.footnote.monospaced()).padding()
        }.padding()
    }
}
