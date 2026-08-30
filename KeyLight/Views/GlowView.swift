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

/// One identity-scoped Classic Glow surface. A surface remains reusable after
/// its fade completes so ordinary sequential typing can keep the established
/// slide animation without keeping inactive layers in the render tree.
private final class ClassicGlowSurface {
    var id: GlowID
    var target: GlowTarget
    let layer: CALayer
    var isAlive = false
    var fadeDelegate: FadeOutDelegate?

    init(id: GlowID, target: GlowTarget, layer: CALayer) {
        self.id = id
        self.target = target
        self.layer = layer
    }
}

// MARK: - GlowView

/// View that renders smooth, blurry glow effects at the bottom edge.
/// Physically held keys own independent surfaces, while inactive surfaces are
/// reused so single-key transitions retain the original slide/pop/fade motion.
@MainActor
final class GlowView: NSView, GlowRenderer {

    var view: NSView { self }
    var supportsConcurrentPhysicalTargets: Bool { true }

    // MARK: - Identity-Scoped Glow State

    private var activeTargets: [GlowID: GlowTarget] = [:]
    private var activeTargetOrder: [GlowID] = []
    private var surfaces: [GlowID: ClassicGlowSurface] = [:]
    private var surfaceOrder: [GlowID] = []

    /// Duration for the slide animation between key positions
    private let slideDuration: CFTimeInterval = 0.07
    private let popInDuration: CFTimeInterval = 0.08
    private let popStartHeightFraction: CGFloat = 0.27

    // MARK: - Pre-computed Timing

    private let easeOutTiming = CAMediaTimingFunction(name: .easeOut)

    // MARK: - Color Cache

    private var cachedColorArrays: [[CGColor]] = []
    private var colorCacheValid = false

    // MARK: - Configuration

    private var configuration = RendererConfiguration.standard

    private var glowColor: NSColor { configuration.solidColor }
    private var baseKeyWidth: CGFloat { configuration.baseKeyWidth }
    private var glowHeight: CGFloat { configuration.glowHeight }
    private var widthMultiplier: CGFloat { configuration.widthMultiplier }
    private var selectedMaxOpacity: Float { configuration.maximumOpacity }
    private var maxOpacity: Float {
        configuration.chordAppearance.opacity(
            selectedMaxOpacity,
            activeMemberCount: activeChordMemberCount
        )
    }
    private var fadeOutDuration: CFTimeInterval { configuration.fadeDuration }
    private var glowRoundness: CGFloat { configuration.roundness }
    private var glowFullness: CGFloat { configuration.fullness }

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

    func apply(_ configuration: RendererConfiguration) {
        guard self.configuration != configuration else { return }
        let wasReducingMotion = self.configuration.reduceMotion
        self.configuration = configuration
        colorCacheValid = false

        if configuration.reduceMotion && !wasReducingMotion {
            freezeGeometryAnimationsAtCurrentState()
        }

        refreshVisibleConfiguration()
    }

    func show(_ target: GlowTarget) {
        let id = target.id
        let previousTarget = activeTargets[id]
        let wasActive = previousTarget != nil
        let hadActiveTargets = !activeTargets.isEmpty
        let surface = surface(
            for: target,
            mayReuseVisibleRetreat: !hadActiveTargets
        )

        activeTargets[id] = target
        if !wasActive {
            activeTargetOrder.append(id)
        }
        surface.target = target
        refreshActiveChordOpacity()

        switch target.id {
        case .physicalKey:
            if wasActive, previousTarget == target, refresh(id) {
                return
            }
            showAnimated(target, on: surface)
        case .preview:
            updatePreview(target, on: surface)
        }
    }

    private func showAnimated(
        _ target: GlowTarget,
        on surface: ClassicGlowSurface
    ) {
        let horizontalPosition = CGFloat(target.horizontalPosition)
        let keyWidth = CGFloat(target.keyWidth)
        let container = surface.layer

        if surface.isAlive {
            // CASE A: Glow is still visible — slide to new position

            // 1. Capture current visual state from presentation layer
            let presentationPosition = container.presentation()?.position ?? container.position
            let presentationBounds = container.presentation()?.bounds ?? container.bounds
            let presentationOpacity = container.presentation()?.opacity ?? container.opacity

            // 2. Cancel all in-progress animations (fade-out, previous slides)
            container.removeAllAnimations()
            surface.fadeDelegate = nil

            // 3. Compute new frame and update content
            let newFrame = computeFrame(for: horizontalPosition, keyWidth: keyWidth)
            let effectiveWidth = newFrame.width
            let flatHeight = flatGlowHeight
            let perKeyColor = configuration.resolvedColorOverride(for: target)

            // 4. Set model values and animate — all within disabled-actions transaction
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            container.frame = newFrame
            container.opacity = maxOpacity
            updateGlowSublayers(container: container, width: effectiveWidth, height: flatHeight, color: perKeyColor)

            if RendererMotionPolicy.allowsGeometryAnimation(
                reduceMotion: configuration.reduceMotion
            ) {
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
            }

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

            container.removeAllAnimations()
            surface.fadeDelegate = nil

            // 1. Position instantly (no animation)
            let newFrame = computeFrame(for: horizontalPosition, keyWidth: keyWidth)
            let effectiveWidth = newFrame.width
            let flatHeight = flatGlowHeight
            let perKeyColor = configuration.resolvedColorOverride(for: target)

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

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0.0
            fadeIn.toValue = maxOpacity
            fadeIn.duration = popInDuration
            fadeIn.timingFunction = easeOutTiming

            if RendererMotionPolicy.allowsGeometryAnimation(
                reduceMotion: configuration.reduceMotion
            ) {
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

                container.add(popBounds, forKey: "popBounds")
                container.add(popPosition, forKey: "popPosition")
            }
            container.add(fadeIn, forKey: "fadeIn")

            container.bounds = finalBounds
            container.position = finalPosition
            container.opacity = maxOpacity
            CATransaction.commit()

        }

        surface.isAlive = true
        surface.target = target
    }

