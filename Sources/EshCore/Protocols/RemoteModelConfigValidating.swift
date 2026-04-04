public protocol RemoteModelConfigValidating: Sendable {
    func validateRemoteConfig(jsonText: String) throws -> String?
}
