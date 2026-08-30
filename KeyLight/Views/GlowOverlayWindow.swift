import AppKit

/// Transparent overlay window that displays at the bottom of the screen.
@MainActor
final class GlowOverlayWindow: NSPanel {

    private var classicGlowView: GlowView?
    private var systemGlassRenderer: (any GlowRenderer)?
    private var physicalRefractionRenderer: (any GlowRenderer)?
    private var solidBlackRenderer: (any GlowRenderer)?
    private var activeRenderer: (any GlowRenderer)?
    private var activeEffectStyle: EffectStyle?
    private var activePhysicalCaptureAccess = false
    private let screenCaptureAccessProvider: @MainActor () -> Bool

    init(
        contentRect: NSRect,
        screenCaptureAccessProvider: @escaping @MainActor () -> Bool = {
            ScreenCaptureAuthorization.isGranted
        }
    ) {
        self.screenCaptureAccessProvider = screenCaptureAccessProvider
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        configureWindow()
    }

    private func configureWindow() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        level = .statusBar
        ignoresMouseEvents = true
        setAccessibilityElement(false)
        setAccessibilityChildren([])

        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        setEffectStyle(.classicGlow)
    }

    var glowRenderer: (any GlowRenderer)? {
        activeRenderer
    }

    func setEffectStyle(_ requestedStyle: EffectStyle) {
        let resolvedStyle = requestedStyle.supportedStyle.resolvedForCurrentSystem
        let physicalCaptureAccess = resolvedStyle == .physicalRefraction
            && screenCaptureAccessProvider()
        guard activeEffectStyle != resolvedStyle
                || activeRenderer == nil
                || activePhysicalCaptureAccess != physicalCaptureAccess else {
            return
        }

        activeRenderer?.clear()

        let renderer: any GlowRenderer
        switch resolvedStyle {
        case .classicGlow:
            renderer = classicRenderer()
        case .classicPlus:
            renderer = classicRenderer()
        case .liquidGlass:
            renderer = systemGlassRendererIfAvailable() ?? classicRenderer()
        case .systemGlass:
            renderer = systemGlassRendererIfAvailable() ?? classicRenderer()
        case .physicalRefraction:
            renderer = physicalCaptureAccess
                ? (physicalRefractionRendererIfAvailable() ?? classicRenderer())
                : (systemGlassRendererIfAvailable() ?? classicRenderer())
        case .solidBlack:
            renderer = solidBlackRendererIfAvailable() ?? classicRenderer()
        }

        renderer.view.frame = contentLayoutRect
        renderer.view.autoresizingMask = [.width, .height]
        renderer.view.setAccessibilityElement(false)
        renderer.view.setAccessibilityChildren([])
        contentView = renderer.view
        activeRenderer = renderer
        activeEffectStyle = resolvedStyle
        activePhysicalCaptureAccess = physicalCaptureAccess
    }

    private func physicalRefractionRendererIfAvailable() -> (any GlowRenderer)? {
        if let physicalRefractionRenderer {
            return physicalRefractionRenderer
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let view = LiquidGlassGlowView(
                frame: contentLayoutRect,
                presentationMode: .physicalRefraction
            )
            view.autoresizingMask = [.width, .height]
            physicalRefractionRenderer = view
            return view
        }
        #endif

        return nil
    }

    private func systemGlassRendererIfAvailable() -> (any GlowRenderer)? {
        if let systemGlassRenderer {
            return systemGlassRenderer
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let view = LiquidGlassGlowView(
                frame: contentLayoutRect,
                presentationMode: .systemGlass
            )
            view.autoresizingMask = [.width, .height]
            systemGlassRenderer = view
            return view
        }
        #endif

        return nil
    }

    private func classicRenderer() -> GlowView {
        if let classicGlowView {
            return classicGlowView
        }
        let view = GlowView(frame: contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        classicGlowView = view
        return view
    }

    private func solidBlackRendererIfAvailable() -> (any GlowRenderer)? {
        if let solidBlackRenderer {
            return solidBlackRenderer
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let view = LiquidGlassGlowView(
                frame: contentLayoutRect,
                presentationMode: .solidBlack
            )
            view.autoresizingMask = [.width, .height]
            solidBlackRenderer = view
            return view
        }
        #endif

        return nil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
