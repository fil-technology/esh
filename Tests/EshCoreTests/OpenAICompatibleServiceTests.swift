import Foundation
import Testing
@testable import EshCore

@Suite
struct OpenAICompatibleServiceTests {
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
    func chatCompletionsMapsMessagesAndFormatsResponse() async throws {
        let requestData = Data(
            """
            {
              "model": "demo-model",
              "messages": [
                { "role": "system", "content": "Be concise." },
                { "role": "user", "content": "Hello there" }
              ],
              "temperature": 0.2,
              "max_completion_tokens": 64,
              "metadata": { "screen": "xcode" }
            }
            """.utf8
        )
        let request = try JSONCoding.decoder.decode(OpenAIChatCompletionsRequest.self, from: requestData)

        let capture = RequestCapture()
        let service = OpenAICompatibleService(
            infer: { externalRequest in
                await capture.store(externalRequest)
                return ExternalInferenceResponse(
                    modelID: externalRequest.model ?? "demo-model",
                    backend: .mlx,
                    integration: .init(mode: "direct"),
                    outputText: "Hi from esh",
                    metrics: .init(ttftMilliseconds: 12)
                )
            },
            installedModels: { [] }
        )

        let response = try await service.chatCompletions(request)
        let externalRequest = try #require(await capture.load())

        #expect(externalRequest.model == "demo-model")
        #expect(externalRequest.messages.map(\.role) == [.system, .user])
        #expect(externalRequest.messages.map(\.text) == ["Be concise.", "Hello there"])
        #expect(externalRequest.generation.maxTokens == 64)
        #expect(externalRequest.generation.temperature == 0.2)
        #expect(response.object == "chat.completion")
        #expect(response.model == "demo-model")
        #expect(response.choices.count == 1)
        #expect(response.choices.first?.message.role == "assistant")
        #expect(response.choices.first?.message.content == "Hi from esh")
    }

    @Test
    func responsesMapsStringInputAndFormatsResponse() async throws {
        let requestData = Data(
            """
            {
              "model": "demo-model",
              "input": "Explain caching in one sentence.",
              "max_output_tokens": 32,
              "temperature": 0.1,
              "reasoning": { "effort": "medium" }
            }
            """.utf8
        )
        let request = try JSONCoding.decoder.decode(OpenAIResponsesRequest.self, from: requestData)

        let capture = RequestCapture()
        let service = OpenAICompatibleService(
            infer: { externalRequest in
                await capture.store(externalRequest)
                return ExternalInferenceResponse(
                    modelID: externalRequest.model ?? "demo-model",
                    backend: .mlx,
                    integration: .init(mode: "direct"),
                    outputText: "Caching reuses prepared state to reduce repeated work.",
                    metrics: .init(tokensPerSecond: 42)
                )
            },
            installedModels: { [] }
        )

        let response = try await service.responses(request)
        let externalRequest = try #require(await capture.load())

        #expect(externalRequest.messages.count == 1)
        #expect(externalRequest.messages.first?.role == .user)
        #expect(externalRequest.messages.first?.text == "Explain caching in one sentence.")
        #expect(externalRequest.generation.maxTokens == 32)
        #expect(externalRequest.generation.temperature == 0.1)
        #expect(response.object == "response")
        #expect(response.model == "demo-model")
        #expect(response.outputText == "Caching reuses prepared state to reduce repeated work.")
        #expect(response.output.count == 1)
    }

