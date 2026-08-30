import AppKit

enum RendererReadiness: String, Equatable, Sendable {
    case ready
    case fallback
    case failed
}

struct GlowRendererRuntimeState: Equatable, Sendable {
    var readiness: RendererReadiness
    var captureState: PhysicalCaptureState
    var fallbackReason: String?

    static let ready = GlowRendererRuntimeState(
        readiness: .ready,
        captureState: .idle,
        fallbackReason: nil
    )
}

struct EffectRuntimeStatus: Equatable, Sendable {
    var selectedEffect: EffectStyle
    var resolvedEffect: EffectStyle
    var rendererReadiness: RendererReadiness
    var captureState: PhysicalCaptureState
    var fallbackReason: String?
    var powerSavingMode: PowerSavingMode
    var powerEnvironmentState: PowerEnvironmentState
    var automaticPowerSavingIsActive: Bool
    var activeDisplayID: UInt32?
    var activeDisplayPersistentIDs: [String]
    var sampledStripHeight: Double?

    static let initial = EffectRuntimeStatus(
        selectedEffect: .classicGlow,
        resolvedEffect: .classicGlow,
        rendererReadiness: .ready,
        captureState: .idle,
        fallbackReason: nil,
        powerSavingMode: .automatic,
        powerEnvironmentState: .normal,
        automaticPowerSavingIsActive: false,
        activeDisplayID: nil,
        activeDisplayPersistentIDs: [],
        sampledStripHeight: nil
    )
}

/// Atomic rendering boundary shared by Classic Glow and the surface effects.
/// Interaction ordering, previews, displays, and persistence belong upstream.
@MainActor
protocol GlowRenderer: AnyObject {
    var view: NSView { get }
    var supportsConcurrentPhysicalTargets: Bool { get }

    func apply(_ configuration: RendererConfiguration)
    func show(_ target: GlowTarget)
    @discardableResult
    func refresh(_ id: GlowID) -> Bool
    func hide(_ id: GlowID)
    func clear()
    func setRuntimeStatusHandler(
        _ handler: (@MainActor (GlowRendererRuntimeState) -> Void)?
    )
}

extension GlowRenderer {
    var supportsConcurrentPhysicalTargets: Bool { false }

    func setRuntimeStatusHandler(
        _ handler: (@MainActor (GlowRendererRuntimeState) -> Void)?
    ) {
        handler?(.ready)
    }
}
