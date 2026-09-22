import Foundation
import EshCore

// First-class, discoverable image STYLE presets for the managed-Python image.edit path (rc.32). A style is a
// named, curated pairing of an edit backend + an optional style LoRA + a prompt, so a consumer (Esh Studio,
// the CLI) applies "3D animation" by name — `options["style"] = "3d-animation"` — instead of hard-coding a
// backend, a LoRA path, and prompt wording. This is exactly what esh-web's Imagine "3D animation" chip does
// under the hood (FLUX.2 Klein 4B + the Flux2_Klein_4B_3D2AI LoRA), now surfaced through the SDK.
//
// NOTE: this path runs the mflux edit engine as a managed-Python subprocess, so it is available to consumers
// that can run the managed runtime (the CLI / `esh web`, non-sandboxed hosts). App-Sandboxed Esh Studio, which
// cannot spawn Python, needs the native in-process route (tracked separately as the native FLUX.2 Klein port).

/// A named image-edit style: an edit backend + optional style LoRA + a curated prompt. `Codable`/`Hashable`
/// so it can be listed for discovery and carried in provenance.
public struct MacImageStyle: Sendable, Hashable, Codable, Identifiable {
    public let id: String              // stable slug, e.g. "3d-animation"
    public let displayName: String     // "3D Animation"
    public let backend: String         // mflux edit backend, e.g. "flux2-klein"
    public let loraRepoID: String?     // Hugging Face repo of the style LoRA, or nil for prompt-only styles
    public let loraFile: String?       // specific adapter file within the repo (nil = first .safetensors)
    public let loraScale: Double       // adapter strength
    public let promptTemplate: String  // curated instruction; the caller's own text is appended when present
    public let licenseIdentifier: String
    public let commercialUse: Bool

    public init(id: String, displayName: String, backend: String, loraRepoID: String?, loraFile: String?,
                loraScale: Double, promptTemplate: String, licenseIdentifier: String, commercialUse: Bool) {
        self.id = id; self.displayName = displayName; self.backend = backend
        self.loraRepoID = loraRepoID; self.loraFile = loraFile; self.loraScale = loraScale
        self.promptTemplate = promptTemplate
        self.licenseIdentifier = licenseIdentifier; self.commercialUse = commercialUse
    }

    /// Compose the final edit instruction from this style's curated prompt plus any caller-supplied text.
    public func composedInstruction(userText: String) -> String {
        let extra = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? promptTemplate : "\(promptTemplate). \(extra)"
    }
}

/// The built-in image-edit style catalog. Extensible: add presets here (or, later, load user/style packs).
public enum MacImageStyles {
    /// Premium 3D animated-feature look via FLUX.2 Klein 4B (Apache-2.0) + the Flux2_Klein_4B_3D2AI LoRA —
    /// identity-preserving, commercial-safe, and validated to fit a 32 GB Mac (~11 GB peak, no swap thrash).
    public static let threeDAnimation = MacImageStyle(
        id: "3d-animation",
        displayName: "3D Animation",
        backend: "flux2-klein",
        loraRepoID: "Latentiq/Flux2_Klein_4B_3D2AI_LoRA",
        loraFile: "Flux_Klein_4B_3D2AI_BF16_R16.safetensors",
        loraScale: 1.0,
        promptTemplate: "Turn this photo into a 3D animated movie still, premium Pixar-style 3D character "
            + "render, stylized smooth shading, big expressive eyes, soft rounded features, cinematic studio "
            + "lighting, subsurface scattering, high quality 3D animation",
        licenseIdentifier: "apache-2.0", commercialUse: true)

    /// All built-in styles, for discovery.
    public static func all() -> [MacImageStyle] { [threeDAnimation] }

    /// Look up a style by its stable id (case-insensitive), or nil.
    public static func byID(_ id: String) -> MacImageStyle? {
        let key = id.lowercased()
        return all().first { $0.id.lowercased() == key }
    }
}