    @Test
    func chatCompletionsIgnoresUnsupportedContentPartsWhenTextIsPresent() async throws {
        let requestData = Data(
            """
            {
              "model": "demo-model",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    { "type": "input_text", "text": "Describe " },
                    { "type": "input_image", "image_url": "file:///tmp/example.png" },
                    { "type": "text", "text": "this setup." }
                  ]
                }
              ]
            }
            """.utf8
        )
        let request = try JSONCoding.decoder.decode(OpenAIChatCompletionsRequest.self, from: requestData)

        let capture = RequestCapture()
        let service = OpenAICompatibleService(
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

        _ = try await service.chatCompletions(request)
        let externalRequest = try #require(await capture.load())
        #expect(externalRequest.messages.first?.text == "Describe this setup.")
    }

    @Test
    func handlerRoutesHealthModelsAndChatCompletions() async throws {
        let handler = OpenAICompatibleHTTPHandler(
            service: OpenAICompatibleService(
                infer: { externalRequest in
                    ExternalInferenceResponse(
                        modelID: externalRequest.model ?? "demo-model",
                        backend: .mlx,
                        integration: .init(mode: "direct"),
                        outputText: "server reply",
                        metrics: .init()
                    )
                },
                installedModels: {
                    [
                        .init(id: "b-model", displayName: "B", backend: .mlx, source: "local/b", variant: nil, runtimeVersion: nil, supportsDirectInference: true, supportsCacheBuild: true, supportsCacheLoad: true),
                        .init(id: "a-model", displayName: "A", backend: .gguf, source: "local/a", variant: nil, runtimeVersion: nil, supportsDirectInference: true, supportsCacheBuild: false, supportsCacheLoad: false)
                    ]
                },
                audioModels: {
                    [
                        .init(
                            id: "voice-model",
                            displayName: "Voice Model",
                            voices: [.init(id: "alba")],
                            languages: [.init(id: "en")]
                        )
                    ]
                }
            )
        )

        let health = try await handler.handle(.init(method: "GET", path: "/health", headers: [:], body: Data()))
        #expect(health.statusCode == 200)

        let models = try await handler.handle(.init(method: "GET", path: "/v1/models", headers: [:], body: Data()))
        let modelsPayload = try JSONCoding.decoder.decode(OpenAIModelsResponse.self, from: models.body)
        #expect(models.statusCode == 200)
        #expect(modelsPayload.data.map(\.id) == ["a-model", "b-model"])

        let queryModels = try await handler.handle(.init(method: "GET", path: "/v1/models?source=xcode", headers: [:], body: Data()))
        #expect(queryModels.statusCode == 200)

        let audioModels = try await handler.handle(.init(method: "GET", path: "/v1/audio/models", headers: [:], body: Data()))
        let audioPayload = try JSONCoding.decoder.decode(OpenAIAudioModelsResponse.self, from: audioModels.body)
        #expect(audioModels.statusCode == 200)
        #expect(audioPayload.data.first?.voices.first?.id == "alba")
        #expect(audioPayload.data.first?.languages.first?.id == "en")

        let tools = try await handler.handle(.init(method: "GET", path: "/v1/tools", headers: [:], body: Data()))
        let toolsPayload = try JSONCoding.decoder.decode(OpenAIToolsResponse.self, from: tools.body)
        #expect(tools.statusCode == 200)
        #expect(toolsPayload.supportsRequestTools)

        let tags = try await handler.handle(.init(method: "GET", path: "/api/tags", headers: [:], body: Data()))
        let tagsPayload = try JSONCoding.decoder.decode(OllamaTagsResponse.self, from: tags.body)
        #expect(tags.statusCode == 200)
        #expect(tagsPayload.models.map(\.name) == ["a-model", "b-model"])

        let chatRequestBody = Data(
            """
            {
              "model": "demo-model",
              "messages": [
                { "role": "user", "content": "hi" }
              ]
            }
            """.utf8
        )
        let chat = try await handler.handle(.init(method: "POST", path: "/v1/chat/completions", headers: ["content-type": "application/json"], body: chatRequestBody))
        let chatPayload = try JSONCoding.decoder.decode(OpenAIChatCompletionsResponse.self, from: chat.body)
        #expect(chat.statusCode == 200)
        #expect(chatPayload.choices.first?.message.content == "server reply")
    }

    @Test
    func handlerStreamsChatCompletions() async throws {
        let handler = OpenAICompatibleHTTPHandler(
            service: OpenAICompatibleService(
                infer: { externalRequest in
                    ExternalInferenceResponse(
                        modelID: externalRequest.model ?? "demo-model",
                        backend: .mlx,
                        integration: .init(mode: "direct"),
                        outputText: "stream reply",
                        metrics: .init()
                    )
                },
                installedModels: { [] }
            )
        )

        let requestBody = Data(
            """
            {
              "model": "demo-model",
              "messages": [
                { "role": "user", "content": "hi" }
              ],
              "stream": true
            }
            """.utf8
        )
        let response = try await handler.handle(.init(method: "POST", path: "/v1/chat/completions", headers: ["content-type": "application/json"], body: requestBody))
        let body = try #require(String(data: response.body, encoding: .utf8))

        #expect(response.statusCode == 200)
        #expect(response.headers["content-type"]?.contains("text/event-stream") == true)
        #expect(body.contains(#""object":"chat.completion.chunk""#))
        #expect(body.contains(#""content":"stream "#))
        #expect(body.contains(#""finish_reason":"stop""#))
        #expect(body.contains("data: [DONE]"))
    }

    @Test
    func handlerStreamsResponses() async throws {
        let handler = OpenAICompatibleHTTPHandler(
            service: OpenAICompatibleService(
                infer: { externalRequest in
                    ExternalInferenceResponse(
                        modelID: externalRequest.model ?? "demo-model",
                        backend: .mlx,
                        integration: .init(mode: "direct"),
                        outputText: "response stream reply",
                        metrics: .init()
                    )
                },
                installedModels: { [] }
            )
        )

        let requestBody = Data(
            """
            {
              "model": "demo-model",
              "input": "hi",
              "stream": true
            }
            """.utf8
        )
        let response = try await handler.handle(.init(method: "POST", path: "/v1/responses", headers: ["content-type": "application/json"], body: requestBody))
        let body = try #require(String(data: response.body, encoding: .utf8))

        #expect(response.statusCode == 200)
        #expect(response.headers["content-type"]?.contains("text/event-stream") == true)
        #expect(body.contains("event: response.created"))
        #expect(body.contains("event: response.output_text.delta"))
        #expect(body.contains("event: response.completed"))
        #expect(body.contains("data: [DONE]"))
    }
}
