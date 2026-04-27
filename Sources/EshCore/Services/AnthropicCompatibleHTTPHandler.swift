import Foundation

public struct AnthropicCompatibleHTTPHandler: Sendable {
    private let service: AnthropicCompatibleService
    private let apiKey: String?

    public init(service: AnthropicCompatibleService, apiKey: String? = nil) {
        self.service = service
        self.apiKey = apiKey
    }

    public func handle(_ request: OpenAICompatibleHTTPRequest) async throws -> OpenAICompatibleHTTPResponse {
        do {
            try validateAuthorization(headers: request.headers)
            let path = normalizedPath(request.path)
            switch (request.method.uppercased(), path) {
            case ("GET", "/"), ("GET", "/health"), ("GET", "/v1"):
                return try jsonResponse(statusCode: 200, payload: ["status": "ok", "routes": "/v1/models,/v1/messages"])
            case ("GET", "/v1/models"):
                return try jsonResponse(statusCode: 200, payload: service.models())
            case ("POST", "/v1/messages"):
                let decoded = try JSONCoding.decoder.decode(AnthropicMessagesRequest.self, from: request.body)
                if decoded.stream == true {
                    let body = try await service.messagesStream(decoded)
                    return streamResponse(body: body)
                } else {
                    let response = try await service.messages(decoded)
                    return try jsonResponse(statusCode: 200, payload: response)
                }
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

    private func normalizedPath(_ path: String) -> String {
        guard let queryStart = path.firstIndex(of: "?") else {
            return path
        }
        return String(path[..<queryStart])
    }

    private func validateAuthorization(headers: [String: String]) throws {
        guard let apiKey, apiKey.isEmpty == false else { return }
        let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        let requestAPIKey = lowered["x-api-key"]
        let requestBearer = lowered["authorization"]
        if requestAPIKey == apiKey || requestBearer == "Bearer \(apiKey)" {
            return
        }
        throw OpenAICompatibleError.unauthorized
    }

    private func jsonResponse<T: Encodable>(statusCode: Int, payload: T) throws -> OpenAICompatibleHTTPResponse {
        let body = try JSONCoding.encoder.encode(payload)
        return OpenAICompatibleHTTPResponse(
            statusCode: statusCode,
            headers: [
                "access-control-allow-origin": "*",
                "access-control-allow-methods": "GET,POST,OPTIONS",
                "access-control-allow-headers": "authorization,content-type,x-api-key,anthropic-version,anthropic-beta",
                "content-type": "application/json; charset=utf-8",
                "content-length": String(body.count)
            ],
            body: body
        )
    }

    private func streamResponse(body: Data) -> OpenAICompatibleHTTPResponse {
        OpenAICompatibleHTTPResponse(
            statusCode: 200,
            headers: [
                "access-control-allow-origin": "*",
                "access-control-allow-methods": "GET,POST,OPTIONS",
                "access-control-allow-headers": "authorization,content-type,x-api-key,anthropic-version,anthropic-beta",
                "cache-control": "no-cache",
                "content-type": "text/event-stream; charset=utf-8",
                "content-length": String(body.count),
                "x-accel-buffering": "no"
            ],
            body: body
        )
    }

    private func errorResponse(for error: OpenAICompatibleError) -> OpenAICompatibleHTTPResponse {
        let statusCode: Int
        let errorType: String
        switch error {
        case .invalidRequest:
            statusCode = 400
            errorType = "invalid_request_error"
        case .unsupported:
            statusCode = 400
            errorType = "unsupported_error"
        case .notFound:
            statusCode = 404
            errorType = "not_found_error"
        case .methodNotAllowed:
            statusCode = 405
            errorType = "method_not_allowed"
        case .unauthorized:
            statusCode = 401
            errorType = "authentication_error"
        }
        let payload = AnthropicErrorResponse(
            type: "error",
            error: .init(type: errorType, message: error.localizedDescription)
        )
        let body = (try? JSONCoding.encoder.encode(payload)) ?? Data()
        return OpenAICompatibleHTTPResponse(
            statusCode: statusCode,
            headers: [
                "access-control-allow-origin": "*",
                "access-control-allow-methods": "GET,POST,OPTIONS",
                "access-control-allow-headers": "authorization,content-type,x-api-key,anthropic-version,anthropic-beta",
                "content-type": "application/json; charset=utf-8",
                "content-length": String(body.count)
            ],
            body: body
        )
    }
}
