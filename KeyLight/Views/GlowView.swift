import AppKit
import QuartzCore

// MARK: - Fade-Out Completion Delegate

/// Reliably detects whether a fade-out animation completed naturally (finished: true)
/// or was cancelled by a new keypress (finished: false).
private final class FadeOutDelegate: NSObject, CAAnimationDelegate {
    let onComplete: (Bool) -> Void
    init(onComplete: @escaping (Bool) -> Void) {
        self.onComplete = onComplete
    }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        onComplete(flag)
    }
}

// MARK: - GlowView

/// View that renders smooth, blurry glow effects at the bottom edge.
/// Uses a single persistent glow layer that slides between key positions.
@MainActor
final class GlowView: NSView {

    // MARK: - Single Glow State

    /// The single persistent glow layer (lazily created)
    private var glowLayer: CALayer? = nil

    /// Keys currently held down
    private var heldKeys: Set<UInt16> = []

    /// Timestamps for each held key (for stale key detection)
    private var keyTimestamps: [UInt16: CFTimeInterval] = [:]

    /// Maximum time a key can stay in heldKeys without being refreshed (seconds)
    private let staleKeyThreshold: CFTimeInterval = 0.5

    /// The keyCode the glow is currently targeting
    private var currentTargetKeyCode: UInt16? = nil

    /// Current glow position (0.0-1.0 horizontal)
    private var currentPosition: CGFloat = 0

    /// Current glow key width
    private var currentKeyWidth: CGFloat = 1.0

    /// Whether the glow is currently visible (opacity > 0).
    /// True from fade-in start, false only when fade-out naturally completes.
    private var glowIsAlive: Bool = false

    /// Duration for the slide animation between key positions
    private let slideDuration: CFTimeInterval = 0.07
    private let popInDuration: CFTimeInterval = 0.08
    private let popStartHeightFraction: CGFloat = 0.27

    // MARK: - Pre-computed Timing

    private let easeOutTiming = CAMediaTimingFunction(name: .easeOut)

    // MARK: - Color Cache

    private var cachedColorArrays: [[CGColor]] = []
    private var colorCacheValid = false

    // MARK: - Configurable Settings

