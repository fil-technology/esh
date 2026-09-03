import Foundation
import Testing
@testable import EshCore

@Suite
struct CapabilityContractTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test
    func capabilityIDParsesFamilyAndVerb() {
        #expect(CapabilityID.languageGenerate.family == "language")
        #expect(CapabilityID.languageGenerate.verb == "generate")
        #expect(CapabilityID.audioSynthesizeSpeech.rawValue == "audio.synthesizeSpeech")
        // No dot → whole string is the family, verb empty.
        let bare: CapabilityID = "custom"
        #expect(bare.family == "custom")
        #expect(bare.verb == "")
        // Dotted verb keeps the remainder.
        let nested: CapabilityID = "image.edit.inpaint"
        #expect(nested.family == "image")
        #expect(nested.verb == "edit.inpaint")
    }

    @Test
    func capabilityIDIsStringLiteralAndCodable() throws {
        let id: CapabilityID = "vector.generate"
        #expect(id == CapabilityID.vectorGenerate)
        #expect(try roundTrip(id) == id)
    }

    @Test
    func executionRequestRoundTripsWithMixedInputs() throws {
        let req = ExecutionRequest(
            capability: .imageUnderstand,
            inputs: [
                .text("What is in this picture?", role: "question"),
                .attachment(EshAttachment(kind: .image, mimeType: "image/png", uri: "/tmp/x.png")),
                .init(payload: .structured(.object(["k": .string("v")]))),
                .init(payload: .embedding([0.1, 0.2, 0.3]))
            ],
            output: .text,
            constraints: ExecutionConstraints(localOnly: true, quality: .balanced, maxPrivilege: .validated),
            options: ExecutionOptions(["maxTokens": .int(256)]),
            model: "some-vlm"
        )
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(ExecutionRequest.self, from: data)
        #expect(back.schemaVersion == ExecutionRequest.currentSchemaVersion)
        #expect(back.capability == .imageUnderstand)
        #expect(back.inputs.count == 4)
        #expect(back.output.modality == .text)
        #expect(back.constraints.quality == .balanced)
        #expect(back.constraints.maxPrivilege == .validated)
        #expect(back.model == "some-vlm")
        // The typed input payloads survive the round trip.
        if case .text(let t) = back.inputs[0].payload { #expect(t == "What is in this picture?") } else { Issue.record("input 0 not text") }
        if case .attachment(let a) = back.inputs[1].payload { #expect(a.kind == .image) } else { Issue.record("input 1 not attachment") }
        if case .embedding(let v) = back.inputs[3].payload { #expect(v == [0.1, 0.2, 0.3]) } else { Issue.record("input 3 not embedding") }
    }

    @Test
    func outputSpecConstants() {
        #expect(OutputSpec.svg.modality == .image)
        #expect(OutputSpec.svg.format == "image/svg+xml")
        #expect(OutputSpec.embedding.modality == .embedding)
        #expect(OutputSpec.text.modality == .text)
    }

    @Test
    func artifactRoundTrips() throws {
        let art = Artifact(
            kind: .svg,
            mimeType: "image/svg+xml",
            files: [ArtifactFile(relativePath: "art.svg", byteSize: 128, sha256: "abc")],
            metadata: ["width": .int(64), "height": .int(64)],
            generatedBy: ArtifactProvenance(providerID: "svg-ir", capability: .vectorGenerate),
            validation: .valid,
            preview: .staticSandbox
        )
        let back = try roundTrip(art)
        #expect(back.kind == .svg)
        #expect(back.mimeType == "image/svg+xml")
        #expect(back.files.first?.byteSize == 128)
        #expect(back.validation.isValid)
        #expect(back.preview.mode == .staticSandbox)
        #expect(back.preview.privilege == .artifactOnly)
        #expect(back.totalByteSize == 128)
    }

    @Test
    func executionResultCarriesTextAndOutputs() throws {
        let result = ExecutionResult(
            capability: .vectorGenerate,
            text: nil,
            outputs: [Artifact(kind: .svg, mimeType: "image/svg+xml")]
        )
        let back = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ExecutionResult.self, from: back)
        #expect(decoded.schemaVersion == ExecutionResult.currentSchemaVersion)
        #expect(decoded.capability == .vectorGenerate)
        #expect(decoded.outputs.count == 1)
        #expect(decoded.outputs.first?.kind == .svg)
    }

    @Test
    func privilegeLevelOrdersLeastToMost() {
        #expect(PrivilegeLevel.artifactOnly < .validated)
        #expect(PrivilegeLevel.validated < .previewSandboxed)
        #expect(PrivilegeLevel.previewSandboxed < .explicitFull)
        #expect([PrivilegeLevel.explicitFull, .artifactOnly, .previewSandboxed].min() == .artifactOnly)
    }
}
