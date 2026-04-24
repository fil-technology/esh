import Foundation
import EshCore

enum ModelListCommand {
    static func run(arguments: [String] = [], service: ModelService) throws {
        let options = try Options(arguments: arguments)
        do {
            let installs = try service.list().filter { install in
                if let task = options.task, install.spec.task != task {
                    return false
                }
                if let capability = options.capability, !install.spec.capabilities.supports(capability: capability) {
                    return false
                }
                return true
            }
            if installs.isEmpty {
                print(options.hasFilters ? "No installed models match those filters." : "No installed models.")
                return
            }
            for install in installs {
                let capabilitySummary = Self.capabilitySummary(for: install.spec)
                print("\(install.id)\t\(install.spec.task.rawValue)\t\(capabilitySummary)\t\(ByteFormatting.string(for: install.sizeBytes))\t\(install.installPath)")
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func capabilitySummary(for spec: ModelSpec) -> String {
        let supported = ModelCapabilityFilter.allCases.filter { spec.capabilities.supports(capability: $0) }
        guard !supported.isEmpty else { return "-" }
        return supported.map(\.rawValue).joined(separator: ",")
    }

    private struct Options {
        var task: ModelTask?
        var capability: ModelCapabilityFilter?

        var hasFilters: Bool {
            task != nil || capability != nil
        }

        init(arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--task":
                    index += 1
                    guard index < arguments.count else {
                        throw StoreError.invalidManifest("Missing value for --task.")
                    }
                    guard let task = ModelTask(rawValue: arguments[index].lowercased()) else {
                        throw StoreError.invalidManifest("Unknown model task \(arguments[index]).")
                    }
                    self.task = task
                case "--capability":
                    index += 1
                    guard index < arguments.count else {
                        throw StoreError.invalidManifest("Missing value for --capability.")
                    }
                    guard let capability = ModelCapabilityFilter(rawValue: arguments[index].lowercased()) else {
                        throw StoreError.invalidManifest("Unknown model capability \(arguments[index]).")
                    }
                    self.capability = capability
                default:
                    throw StoreError.invalidManifest("Unknown model list option \(argument).")
                }
                index += 1
            }
        }
    }
}