    var glowColor: NSColor = NSColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1.0) {
        didSet { colorCacheValid = false }
    }
    var baseKeyWidth: CGFloat = 60
    var glowHeight: CGFloat = 60
    var widthMultiplier: CGFloat = 1.0
    var maxOpacity: Float = 0.7
    var fadeOutDuration: CFTimeInterval = 1.5
    var glowRoundness: CGFloat = 1.0
    var glowFullness: CGFloat = 0.5 {
        didSet { colorCacheValid = false }
    }
    var colorResolver: ((CGFloat) -> NSColor)? = nil

    private let edgeEmergenceFraction: CGFloat = 0.5
    private let baseVerticalInset: CGFloat = 2.0
    private let halfEllipseKappa: CGFloat = 0.552_284_749_8
    private let hybridMixExponent: CGFloat = 1.25

    /// Effective rendered height for the flat glow body.
    /// Baseline: glowHeight=60 maps to legacy flat height=14.
    private var flatGlowHeight: CGFloat {
        max(4.0, glowHeight * (14.0 / 60.0))
    }

    private let blurSteps = 11
    private var alphaNormalization: CGFloat { 5.0 / CGFloat(blurSteps) }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshGlowLayerForDisplayScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshGlowLayerForDisplayScale()
    }

    // MARK: - Public API

    func showGlow(at horizontalPosition: CGFloat, keyCode: UInt16, keyWidth: CGFloat) {
        // Purge stale keys that may have missed their keyUp event
        purgeStaleKeys()

        // Update timestamp for this key
        keyTimestamps[keyCode] = CACurrentMediaTime()

        // Key repeat: same key firing again while held — just keep it alive
        if heldKeys.contains(keyCode) && currentTargetKeyCode == keyCode {
            let container = ensureGlowLayer()
            // Only intervene if something is wrong (e.g. a fade-out snuck in).
            // Otherwise leave the layer alone to avoid disrupting animations.
            if container.opacity != maxOpacity && container.animation(forKey: "fadeOut") != nil {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                container.removeAllAnimations()
                container.opacity = maxOpacity
                CATransaction.commit()
            }
            glowIsAlive = true
            return
        }

        heldKeys.insert(keyCode)
        currentTargetKeyCode = keyCode

        let container = ensureGlowLayer()

        if glowIsAlive {
            // CASE A: Glow is still visible — slide to new position

            // 1. Capture current visual state from presentation layer
            let presentationPosition = container.presentation()?.position ?? container.position
            let presentationBounds = container.presentation()?.bounds ?? container.bounds
            let presentationOpacity = container.presentation()?.opacity ?? container.opacity

            // 2. Cancel all in-progress animations (fade-out, previous slides)
            container.removeAllAnimations()

            // 3. Compute new frame and update content
            let newFrame = computeFrame(for: horizontalPosition, keyWidth: keyWidth)
            let effectiveWidth = newFrame.width
            let flatHeight = flatGlowHeight
            let perKeyColor: NSColor? = colorResolver?(horizontalPosition)

            // 4. Set model values and animate — all within disabled-actions transaction
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            container.frame = newFrame
            container.opacity = maxOpacity
            updateGlowSublayers(container: container, width: effectiveWidth, height: flatHeight, color: perKeyColor)

            // 5. Animate position (slide)
            let slidePosition = CABasicAnimation(keyPath: "position")
            slidePosition.fromValue = presentationPosition
            slidePosition.toValue = container.position
            slidePosition.duration = slideDuration
            slidePosition.timingFunction = easeOutTiming

            // 6. Animate bounds (handles width changes between different keys)
            let slideBounds = CABasicAnimation(keyPath: "bounds")
            slideBounds.fromValue = presentationBounds
            slideBounds.toValue = container.bounds
            slideBounds.duration = slideDuration
            slideBounds.timingFunction = easeOutTiming

            container.add(slidePosition, forKey: "slidePosition")
            container.add(slideBounds, forKey: "slideBounds")

            // 7. Restore opacity smoothly if it was mid-fade
            if presentationOpacity < maxOpacity {
                let opacityRestore = CABasicAnimation(keyPath: "opacity")
                opacityRestore.fromValue = presentationOpacity
                opacityRestore.toValue = maxOpacity
                opacityRestore.duration = 0.06
                opacityRestore.timingFunction = easeOutTiming
                container.add(opacityRestore, forKey: "opacityRestore")
            }

            CATransaction.commit()

        } else {
            // CASE B: Glow fully faded — appear fresh at new position

            // 1. Position instantly (no animation)
            let newFrame = computeFrame(for: horizontalPosition, keyWidth: keyWidth)
            let effectiveWidth = newFrame.width
            let flatHeight = flatGlowHeight
            let perKeyColor: NSColor? = colorResolver?(horizontalPosition)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = newFrame
            updateGlowSublayers(container: container, width: effectiveWidth, height: flatHeight, color: perKeyColor)
            CATransaction.commit()

            // 2. Fade in (identical to original behavior)
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let finalBounds = container.bounds
            let finalPosition = container.position
            let startHeight = max(1.0, finalBounds.height * popStartHeightFraction)
            let startBounds = CGRect(
                x: finalBounds.origin.x,
                y: finalBounds.origin.y,
                width: finalBounds.width,
                height: startHeight
            )
            let startPosition = CGPoint(
                x: finalPosition.x,
                y: finalPosition.y - (finalBounds.height - startHeight) * 0.5
            )

            let popBounds = CABasicAnimation(keyPath: "bounds")
            popBounds.fromValue = startBounds
            popBounds.toValue = finalBounds
            popBounds.duration = popInDuration
            popBounds.timingFunction = easeOutTiming

            let popPosition = CABasicAnimation(keyPath: "position")
            popPosition.fromValue = startPosition
            popPosition.toValue = finalPosition
            popPosition.duration = popInDuration
            popPosition.timingFunction = easeOutTiming

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0.0
            fadeIn.toValue = maxOpacity
            fadeIn.duration = popInDuration
            fadeIn.timingFunction = easeOutTiming
            container.add(popBounds, forKey: "popBounds")
            container.add(popPosition, forKey: "popPosition")
            container.add(fadeIn, forKey: "fadeIn")

            container.bounds = finalBounds
            container.position = finalPosition
            container.opacity = maxOpacity
            CATransaction.commit()

            glowIsAlive = true
        }

        // Update tracking
        currentPosition = horizontalPosition
        currentKeyWidth = keyWidth
    }

    /// Update the position of the glow instantly (for live preview during drag in key position editor)
    func updateGlowPosition(at horizontalPosition: CGFloat, keyCode: UInt16, keyWidth: CGFloat) {
        let container = ensureGlowLayer()

        // Cancel any animations for instant repositioning
        container.removeAllAnimations()

        let newFrame = computeFrame(for: horizontalPosition, keyWidth: keyWidth)
        let effectiveWidth = newFrame.width
        let flatHeight = flatGlowHeight
        let perKeyColor: NSColor? = colorResolver?(horizontalPosition)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = newFrame
        container.opacity = maxOpacity
        updateGlowSublayers(container: container, width: effectiveWidth, height: flatHeight, color: perKeyColor)
        CATransaction.commit()

        glowIsAlive = true
        currentPosition = horizontalPosition
        currentKeyWidth = keyWidth
        currentTargetKeyCode = keyCode
        heldKeys.insert(keyCode)
    }

    func hideGlow(keyCode: UInt16) {
        heldKeys.remove(keyCode)
        keyTimestamps.removeValue(forKey: keyCode)

        // Only fade out when ALL keys are released
        if !heldKeys.isEmpty {
            return
        }

        guard let container = glowLayer, glowIsAlive else { return }

        // Capture the current visual opacity before touching animations
        let currentVisualOpacity = container.presentation()?.opacity ?? container.opacity

        // Remove any slide/restore animations so they don't interfere with fade-out.
        // This ensures the layer is at its final model position before fading.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Snap to current visual position if a slide was still running
        let hasPositionAnimation =
            container.animation(forKey: "slidePosition") != nil ||
            container.animation(forKey: "popPosition") != nil
        let hasBoundsAnimation =
            container.animation(forKey: "slideBounds") != nil ||
            container.animation(forKey: "popBounds") != nil

        if let presentationPosition = container.presentation()?.position,
           hasPositionAnimation {
            container.position = presentationPosition
        }
        if let presentationBounds = container.presentation()?.bounds,
           hasBoundsAnimation {
            container.bounds = presentationBounds
        }
        container.removeAllAnimations()

        // Start fade-out
        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = currentVisualOpacity
        fadeAnim.toValue = 0.0
        fadeAnim.duration = fadeOutDuration
        fadeAnim.timingFunction = easeOutTiming
        fadeAnim.fillMode = .forwards
        fadeAnim.isRemovedOnCompletion = false

        // Use delegate to reliably detect completion vs. cancellation
        fadeAnim.delegate = FadeOutDelegate { [weak self] finished in
            if finished {
                self?.glowIsAlive = false
            }
        }

        container.add(fadeAnim, forKey: "fadeOut")
        container.opacity = 0.0

        CATransaction.commit()

        currentTargetKeyCode = nil
    }

    // MARK: - Key State Management

    /// Removes keys from heldKeys that haven't been refreshed recently.
    /// Protects against missed keyUp events (e.g., focus change, app switching).
    private func purgeStaleKeys() {
        let now = CACurrentMediaTime()
        let staleKeys = heldKeys.filter { key in
            guard let timestamp = keyTimestamps[key] else { return true }
            return (now - timestamp) > staleKeyThreshold
        }
        for key in staleKeys {
            heldKeys.remove(key)
            keyTimestamps.removeValue(forKey: key)
        }
    }

    /// Clears all held key state. Call on wake from sleep or app reactivation
    /// to prevent stale keys from blocking fade-out.
    func clearHeldKeys() {
        heldKeys.removeAll()
        keyTimestamps.removeAll()
    }

    // MARK: - Helpers

    /// Lazily creates the single glow layer or returns the existing one
    private func ensureGlowLayer() -> CALayer {
        if let existing = glowLayer {
            if existing.superlayer == nil {
                layer?.addSublayer(existing)
            }
            return existing
        }
        let container = createEmptyGlowContainer()
        layer?.addSublayer(container)
        glowLayer = container
        return container
    }

    /// Computes the frame rect for a glow at the given position and key width
    private func computeFrame(for horizontalPosition: CGFloat, keyWidth: CGFloat) -> CGRect {
        let effectiveWidth = baseKeyWidth * keyWidth * 2.5 * widthMultiplier
        let centerX = bounds.width * horizontalPosition
        let flatHeight = flatGlowHeight
        let verticalSink = flatHeight * edgeEmergenceFraction
        return CGRect(
            x: centerX - effectiveWidth / 2,
            y: -baseVerticalInset - verticalSink,
            width: effectiveWidth,
            height: flatHeight + 4
        )
    }

    // MARK: - Layer Creation

    private func createEmptyGlowContainer() -> CALayer {
        let container = CALayer()
        container.opacity = 0

        // Pre-create the sublayers
        for _ in 0..<blurSteps {
            let gradientLayer = CAGradientLayer()
            gradientLayer.locations = [0.0, 0.25, 0.55, 1.0]
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

            let maskLayer = CAShapeLayer()
            maskLayer.fillColor = NSColor.white.cgColor
            gradientLayer.mask = maskLayer

            container.addSublayer(gradientLayer)
        }

        applyRenderingQuality(to: container)
        return container
    }

    // MARK: - Sublayer Updates

    private func updateGlowSublayers(container: CALayer, width: CGFloat, height: CGFloat, color: NSColor? = nil) {
        let hardness = max(0.0, min(1.0, glowFullness))
        let mix = pow(hardness, 1.25)
        let spreadX = lerp(0.40, 0.12, mix: mix)
        let spreadY = lerp(0.80, 0.20, mix: mix)
        let outerExponent = lerp(1.0, 2.6, mix: mix)

        let mid1 = lerp(0.30, 0.55, mix: mix)
        let mid2Raw = lerp(0.62, 0.86, mix: mix)
        let mid2 = max(mid1 + 0.05, mid2Raw)

        let secondRatio = lerp(0.55, 0.80, mix: mix)
        let thirdRatio = lerp(0.20, 0.45, mix: mix)
        let baseAlpha = 0.35 * alphaNormalization

        // Use cached colors for solid mode (color == nil), compute inline for per-key colors
        let useCache = (color == nil)
        if useCache && !colorCacheValid {
            rebuildColorCache(
                baseAlpha: baseAlpha,
                outerExponent: outerExponent,
                secondRatio: secondRatio,
                thirdRatio: thirdRatio
            )
        }

        guard let sublayers = container.sublayers, sublayers.count == blurSteps else { return }

        let effectiveColor = color ?? glowColor

        for i in 0..<blurSteps {
            let factor = CGFloat(i) / CGFloat(blurSteps - 1)
            let scaleX = 1.0 + factor * spreadX
            let scaleY = 1.0 + factor * spreadY

            let layerWidth = width * scaleX
            let layerHeight = height * scaleY

            guard let gradientLayer = sublayers[i] as? CAGradientLayer else { continue }
            gradientLayer.locations = [0.0, NSNumber(value: Double(mid1)), NSNumber(value: Double(mid2)), 1.0]

            // Update frame
            gradientLayer.frame = CGRect(
                x: (width - layerWidth) / 2,
                y: 0,
                width: layerWidth,
                height: layerHeight
            )

            // Update colors
            if useCache {
                gradientLayer.colors = cachedColorArrays[i]
            } else {
                let layerWeight = pow(max(0.0, 1.0 - factor), outerExponent)
                let alpha = baseAlpha * layerWeight
                gradientLayer.colors = [
                    effectiveColor.withAlphaComponent(alpha).cgColor,
                    effectiveColor.withAlphaComponent(alpha * secondRatio).cgColor,
                    effectiveColor.withAlphaComponent(alpha * thirdRatio).cgColor,
                    NSColor.clear.cgColor
                ]
            }

            // Update mask path
            if let maskLayer = gradientLayer.mask as? CAShapeLayer {
                maskLayer.frame = gradientLayer.bounds
                maskLayer.path = maskPath(width: layerWidth, height: layerHeight)
            }
        }
    }

    // MARK: - Shape

    /// Generates a hybrid dome mask:
    /// - roundness=0   -> sharper cone-like profile
    /// - roundness=1   -> half-oval profile
    private func maskPath(width: CGFloat, height: CGFloat) -> CGPath {
        let clampedRoundness = max(0.0, min(1.0, glowRoundness))
        let mix = pow(clampedRoundness, hybridMixExponent)

        let path = CGMutablePath()
        let midX = width / 2
        let apexY = height

        let leftBase = CGPoint(x: 0, y: 0)
        let apex = CGPoint(x: midX, y: apexY)
        let rightBase = CGPoint(x: width, y: 0)

        // Cone-like control points (very sharp profile).
        let leftConeC1 = leftBase
        let leftConeC2 = apex
        let rightConeC1 = apex
        let rightConeC2 = rightBase

        // Half-ellipse control points (smooth dome profile).
        let leftOvalC1 = CGPoint(x: 0, y: apexY * halfEllipseKappa)
        let leftOvalC2 = CGPoint(x: midX * (1 - halfEllipseKappa), y: apexY)
        let rightOvalC1 = CGPoint(x: midX + (midX * halfEllipseKappa), y: apexY)
        let rightOvalC2 = CGPoint(x: width, y: apexY * halfEllipseKappa)

        let leftC1 = interpolatedPoint(from: leftConeC1, to: leftOvalC1, mix: mix)
        let leftC2 = interpolatedPoint(from: leftConeC2, to: leftOvalC2, mix: mix)
        let rightC1 = interpolatedPoint(from: rightConeC1, to: rightOvalC1, mix: mix)
        let rightC2 = interpolatedPoint(from: rightConeC2, to: rightOvalC2, mix: mix)

        path.move(to: leftBase)
        path.addCurve(to: apex, control1: leftC1, control2: leftC2)
        path.addCurve(to: rightBase, control1: rightC1, control2: rightC2)
        path.addLine(to: leftBase)
        path.closeSubpath()
        return path
    }

    private func interpolatedPoint(from: CGPoint, to: CGPoint, mix: CGFloat) -> CGPoint {
        CGPoint(
            x: from.x + (to.x - from.x) * mix,
            y: from.y + (to.y - from.y) * mix
        )
    }

    private func lerp(_ start: CGFloat, _ end: CGFloat, mix: CGFloat) -> CGFloat {
        start + (end - start) * mix
    }

    private func rebuildColorCache(baseAlpha: CGFloat, outerExponent: CGFloat, secondRatio: CGFloat, thirdRatio: CGFloat) {
        cachedColorArrays.removeAll()
        cachedColorArrays.reserveCapacity(blurSteps)

        for i in 0..<blurSteps {
            let factor = CGFloat(i) / CGFloat(blurSteps - 1)
            let layerWeight = pow(max(0.0, 1.0 - factor), outerExponent)
            let alpha = baseAlpha * layerWeight

            let colors: [CGColor] = [
                glowColor.withAlphaComponent(alpha).cgColor,
                glowColor.withAlphaComponent(alpha * secondRatio).cgColor,
                glowColor.withAlphaComponent(alpha * thirdRatio).cgColor,
                NSColor.clear.cgColor
            ]
            cachedColorArrays.append(colors)
        }

        colorCacheValid = true
    }

    private func currentScale() -> CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func applyRenderingQuality(to container: CALayer) {
        let scale = currentScale()
        container.contentsScale = scale
        container.allowsEdgeAntialiasing = true

        guard let sublayers = container.sublayers else { return }
        for sublayer in sublayers {
            guard let gradientLayer = sublayer as? CAGradientLayer else { continue }
            gradientLayer.contentsScale = scale
            gradientLayer.allowsEdgeAntialiasing = true
            gradientLayer.magnificationFilter = .linear
            gradientLayer.minificationFilter = .linear

            if let maskLayer = gradientLayer.mask as? CAShapeLayer {
                maskLayer.contentsScale = scale
                maskLayer.rasterizationScale = scale
                maskLayer.shouldRasterize = true
                maskLayer.allowsEdgeAntialiasing = true
            }
        }
    }

    private func refreshGlowLayerForDisplayScale() {
        guard let container = glowLayer else { return }
        let effectiveWidth = baseKeyWidth * currentKeyWidth * 2.5 * widthMultiplier
        let perKeyColor: NSColor? = colorResolver?(currentPosition)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyRenderingQuality(to: container)
        updateGlowSublayers(container: container, width: effectiveWidth, height: flatGlowHeight, color: perKeyColor)
        CATransaction.commit()
    }
}
