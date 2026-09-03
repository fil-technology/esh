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
    /// When set, the server sends the headers then streams the body incrementally by calling this with
    /// a `write` callback per chunk (used for real SSE streaming); `body` is ignored in that case.
    public var bodyStream: (@Sendable (@escaping @Sendable (Data) -> Void) async -> Void)?

    public init(statusCode: Int, headers: [String: String], body: Data,
                bodyStream: (@Sendable (@escaping @Sendable (Data) -> Void) async -> Void)? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyStream = bodyStream
    }
}

public struct OpenAICompatibleHTTPHandler: Sendable {
    private let service: OpenAICompatibleService
    private let bearerToken: String?
    private let toolVersion: String?

    public init(service: OpenAICompatibleService, bearerToken: String? = nil, toolVersion: String? = nil) {
        self.service = service
        self.bearerToken = bearerToken
        self.toolVersion = toolVersion
    }

    public func handle(_ request: OpenAICompatibleHTTPRequest) async throws -> OpenAICompatibleHTTPResponse {
        do {
            try validateAuthorization(headers: request.headers)

            let path = normalizedPath(request.path)
            switch (request.method.uppercased(), path) {
            case ("OPTIONS", _):
                return emptyResponse(statusCode: 204)
            case ("GET", "/"), ("GET", "/health"), ("GET", "/v1"):
                return try jsonResponse(
                    statusCode: 200,
                    payload: [
                        "status": "ok",
                        "routes": "/web,/v1/models,/v1/chat/completions,/v1/responses,/v1/tools,/v1/audio/models,/v1/audio/speech,/v1/audio/transcriptions,/api/tags"
                    ]
                )
            case ("GET", "/web"), ("GET", "/chat"):
                return htmlResponse(WebChatPage.html(toolVersion: toolVersion))
            case ("GET", "/v1/models"):
                return try jsonResponse(statusCode: 200, payload: service.models())
            case ("GET", "/v1/audio/models"):
                return try jsonResponse(statusCode: 200, payload: service.audioModels())
            case ("POST", "/v1/audio/speech"):
                let decoded = try JSONCoding.decoder.decode(OpenAIAudioSpeechRequest.self, from: request.body)
                let response = try await service.audioSpeech(decoded)
                return binaryResponse(
                    statusCode: 200,
                    contentType: response.contentType,
                    filename: response.filename,
                    body: response.audioData,
                    extraHeaders: [
                        "x-esh-audio-model": response.modelID,
                        "x-esh-audio-sample-rate": "\(response.sampleRate)"
                    ]
                )
            case ("POST", "/v1/audio/transcriptions"):
                let decoded = try JSONCoding.decoder.decode(OpenAIAudioTranscriptionRequest.self, from: request.body)
                let response = try await service.audioTranscription(decoded)
                return try jsonResponse(statusCode: 200, payload: response)
            // 2.0 Web Experience data endpoints — thin JSON over the canonical services.
            case ("GET", "/v1/engine"), ("GET", "/v1/schedule"), ("GET", "/v1/catalog"),
                 ("GET", "/v1/config"), ("GET", "/v1/doctor"), ("GET", "/v1/onboarding"),
                 ("GET", "/v1/capability-models"),
                 ("POST", "/v1/config"),
                 ("POST", "/v1/models/install"), ("GET", "/v1/models/install"),
                 ("POST", "/v1/models/install/cancel"):
                let data = try await service.webData(WebDataRequest(
                    method: request.method.uppercased(), path: path,
                    query: queryItems(from: request.path), body: request.body))
                return jsonDataResponse(data)
            case ("GET", let p) where p.hasPrefix("/v1/catalog/"):
                let data = try await service.webData(WebDataRequest(
                    method: "GET", path: p, query: queryItems(from: request.path), body: request.body))
                return jsonDataResponse(data)
            case ("GET", "/v1/tools"):
                return try jsonResponse(statusCode: 200, payload: service.tools())
            case ("GET", "/api/tags"):
                return try jsonResponse(statusCode: 200, payload: service.ollamaTags())
            case ("POST", "/v1/chat/completions"):
                let decoded = try JSONCoding.decoder.decode(OpenAIChatCompletionsRequest.self, from: request.body)
                if decoded.stream == true {
                    // Real incremental SSE when streaming inference is wired; else buffered fallback.
                    if let provider = service.chatCompletionsStreamProvider(decoded) {
                        return streamingResponse(provider: provider)
                    }
                    let body = try await service.chatCompletionsStream(decoded)
                    return streamResponse(body: body)
                } else {
                    let response = try await service.chatCompletions(decoded)
                    return try jsonResponse(statusCode: 200, payload: response)
                }
            case ("POST", "/v1/responses"):
                let decoded = try JSONCoding.decoder.decode(OpenAIResponsesRequest.self, from: request.body)
                if decoded.stream == true {
                    let body = try await service.responsesStream(decoded)
                    return streamResponse(body: body)
                } else {
                    let response = try await service.responses(decoded)
                    return try jsonResponse(statusCode: 200, payload: response)
                }
            // UCMR (2.1): additive capability endpoints. All v2.0 routes above are unchanged.
            case ("POST", "/v1/execute"):
                let decoded = try JSONCoding.decoder.decode(ExecutionRequest.self, from: request.body)
                let result = try await service.execute(decoded)
                return try jsonResponse(statusCode: 200, payload: result)
            case ("POST", "/v1/route"):
                let decoded = try JSONCoding.decoder.decode(RouteHTTPRequest.self, from: request.body)
                let decision = try await service.route(message: decoded.message, attachments: decoded.attachments ?? [], conversationID: decoded.conversationID)
                return try jsonResponse(statusCode: 200, payload: decision)
            case ("POST", "/v1/route/resume"):
                let decoded = try JSONCoding.decoder.decode(RouteResumeHTTPRequest.self, from: request.body)
                let decision = try await service.resumeRoute(pendingId: decoded.pendingId, conversationID: decoded.conversationID)
                return try jsonResponse(statusCode: 200, payload: decision)
            case ("POST", "/v1/route/benchmark"):
                let mode = queryItems(from: request.path)["mode"] ?? "hybrid"
                let data = try await service.routeBenchmark(mode: mode)
                return jsonDataResponse(data)
            case ("POST", "/v1/route/benchmark/detail"):
                let mode = queryItems(from: request.path)["mode"] ?? "apple"
                let data = try await service.routeBenchmarkDetail(mode: mode)
                return jsonDataResponse(data)
            case ("GET", let p) where p.hasPrefix("/v1/artifacts/"):
                let rest = String(p.dropFirst("/v1/artifacts/".count))
                let comps = rest.split(separator: "/", maxSplits: 1).map(String.init)
                guard let first = comps.first, let id = UUID(uuidString: first) else {
                    throw OpenAICompatibleError.invalidRequest("Invalid artifact id in \(p)")
                }
                let file = comps.count > 1 ? comps[1] : nil
                guard let bytes = try await service.artifactBytes(id: id, file: file) else {
                    throw OpenAICompatibleError.notFound("Artifact not found: \(p)")
                }
                // Inline so previewable artifacts (SVG/image) render directly; still fine for download.
                return binaryResponse(statusCode: 200, contentType: bytes.mimeType, filename: bytes.filename,
                                      body: bytes.data,
                                      extraHeaders: ["content-disposition": #"inline; filename="\#(bytes.filename)""#])
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
            headers: jsonHeaders(contentLength: body.count),
            body: body
        )
    }

    /// Wrap already-encoded JSON `Data` (from the web-data provider) in a 200 response.
    private func jsonDataResponse(_ body: Data) -> OpenAICompatibleHTTPResponse {
        OpenAICompatibleHTTPResponse(statusCode: 200, headers: jsonHeaders(contentLength: body.count), body: body)
    }

    /// Parse `?a=b&c=d` query items from a raw request path (percent-decoded).
    private func queryItems(from rawPath: String) -> [String: String] {
        guard let q = rawPath.firstIndex(of: "?") else { return [:] }
        let query = rawPath[rawPath.index(after: q)...]
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = value
        }
        return out
    }

    /// A streaming SSE response: the server sends headers, then writes chunks from `provider` as they
    /// arrive (no content-length; the connection closes at the end).
    private func streamingResponse(
        provider: @escaping @Sendable (@escaping @Sendable (Data) -> Void) async -> Void
    ) -> OpenAICompatibleHTTPResponse {
        OpenAICompatibleHTTPResponse(
            statusCode: 200,
            headers: [
                "content-type": "text/event-stream; charset=utf-8",
                "cache-control": "no-cache",
                "connection": "close"
            ],
            body: Data(),
            bodyStream: provider
        )
    }

    private func htmlResponse(_ html: String) -> OpenAICompatibleHTTPResponse {
        let body = Data(html.utf8)
        return OpenAICompatibleHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": WebChatPage.contentType, "Content-Length": "\(body.count)"],
            body: body
        )
    }

    private func streamResponse(body: Data) -> OpenAICompatibleHTTPResponse {
        OpenAICompatibleHTTPResponse(
            statusCode: 200,
            headers: streamHeaders(contentLength: body.count),
            body: body
        )
    }

    private func binaryResponse(
        statusCode: Int,
        contentType: String,
        filename: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) -> OpenAICompatibleHTTPResponse {
        var headers = [
            "access-control-allow-origin": "*",
            "access-control-allow-methods": "GET,POST,OPTIONS",
            "access-control-allow-headers": "authorization,content-type",
            "content-type": contentType,
            "content-length": String(body.count),
            "content-disposition": #"attachment; filename="\#(filename)""#
        ]
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        return OpenAICompatibleHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private func emptyResponse(statusCode: Int) -> OpenAICompatibleHTTPResponse {
        OpenAICompatibleHTTPResponse(
            statusCode: statusCode,
            headers: [
                "access-control-allow-origin": "*",
                "access-control-allow-methods": "GET,POST,OPTIONS",
                "access-control-allow-headers": "authorization,content-type",
                "content-length": "0"
            ],
            body: Data()
        )
    }

    private func jsonHeaders(contentLength: Int) -> [String: String] {
        [
            "access-control-allow-origin": "*",
            "access-control-allow-methods": "GET,POST,OPTIONS",
            "access-control-allow-headers": "authorization,content-type",
            "content-type": "application/json; charset=utf-8",
            "content-length": String(contentLength)
        ]
    }

    private func streamHeaders(contentLength: Int) -> [String: String] {
        [
            "access-control-allow-origin": "*",
            "access-control-allow-methods": "GET,POST,OPTIONS",
            "access-control-allow-headers": "authorization,content-type",
            "cache-control": "no-cache",
            "content-type": "text/event-stream; charset=utf-8",
            "content-length": String(contentLength),
            "x-accel-buffering": "no"
        ]
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
            headers: jsonHeaders(contentLength: body.count),
            body: body
        )
    }
}
