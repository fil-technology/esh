import Foundation
import EshCore

enum CalibrateCommand {
    static func run(arguments: [String]) throws {
        let method = CommandSupport.optionalValue(flag: "--method", in: arguments) ?? "triattention"
        guard method == "triattention" else {
            throw StoreError.invalidManifest("Unsupported calibration method: \(method)")
        }

        let modelIdentifier = try CommandSupport.requiredValue(flag: "--model", in: arguments)
        let maxTokens = Int(CommandSupport.optionalValue(flag: "--max-tokens", in: arguments) ?? "4096") ?? 4096
        let calibrationFilePath = CommandSupport.optionalValue(flag: "--calibration-file", in: arguments)

        let root = PersistenceRoot.default()
        let modelStore = FileModelStore(root: root)
        let install = try CommandSupport.resolveInstall(identifier: modelIdentifier, modelStore: modelStore)
        let locator = TriAttentionCalibrationLocator(root: root)
        let outputURL = try locator.ensureDirectory(for: install.id)

        let bridge = MLXBridge()
        let response: TriAttentionCalibrationResponse = try bridge.run(
            command: "triattention-calibrate",
            request: TriAttentionCalibrationRequest(
                modelPath: install.installPath,
                outputPath: outputURL.path,
                calibrationFilePath: calibrationFilePath,
                maxTokens: maxTokens
            ),
            as: TriAttentionCalibrationResponse.self
        )

        print("method: \(method)")
        print("model: \(install.id)")
        print("output: \(response.outputPath)")
    }
}

private struct TriAttentionCalibrationRequest: Codable, Sendable {
    let modelPath: String
    let outputPath: String
    let calibrationFilePath: String?
    let maxTokens: Int
}

private struct TriAttentionCalibrationResponse: Codable, Sendable {
    let outputPath: String
}
