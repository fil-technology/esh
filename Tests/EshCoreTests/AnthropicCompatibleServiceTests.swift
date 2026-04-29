import Foundation
import Testing
@testable import EshCore

@Suite
struct AnthropicCompatibleServiceTests {
    actor RequestCapture {
        private var request: ExternalInferenceRequest?

        func store(_ request: ExternalInferenceRequest) {
            self.request = request
        }

        func load() -> ExternalInferenceRequest? {
            request
        }
    }

    @Test
    func messagesMapsSystemAndUserContentIntoExternalInference() async throws {
        let requestData = Data(
            """
            {
              "model": "demo-model",
              "system": "Be concise.",
              "max_tokens": 64,
              "temperature": 0.3,
              "top_p": 0.95,
              "top_k": 40,
              "messages": [
                {
                  "role": "user",
                  "content": [
                    { "type": "text", "text": "Explain local inference." }
                  ]
                }
              ]
            }
            """.utf8
        )
        let request = try JSONCoding.decoder.decode(AnthropicMessagesRequest.self, from: requestData)

        let capture = RequestCapture()
        let service = AnthropicCompatibleService(
            infer: { externalRequest in
                await capture.store(externalRequest)
                return ExternalInferenceResponse(
                    modelID: externalRequest.model ?? "demo-model",
                    backend: .mlx,
                    integration: .init(mode: "direct"),
                    outputText: "Local inference runs the model on your machine.",
                    metrics: .init(contextTokens: 18, ttftMilliseconds: 8, tokensPerSecond: 42)
                )
            },
            installedModels: { [] }
        )

        let response = try await service.messages(request)
        let external = try #require(await capture.load())

        #expect(external.model == "demo-model")
        #expect(external.generation.maxTokens == 64)
        #expect(external.generation.temperature == 0.3)
        #expect(external.generation.topP == 0.95)
        #expect(external.generation.topK == 40)
        #expect(external.messages.map(\.role) == [.system, .user])
        #expect(external.messages.map(\.text) == ["Be concise.", "Explain local inference."])
        #expect(response.type == "message")
        #expect(response.role == "assistant")
        #expect(response.model == "demo-model")
        #expect(response.content.first?.text == "Local inference runs the model on your machine.")
    }

    @Test
    func messageStreamEmitsAnthropicSSESequence() async throws {
        let service = AnthropicCompatibleService(
            infer: { _ in
                ExternalInferenceResponse(
                    modelID: "demo-model",
                    backend: .mlx,
                    integration: .init(mode: "direct"),
                    outputText: "Hello from esh",
                    metrics: .init(contextTokens: 12, ttftMilliseconds: 5)
                )
            },
            installedModels: { [] }
        )

        let body = try await service.messagesStream(.init(
            model: "demo-model",
            messages: [.init(role: "user", content: .text("hi"))],
            maxTokens: 32,
            stream: true
        ))
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.contains("event: message_start"))
        #expect(text.contains("event: content_block_start"))
        #expect(text.contains("event: content_block_delta"))
        #expect(text.contains("\"type\":\"text_delta\""))
        #expect(text.contains("event: content_block_stop"))
        #expect(text.contains("event: message_delta"))
        #expect(text.contains("event: message_stop"))
    }

    @Test
    func messagesIgnoresNonTextContentParts() async throws {
        let requestData = Data(
            """
            {
              "model": "demo-model",
              "max_tokens": 32,
              "messages": [
                {
                  "role": "user",
                  "content": [
                    { "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": "AA==" } }
                  ]
                }
              ]
            }
            """.utf8
        )
        let request = try JSONCoding.decoder.decode(AnthropicMessagesRequest.self, from: requestData)

        let capture = RequestCapture()
        let service = AnthropicCompatibleService(
            infer: { externalRequest in
                await capture.store(externalRequest)
                return ExternalInferenceResponse(
                    modelID: "demo-model",
                    backend: .mlx,
                    integration: .init(mode: "direct"),
                    outputText: "done",
                    metrics: .init()
                )
            },
            installedModels: { [] }
        )

        _ = try await service.messages(request)
        let external = try #require(await capture.load())
        #expect(external.messages.map(\.text) == [""])
    }

    @Test
    func handlerRoutesModelsAndMessages() async throws {
        let handler = AnthropicCompatibleHTTPHandler(
            service: AnthropicCompatibleService(
                infer: { externalRequest in
                    ExternalInferenceResponse(
                        modelID: externalRequest.model ?? "demo-model",
                        backend: .mlx,
                        integration: .init(mode: "direct"),
                        outputText: "Anthropic route ok",
                        metrics: .init(contextTokens: 5)
                    )
                },
                installedModels: {
                    [
                        .init(
                            id: "demo-model",
                            displayName: "Demo Model",
                            backend: .mlx,
                            source: "local/demo",
                            variant: nil,
                            runtimeVersion: nil,
                            supportsDirectInference: true,
                            supportsCacheBuild: true,
                            supportsCacheLoad: true
                        )
                    ]
                }
            ),
            apiKey: "esh-key"
        )

        let models = try await handler.handle(.init(method: "GET", path: "/v1/models", headers: ["x-api-key": "esh-key"], body: Data()))
        #expect(models.statusCode == 200)
        let modelsPayload = try JSONCoding.decoder.decode(AnthropicModelsResponse.self, from: models.body)
        #expect(modelsPayload.data.map(\.id) == ["demo-model"])

        let requestBody = Data(
            """
            {
              "model": "demo-model",
              "max_tokens": 32,
              "messages": [
                { "role": "user", "content": "Hello" }
              ]
            }
            """.utf8
        )
        let response = try await handler.handle(.init(
            method: "POST",
            path: "/v1/messages",
            headers: [
                "x-api-key": "esh-key",
                "anthropic-version": "2023-06-01"
            ],
            body: requestBody
        ))

        #expect(response.statusCode == 200)
        let payload = try JSONCoding.decoder.decode(AnthropicMessageResponse.self, from: response.body)
        #expect(payload.content.first?.text == "Anthropic route ok")
    }
}
