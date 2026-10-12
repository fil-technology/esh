import Foundation
import EshCore

// macOS MLX Python-bridge doctor (M9). The `MLXPackageDoctor` protocol and `MLXPackageDoctorReport` value
// type stay portable in EshCore/Domain/EngineStatus.swift; this concrete implementation drives the macOS-only
// `MLXBridge` (Python subprocess) and therefore lives in EshMacRuntime.
public struct BridgeMLXPackageDoctor: MLXPackageDoctor {
    private let bridge: MLXBridge

    public init(bridge: MLXBridge = .init()) {
        self.bridge = bridge
    }

    public func check() throws -> MLXPackageDoctorReport {
        let response: BridgeDoctorResponse = try bridge.run(
            command: "doctor",
            request: EmptyDoctorRequest(),
            as: BridgeDoctorResponse.self
        )
        return MLXPackageDoctorReport(
            pythonExecutable: response.pythonExecutable,
            mlxVersion: response.mlxVersion,
            mlxLMVersion: response.mlxLMVersion,
            mlxVLMVersion: response.mlxVLMVersion,
            numpyVersion: response.numpyVersion,
            safetensorsVersion: response.safetensorsVersion
        )
    }
}

private struct EmptyDoctorRequest: Codable {}

private struct BridgeDoctorResponse: Codable {
    var pythonExecutable: String
    var mlxVersion: String
    var mlxLMVersion: String
    var mlxVLMVersion: String
    var numpyVersion: String
    var safetensorsVersion: String
}
