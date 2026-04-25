import Foundation
import Network

public final class OpenAICompatibleLocalServer: @unchecked Sendable {
    private enum HostMode {
        case loopback
        case any
    }

    private let listener: NWListener
    private let handler: OpenAICompatibleHTTPHandler
    private let hostMode: HostMode
    public let host: String
    public let port: UInt16
    private let queue = DispatchQueue(label: "esh.openai-server")

    public init(host: String, port: UInt16, handler: OpenAICompatibleHTTPHandler) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OpenAICompatibleError.invalidRequest("Invalid port: \(port)")
        }
        self.host = host
        self.port = port
        self.hostMode = try Self.resolveHostMode(host)
        self.listener = try NWListener(using: .tcp, on: nwPort)
        self.listener.service = nil
        self.handler = handler
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.start(connection: connection)
        }
        self.listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("error: server failed: \(error)\n", stderr)
            }
        }
    }

    public func start() {
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    private func start(connection: NWConnection) {
        connection.start(queue: queue)
        guard isEndpointAllowed(connection.endpoint) else {
            send(
                response: httpResponse(for: .unauthorized, messageOverride: "Loopback host only accepts local clients."),
                on: connection
            )
            return
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                fputs("error: connection receive failed: \(error)\n", stderr)
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            do {
                if let request = try self.parseRequest(from: accumulated) {
                    Task {
                        let response = (try? await self.handler.handle(request)) ?? OpenAICompatibleHTTPResponse(
                            statusCode: 500,
                            headers: ["content-type": "application/json; charset=utf-8"],
                            body: Data(#"{"error":{"message":"Internal server error","type":"server_error"}}"#.utf8)
                        )
                        self.send(response: response, on: connection)
                    }
                    return
                }
            } catch let error as OpenAICompatibleError {
                let response = self.httpResponse(for: error)
                self.send(response: response, on: connection)
                return
            } catch {
                let response = self.httpResponse(for: .invalidRequest(error.localizedDescription))
                self.send(response: response, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func send(response: OpenAICompatibleHTTPResponse, on connection: NWConnection) {
        let serialized = serialize(response: response)
        connection.send(content: serialized, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func parseRequest(from data: Data) throws -> OpenAICompatibleHTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw OpenAICompatibleError.invalidRequest("Request headers were not valid UTF-8.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw OpenAICompatibleError.invalidRequest("Missing HTTP request line.")
        }
        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else {
            throw OpenAICompatibleError.invalidRequest("Malformed HTTP request line.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.isEmpty == false {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let availableBodyLength = data.count - bodyStart
        guard availableBodyLength >= contentLength else {
            return nil
        }

        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        return OpenAICompatibleHTTPRequest(
            method: String(requestLineParts[0]),
            path: normalizedRequestPath(String(requestLineParts[1])),
            headers: headers,
            body: body
        )
    }

    private func normalizedRequestPath(_ path: String) -> String {
        guard let url = URL(string: path), url.path.isEmpty == false else {
            return path
        }
        if let query = url.query, query.isEmpty == false {
            return "\(url.path)?\(query)"
        }
        return url.path
    }

    private func serialize(response: OpenAICompatibleHTTPResponse) -> Data {
        let reasonPhrase = switch response.statusCode {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Internal Server Error"
        }

        var payload = Data("HTTP/1.1 \(response.statusCode) \(reasonPhrase)\r\n".utf8)
        var headers = response.headers
        headers["connection"] = "close"
        if headers["content-length"] == nil {
            headers["content-length"] = String(response.body.count)
        }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            payload.append(Data("\(name): \(value)\r\n".utf8))
        }
        payload.append(Data("\r\n".utf8))
        payload.append(response.body)
        return payload
    }

    private func httpResponse(for error: OpenAICompatibleError) -> OpenAICompatibleHTTPResponse {
        httpResponse(for: error, messageOverride: nil)
    }

    private func httpResponse(for error: OpenAICompatibleError, messageOverride: String?) -> OpenAICompatibleHTTPResponse {
        let errorType: String
        let statusCode: Int
        switch error {
        case .invalidRequest:
            errorType = "invalid_request_error"
            statusCode = 400
        case .unsupported:
            errorType = "unsupported_error"
            statusCode = 400
        case .unauthorized:
            errorType = "authentication_error"
            statusCode = 401
        case .notFound:
            errorType = "not_found_error"
            statusCode = 404
        case .methodNotAllowed:
            errorType = "method_not_allowed"
            statusCode = 405
        }

        let payload = OpenAIErrorResponse(
            error: .init(message: messageOverride ?? error.localizedDescription, type: errorType)
        )
        let body = (try? JSONCoding.encoder.encode(payload)) ?? Data()
        return OpenAICompatibleHTTPResponse(
            statusCode: statusCode,
            headers: [
                "content-type": "application/json; charset=utf-8",
                "content-length": String(body.count)
            ],
            body: body
        )
    }

    private func isEndpointAllowed(_ endpoint: NWEndpoint) -> Bool {
        switch hostMode {
        case .any:
            return true
        case .loopback:
            guard case .hostPort(let remoteHost, _) = endpoint else {
                return false
            }
            let remote = String(describing: remoteHost).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return remote == "127.0.0.1" || remote == "::1"
        }
    }

    private static func resolveHostMode(_ host: String) throws -> HostMode {
        switch host.lowercased() {
        case "127.0.0.1", "localhost", "::1":
            return .loopback
        case "0.0.0.0", "::":
            return .any
        default:
            throw OpenAICompatibleError.unsupported("Unsupported host `\(host)`. Use 127.0.0.1, localhost, ::1, 0.0.0.0, or ::.")
        }
    }
}
