import Foundation
import LLMCacheCore

enum DoctorCommand {
    static func run() throws {
        let bridge = MLXBridge()
        let pythonURL = try bridge.resolvedPythonExecutable()
        let helperURL = try bridge.resolvedHelperScript()
        let root = PersistenceRoot.default()
        let bridgeDoctor: BridgeDoctorResponse = try bridge.run(
            command: "doctor",
            request: EmptyRequest(),
            as: BridgeDoctorResponse.self
        )

        print("status: ok")
        print("persistence_root: \(root.rootURL.path)")
        print("python: \(pythonURL.path)")
        print("bridge: \(helperURL.path)")
        print("bridge_python: \(bridgeDoctor.pythonExecutable)")
        print("mlx: \(bridgeDoctor.mlxVersion)")
        print("mlx_lm: \(bridgeDoctor.mlxLMVersion)")
        print("mlx_vlm: \(bridgeDoctor.mlxVLMVersion)")
        print("numpy: \(bridgeDoctor.numpyVersion)")
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
