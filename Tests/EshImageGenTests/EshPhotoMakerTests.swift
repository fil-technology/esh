import Foundation
import Testing
import EshCore
import EshRuntime
@testable import EshImageGen

// Deterministic tests for the PhotoMaker identity tier of image.edit: provider descriptor/selection metadata,
// registry model-routing (Auto vs pinned tier), and the token-free, checksum-pinned self-hosted manifests.
// No MLX/Metal here — the real on-device behavior is the esh-level dogfood.

private struct MockEditProvider: CapabilityProvider, @unchecked Sendable {
    let descriptor: CapabilityProviderDescriptor
    init(id: String, family: String?, backend: RuntimeKind = .mlx) {
        descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.imageEdit], acceptedInputs: [.image, .text], producedOutputs: [.image],
            backend: backend, modelFamily: family, streaming: true, structuredOutput: false,
            requiredPrivilege: .artifactOnly, previewMode: .none)
    }
    func execute(_ r: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func unload() async {}
}

private func editReq(model: String?) -> ExecutionRequest {
    ExecutionRequest(capability: .imageEdit,
        inputs: [.attachment(EshAttachment(kind: .image, uri: "file:///x.png")), .text("3d")],
        output: OutputSpec(modality: .image, format: "image/png"), model: model)
}

@Suite struct EshPhotoMakerTests {
    @Test func editSizeKnobAndHonestResourceProfile() {
        // Default is SDXL-native 1024 (max quality). editSize is a speed/quality knob, not a memory lever —
        // a live sweep measured ~12.4 GB peak at both 1024 and 768.
        #expect(EshPhotoMaker.defaultEditSize == 1024)
        // Clamp: multiple of 8, within [512, 1024].
        #expect(EshPhotoMaker.clampedEditSize(768) == 768)
        #expect(EshPhotoMaker.clampedEditSize(1024) == 1024)
        #expect(EshPhotoMaker.clampedEditSize(2048) == 1024)   // capped
        #expect(EshPhotoMaker.clampedEditSize(256) == 512)     // floored
        #expect(EshPhotoMaker.clampedEditSize(700) == 696)     // snapped down to a multiple of 8
        // Advertised peak is the measured value (~12.4 GB) + small margin, not the old padded 14.
        #expect(EshPhotoMaker.resourceProfile.estimatedPeakMemoryGB == 13)
    }

    @Test func photoMakerProviderDescriptorIsNativeIdentityTier() {
        let ps = EshPhotoMaker.providers()
        #expect(ps.count == 1)
        let d = ps[0].descriptor
        #expect(d.id == "mlx-photomaker-v1")
        #expect(d.modelFamily == "photomaker-v1")
        #expect(d.capabilities == [.imageEdit])
        #expect(d.backend == .mlx && d.backend.isInProcess)
    }

    @Test func registryRoutesByPinnedModelElseNativeFirst() {
        var reg = CapabilityRegistry()
        reg.register(MockEditProvider(id: "mlx-instruct-image-edit", family: "instruct-pix2pix"))  // registered first
        reg.register(MockEditProvider(id: "mlx-photomaker-v1", family: "photomaker-v1"))
        // Auto (no pin): native-first order → the first-registered native provider leads.
        #expect(reg.candidates(for: editReq(model: nil)).first?.descriptor.id == "mlx-instruct-image-edit")
        // Pin the PhotoMaker identity tier by provider id.
        #expect(reg.candidates(for: editReq(model: "mlx-photomaker-v1")).map { $0.descriptor.id } == ["mlx-photomaker-v1"])
        // Pin by model family alias.
        #expect(reg.candidates(for: editReq(model: "photomaker-v1")).first?.descriptor.id == "mlx-photomaker-v1")
        // Pin the lightweight tier.
        #expect(reg.candidates(for: editReq(model: "mlx-instruct-image-edit")).first?.descriptor.id == "mlx-instruct-image-edit")
        // Unknown pin falls back to the native-first list (honest: not empty).
        #expect(reg.candidates(for: editReq(model: "nope")).count == 2)
    }

    @Test func photoMakerAndSDXLManifestsAreTokenFreeAndPinned() {
        let pm = SelfHostedModel.photoMakerV1()
        #expect(pm.modelID == "fil-technology/photomaker-v1")
        #expect(pm.baseURL.absoluteString.contains("releases/download/pmv1-weights-v1"))
        let pmFiles = Set(pm.files.map(\.relativePath))
        #expect(pmFiles == ["photomaker_id_encoder.safetensors", "photomaker_lora_compact.safetensors", "style_3d_lora_compact.safetensors"])
        #expect(pm.files.allSatisfy { $0.sha256 != nil })   // all three integrity-pinned

        let xl = SelfHostedModel.sdxlBase()
        #expect(xl.modelID == "stabilityai/stable-diffusion-xl-base-1.0")
        #expect(xl.baseURL.absoluteString.contains("/resolve/462165984030d82259a11f4367a4eed129e94a7b"))  // pinned revision
        let pinned = Set(xl.files.filter { $0.sha256 != nil }.map(\.relativePath))
        #expect(pinned == ["unet/diffusion_pytorch_model.fp16.safetensors", "text_encoder/model.fp16.safetensors",
                           "text_encoder_2/model.fp16.safetensors", "vae/diffusion_pytorch_model.fp16.safetensors"])
    }
}
