import Foundation
import EshCore

/// One-time wiring of the macOS runtime into the portable core (M9).
///
/// EshCore is portable and references no macOS execution type. A few portable code paths defer to macOS
/// behavior through set-once hooks (`RoutingEngineProbe`, `CacheArtifactSupport`); this bootstrap fills
/// them with the concrete macOS implementations that live in EshMacRuntime. The macOS CLI (`esh`) calls
/// `MacRuntimeBootstrap.install()` once at startup, before routing or inference begins. iOS never links
/// this target, so the hooks stay `nil` there (the portable fallbacks apply).
public enum MacRuntimeBootstrap {
    /// Install the macOS hooks into EshCore. Idempotent; call once at process start.
    public static func install() {
        // Routing: detect installed optional generative engines via the macOS Python-engine manager.
        RoutingEngineProbe.isInstalled = { id, root in
            GenerativeEngineManager(root: root).isInstalled(GenerativeEngineCatalog.spec(id))
        }
        // Prompt-cache: the turbo (TurboQuant) compressor is a macOS subprocess-backed codec.
        CacheArtifactSupport.turboCompressorFactory = { TurboQuantCompressor() }
    }
}
