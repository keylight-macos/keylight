import AppKit

/// Transparent overlay window that displays at the bottom of the screen
@MainActor
final class GlowOverlayWindow: NSPanel {

    private var _glowView: GlowView?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true  // Defer to avoid layout during init
        )

        configureWindow()
    }

    private func configureWindow() {
        // Transparent background
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Float above most windows
        level = .statusBar

        // Click-through - mouse events pass to windows below
        ignoresMouseEvents = true

        // Visible on all Spaces and over fullscreen apps
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        // Setup content view after window is configured
        let view = GlowView(frame: contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        _glowView = view
        contentView = view
    }

    /// Access the glow view for showing/hiding effects
    var glowView: GlowView? {
        _glowView
    }

    // Prevent window from becoming key or main
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
