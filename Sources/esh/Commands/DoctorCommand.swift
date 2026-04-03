import Foundation
import EshCore

enum DoctorCommand {
    static func run() throws {
        for line in try outputLines() {
            print(line)
        }
    }

    static func outputLines() throws -> [String] {
        let bridge = MLXBridge()
        let pythonURL = try bridge.resolvedPythonExecutable()
        let helperURL = try bridge.resolvedHelperScript()
        let root = PersistenceRoot.default()
        let bridgeDoctor: BridgeDoctorResponse = try bridge.run(
            command: "doctor",
            request: EmptyRequest(),
            as: BridgeDoctorResponse.self
        )

        return [
            "status: ok",
            "persistence_root: \(root.rootURL.path)",
            "python: \(pythonURL.path)",
            "bridge: \(helperURL.path)",
            "bridge_python: \(bridgeDoctor.pythonExecutable)",
            "mlx: \(bridgeDoctor.mlxVersion)",
            "mlx_lm: \(bridgeDoctor.mlxLMVersion)",
            "mlx_vlm: \(bridgeDoctor.mlxVLMVersion)",
            "numpy: \(bridgeDoctor.numpyVersion)"
        ]
    }
}

private struct EmptyRequest: Codable {}

private struct BridgeDoctorResponse: Codable {
    var pythonExecutable: String
    var mlxVersion: String
    var mlxLMVersion: String
    var mlxVLMVersion: String
    var numpyVersion: String
}