    /// Refresh the visible identity without changing geometry, color, or
    /// animation energy. Nonvisible identities are deliberately rejected.
    @discardableResult
    func refresh(_ id: GlowID) -> Bool {
        guard activeTargets[id] != nil else { return false }
        guard let surface = surfaces[id] else { return false }
        let container = surface.layer
        guard container.superlayer != nil,
              surface.isAlive else {
            return false
        }

        // Only intervene if something is wrong (e.g. a fade-out snuck in).
        // Otherwise leave the layer alone to avoid disrupting animations.
        if container.opacity != maxOpacity && container.animation(forKey: "fadeOut") != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.removeAllAnimations()
            container.opacity = maxOpacity
            CATransaction.commit()
            surface.fadeDelegate = nil
        }
        surface.isAlive = true
        return true
    }

    /// Update the position of the glow instantly (for live preview during drag in key position editor)
    private func updatePreview(
        _ target: GlowTarget,
        on surface: ClassicGlowSurface
    ) {
        let container = surface.layer
        redrawImmediately(target, in: container)
        surface.fadeDelegate = nil
        surface.isAlive = true
        surface.target = target
    }

    /// Repaints the currently visible target after an atomic configuration
    /// update. This deliberately does not call `show` or mutate held-key state:
    /// target priority and retreat ordering belong to `OverlayController`.
    private func refreshVisibleConfiguration() {
        for id in activeTargetOrder {
            guard let target = activeTargets[id],
                  let surface = surfaces[id],
                  surface.layer.superlayer != nil,
                  surface.isAlive else {
                continue
            }

            redrawImmediately(target, in: surface.layer)
            surface.fadeDelegate = nil
            surface.target = target
        }
    }

    /// Applies the current pixels without introducing a new transition. This is
    /// also the established behavior for the continuously tracking previews.
    private func redrawImmediately(_ target: GlowTarget, in container: CALayer) {
        let horizontalPosition = CGFloat(target.horizontalPosition)
        let keyWidth = CGFloat(target.keyWidth)

        // Cancel any animations so the complete configuration becomes visible
        // as one transaction rather than mixing old geometry with new content.
        container.removeAllAnimations()

        let newFrame = computeFrame(for: horizontalPosition, keyWidth: keyWidth)
        let effectiveWidth = newFrame.width
        let flatHeight = flatGlowHeight
        let perKeyColor = configuration.resolvedColorOverride(for: target)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = newFrame
        container.opacity = maxOpacity
        updateGlowSublayers(
            container: container,
            width: effectiveWidth,
            height: flatHeight,
            color: perKeyColor
        )
        CATransaction.commit()
    }

    func hide(_ id: GlowID) {
        guard let target = activeTargets.removeValue(forKey: id) else { return }
        activeTargetOrder.removeAll { $0 == id }
        refreshActiveChordOpacity()
        guard let surface = surfaces[id], surface.isAlive else { return }
        surface.target = target
        let container = surface.layer

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
        surface.fadeDelegate = nil

        // Start fade-out
        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = currentVisualOpacity
        fadeAnim.toValue = 0.0
        fadeAnim.duration = fadeOutDuration
        fadeAnim.timingFunction = easeOutTiming
        fadeAnim.fillMode = .forwards
        fadeAnim.isRemovedOnCompletion = false

        // Use a retained delegate to reliably distinguish natural completion
        // from a surface being reused by a later key press.
        let fadeDelegate = FadeOutDelegate { [weak self, weak surface] finished in
            guard finished,
                  let self,
                  let surface,
                  self.surfaces[id] === surface,
                  self.activeTargets[id] == nil else {
                return
            }
            surface.isAlive = false
            surface.fadeDelegate = nil
            surface.layer.removeFromSuperlayer()
        }
        surface.fadeDelegate = fadeDelegate
        fadeAnim.delegate = fadeDelegate

        container.add(fadeAnim, forKey: "fadeOut")
        container.opacity = 0.0

        CATransaction.commit()
    }

    /// Clears the rendered identity and all in-flight visual state.
    func clear() {
        activeTargets.removeAll(keepingCapacity: true)
        activeTargetOrder.removeAll(keepingCapacity: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surface in surfaces.values {
            surface.layer.removeAllAnimations()
            surface.layer.opacity = 0
            surface.layer.removeFromSuperlayer()
            surface.isAlive = false
            surface.fadeDelegate = nil
        }
        CATransaction.commit()

        surfaces.removeAll(keepingCapacity: true)
        surfaceOrder.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    private var activeChordMemberCount: Int {
        activeTargets.keys.reduce(into: 0) { count, id in
            switch id {
            case .physicalKey:
                count += 1
            case .preview(let source) where source.isChordTest:
                count += 1
            case .preview:
                break
            }
        }
    }

    /// Chord membership can change without a settings transaction. Update the
    /// model opacity of every surviving identity immediately while preserving
    /// its geometry and other in-flight animation state.
    private func refreshActiveChordOpacity() {
        let opacity = maxOpacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in activeTargetOrder {
            guard let surface = surfaces[id], surface.isAlive else { continue }
            surface.layer.removeAnimation(forKey: "fadeIn")
            surface.layer.removeAnimation(forKey: "opacityRestore")
            surface.layer.opacity = opacity
        }
        CATransaction.commit()
    }

    /// Returns the target's existing surface or reuses an inactive surface.
    /// A still-visible retreat is reused only when no other target is active;
    /// that retains Classic Glow's original sequential slide behavior without
    /// stealing a layer from a physically held chord member.
    private func surface(
        for target: GlowTarget,
        mayReuseVisibleRetreat: Bool
    ) -> ClassicGlowSurface {
        if let existing = surfaces[target.id] {
            if activeTargets[target.id] == nil {
                surfaceOrder.removeAll { $0 == target.id }
                surfaceOrder.append(target.id)
            }
            if existing.layer.superlayer == nil {
                layer?.addSublayer(existing.layer)
            }
            return existing
        }

        let reusableID = surfaceOrder.reversed().first { candidateID in
            guard activeTargets[candidateID] == nil,
                  let candidate = surfaces[candidateID] else {
                return false
            }
            return !candidate.isAlive || mayReuseVisibleRetreat
        }

        if let reusableID,
           let reusable = surfaces.removeValue(forKey: reusableID) {
            surfaceOrder.removeAll { $0 == reusableID }
            reusable.id = target.id
            reusable.target = target
            surfaces[target.id] = reusable
            surfaceOrder.append(target.id)
            if reusable.layer.superlayer == nil {
                layer?.addSublayer(reusable.layer)
            }
            return reusable
        }

        let container = createEmptyGlowContainer()
        layer?.addSublayer(container)
        let created = ClassicGlowSurface(
            id: target.id,
            target: target,
            layer: container
        )
        surfaces[target.id] = created
        surfaceOrder.append(target.id)
        return created
    }

    private func freezeGeometryAnimationsAtCurrentState() {
        for surface in surfaces.values {
            freezeGeometryAnimations(on: surface.layer)
        }
    }

    private func freezeGeometryAnimations(on container: CALayer) {
        let hasPositionAnimation =
            container.animation(forKey: "slidePosition") != nil ||
            container.animation(forKey: "popPosition") != nil
        let hasBoundsAnimation =
            container.animation(forKey: "slideBounds") != nil ||
            container.animation(forKey: "popBounds") != nil

        guard hasPositionAnimation || hasBoundsAnimation else { return }
        let presentation = container.presentation()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hasPositionAnimation, let position = presentation?.position {
            container.position = position
        }
        if hasBoundsAnimation, let bounds = presentation?.bounds {
            container.bounds = bounds
        }
        container.removeAnimation(forKey: "slidePosition")
        container.removeAnimation(forKey: "popPosition")
        container.removeAnimation(forKey: "slideBounds")
        container.removeAnimation(forKey: "popBounds")
        CATransaction.commit()
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
        guard !surfaces.isEmpty else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surface in surfaces.values where surface.layer.superlayer != nil {
            let target = activeTargets[surface.id] ?? surface.target
            let effectiveWidth = baseKeyWidth
                * CGFloat(target.keyWidth)
                * 2.5
                * widthMultiplier
            applyRenderingQuality(to: surface.layer)
            updateGlowSublayers(
                container: surface.layer,
                width: effectiveWidth,
                height: flatGlowHeight,
                color: configuration.resolvedColorOverride(for: target)
            )
        }
        CATransaction.commit()
    }
}
