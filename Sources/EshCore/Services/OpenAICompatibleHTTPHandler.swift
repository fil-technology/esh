import Foundation

public struct OpenAICompatibleHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct OpenAICompatibleHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct OpenAICompatibleHTTPHandler: Sendable {
    private let service: OpenAICompatibleService
    private let bearerToken: String?

    public init(service: OpenAICompatibleService, bearerToken: String? = nil) {
        self.service = service
        self.bearerToken = bearerToken
    }

    public func handle(_ request: OpenAICompatibleHTTPRequest) async throws -> OpenAICompatibleHTTPResponse {
        do {
            try validateAuthorization(headers: request.headers)

            switch (request.method.uppercased(), request.path) {
            case ("GET", "/health"):
                return try jsonResponse(statusCode: 200, payload: ["status": "ok"])
            case ("GET", "/v1/models"):
                return try jsonResponse(statusCode: 200, payload: service.models())
            case ("GET", "/v1/audio/models"):
                return try jsonResponse(statusCode: 200, payload: service.audioModels())
            case ("POST", "/v1/chat/completions"):
                let decoded = try JSONCoding.decoder.decode(OpenAIChatCompletionsRequest.self, from: request.body)
                let response = try await service.chatCompletions(decoded)
                return try jsonResponse(statusCode: 200, payload: response)
            case ("POST", "/v1/responses"):
                let decoded = try JSONCoding.decoder.decode(OpenAIResponsesRequest.self, from: request.body)
                let response = try await service.responses(decoded)
                return try jsonResponse(statusCode: 200, payload: response)
            case ("GET", _), ("POST", _):
                throw OpenAICompatibleError.notFound("No route for \(request.method.uppercased()) \(request.path)")
            default:
                throw OpenAICompatibleError.methodNotAllowed("Unsupported method: \(request.method)")
            }
        } catch let error as OpenAICompatibleError {
            return errorResponse(for: error)
        } catch let error as DecodingError {
            return errorResponse(for: .invalidRequest("Invalid JSON request body: \(error.localizedDescription)"))
        } catch {
            return errorResponse(for: .invalidRequest(error.localizedDescription))
        }
    }

    private func validateAuthorization(headers: [String: String]) throws {
        guard let bearerToken, bearerToken.isEmpty == false else { return }
        let authorization = headers.first { $0.key.lowercased() == "authorization" }?.value
        guard authorization == "Bearer \(bearerToken)" else {
            throw OpenAICompatibleError.unauthorized
        }
    }

    private func jsonResponse<T: Encodable>(statusCode: Int, payload: T) throws -> OpenAICompatibleHTTPResponse {
        let body = try JSONCoding.encoder.encode(payload)
        return OpenAICompatibleHTTPResponse(
            statusCode: statusCode,
            headers: [
                "content-type": "application/json; charset=utf-8",
                "content-length": String(body.count)
            ],
            body: body
        )
    }

    private func errorResponse(for error: OpenAICompatibleError) -> OpenAICompatibleHTTPResponse {
        let statusCode: Int
        let type: String
        switch error {
        case .invalidRequest:
            statusCode = 400
            type = "invalid_request_error"
        case .unsupported:
            statusCode = 400
            type = "unsupported_error"
        case .notFound:
            statusCode = 404
            type = "not_found_error"
        case .methodNotAllowed:
            statusCode = 405
            type = "method_not_allowed"
        case .unauthorized:
            statusCode = 401
            type = "authentication_error"
        }
        let payload = OpenAIErrorResponse(error: .init(message: error.localizedDescription, type: type))
        let body = (try? JSONCoding.encoder.encode(payload)) ?? Data(#"{"error":{"message":"Unknown error","type":"server_error"}}"#.utf8)
        return OpenAICompatibleHTTPResponse(
            statusCode: statusCode,
            headers: [
                "content-type": "application/json; charset=utf-8",
                "content-length": String(body.count)
            ],
            body: body
        )
    }
}
