import AppKit
import Observation
import SwiftUI

#if compiler(>=6.2)
@available(macOS 26.0, *)
enum LiquidGlassPresentationMode: Equatable {
    case systemGlass
    case solidBlack
    case physicalRefraction

    /// A glass shape must be closed, so place that closure below the clipped
    /// screen edge for routes where a visible bottom optical rule is unwanted.
    var extendsGlassBelowVisibleBaseline: Bool {
        self == .systemGlass || self == .physicalRefraction
    }
}

@available(macOS 26.0, *)
struct LiquidGlassBellShape: Shape {
    var emergence: CGFloat
    var smoothness: CGFloat = 0.7069
    var flow: CGFloat = 0
    var profile: SurfaceShapeProfile = .currentWave
    var minimumRise: CGFloat = 0.5
    var extendsBelowBaseline = false

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(emergence, smoothness), flow) }
        set {
            emergence = newValue.first.first
            smoothness = newValue.first.second
            flow = newValue.second
        }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        Self.makePath(
            in: rect,
            emergence: emergence,
            smoothness: smoothness,
            flow: flow,
            profile: profile,
            minimumRise: minimumRise,
            extendsBelowBaseline: extendsBelowBaseline,
            closesBase: true
        )
    }

    nonisolated static func edgePath(
        in rect: CGRect,
        emergence: CGFloat,
        smoothness: CGFloat,
        flow: CGFloat,
        profile: SurfaceShapeProfile = .currentWave,
        minimumRise: CGFloat = 0.5
    ) -> Path {
        makePath(
            in: rect,
            emergence: emergence,
            smoothness: smoothness,
            flow: flow,
            profile: profile,
            minimumRise: minimumRise,
            extendsBelowBaseline: false,
            closesBase: false
        )
    }

    private nonisolated static func makePath(
        in rect: CGRect,
        emergence: CGFloat,
        smoothness: CGFloat,
        flow: CGFloat,
        profile _: SurfaceShapeProfile,
        minimumRise: CGFloat,
        extendsBelowBaseline: Bool,
        closesBase: Bool
    ) -> Path {
        currentWavePath(
            in: rect,
            emergence: emergence,
            smoothness: smoothness,
            flow: flow,
            minimumRise: minimumRise,
            extendsBelowBaseline: extendsBelowBaseline,
            closesBase: closesBase
        )
    }

    /// The original KeyLight wave. Keep this geometry stable so selecting the
    /// default profile is visually identical to prior builds.
    private nonisolated static func currentWavePath(
        in rect: CGRect,
        emergence: CGFloat,
        smoothness: CGFloat,
        flow: CGFloat,
        minimumRise: CGFloat,
        extendsBelowBaseline: Bool,
        closesBase: Bool
    ) -> Path {
        let progress = Self.unitValue(emergence, default: 0)
        let softness = Self.unitValue(smoothness, default: 0.7069)
        let directionalFlow = Self.signedUnitValue(flow)
        let materialWidth = rect.width * (0.28 + 0.72 * progress)
        let minX = rect.midX - materialWidth * 0.5
        let maxX = rect.midX + materialWidth * 0.5

        // The renderer places 28% of its frame below the display. This line is
        // therefore the exact physical screen edge in the SwiftUI coordinate
        // space. Even the collapsed path leaves a half-point lens at that edge,
        // while its opacity begins at zero, so the material grows from the bezel
        // instead of appearing one frame above it.
        let screenEdgeY = rect.height * 0.72
        let safeMinimumRise = minimumRise.isFinite
            ? max(minimumRise, 0)
            : 0.5
        let rise = max(screenEdgeY * progress, safeMinimumRise)
        let topY = screenEdgeY - rise

        // Smoothness changes only the horizontal shoulder falloff. Keeping the
        // range below one half per side guarantees a real flat plateau at 100%.
        let shoulderShare = Self.shoulderShare(for: softness)
        let leadingAdjustment = 0.055 * abs(directionalFlow)
        let trailingAdjustment = 0.085 * abs(directionalFlow)
        let leftShoulderShare = directionalFlow >= 0
            ? shoulderShare + trailingAdjustment
            : shoulderShare - leadingAdjustment
        let rightShoulderShare = directionalFlow >= 0
            ? shoulderShare - leadingAdjustment
            : shoulderShare + trailingAdjustment
        let leftShoulder = materialWidth * min(max(leftShoulderShare, 0.12), 0.46)
        let rightShoulder = materialWidth * min(max(rightShoulderShare, 0.12), 0.46)
        let topBias = materialWidth * 0.045 * directionalFlow * progress
        let leftTopX = min(
            minX + leftShoulder + topBias,
            rect.midX + topBias - 0.5
        )
        let rightTopX = max(
            maxX - rightShoulder + topBias,
            rect.midX + topBias + 0.5
        )
        let leftFirstTangent = leftShoulder * (0.18 + 0.06 * softness)
        let leftSecondTangent = leftShoulder * (0.70 + 0.08 * softness)
        let rightFirstTangent = rightShoulder * (0.18 + 0.06 * softness)
        let rightSecondTangent = rightShoulder * (0.70 + 0.08 * softness)

        var path = Path()
        path.move(to: CGPoint(x: minX, y: screenEdgeY))
        path.addCurve(
            to: CGPoint(x: leftTopX, y: topY),
            control1: CGPoint(x: minX + leftFirstTangent, y: screenEdgeY),
            control2: CGPoint(x: minX + leftSecondTangent + topBias, y: topY)
        )
        path.addLine(to: CGPoint(x: rightTopX, y: topY))
        path.addCurve(
            to: CGPoint(x: maxX, y: screenEdgeY),
            control1: CGPoint(x: maxX - rightSecondTangent + topBias, y: topY),
            control2: CGPoint(x: maxX - rightFirstTangent, y: screenEdgeY)
        )
        if closesBase {
            if extendsBelowBaseline {
                // Physical glass is cropped by the screen edge rather than
                // terminated there. Put the closure below the visible view so
                // system glass cannot produce a horizontal bezel highlight.
                path.addLine(to: CGPoint(x: maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: minX, y: rect.maxY))
            }
            path.closeSubpath()
        }
        return path
    }

    private nonisolated static func unitValue(
        _ value: CGFloat,
        default defaultValue: CGFloat
    ) -> CGFloat {
        guard value.isFinite else { return defaultValue }
        return min(max(value, 0), 1)
    }

    nonisolated static func shoulderShare(for smoothness: CGFloat) -> CGFloat {
        let safeSmoothness = unitValue(smoothness, default: 0.7069)
        let curved = CGFloat(pow(Double(safeSmoothness), 1.55))
        return 0.12 + 0.30 * curved
    }

    private nonisolated static func signedUnitValue(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, -1), 1)
    }
}

@available(macOS 26.0, *)
struct LiquidGlassCohesiveBridge {
    nonisolated static func sag(
        averageHeight: CGFloat,
        smoothness: CGFloat
    ) -> CGFloat {
        let safeHeight = averageHeight.isFinite ? max(averageHeight, 0) : 0
        let safeSmoothness = smoothness.isFinite
            ? min(max(smoothness, 0), 1)
            : 0.7069
        return min(
            max(safeHeight * (0.10 - 0.04 * safeSmoothness), 0.75),
            3.2
        )
    }

    nonisolated static func path(
        start: CGPoint,
        end: CGPoint,
        baselineY: CGFloat,
        averageHeight: CGFloat,
        smoothness: CGFloat
    ) -> Path {
        let distance = end.x - start.x
        guard start.x.isFinite,
              start.y.isFinite,
              end.x.isFinite,
              end.y.isFinite,
              baselineY.isFinite,
              distance > 0.5 else {
            return Path()
        }

        let saddleY = max(start.y, end.y) + sag(
            averageHeight: averageHeight,
            smoothness: smoothness
        )
        var bridge = Path()
        bridge.move(to: CGPoint(x: start.x, y: baselineY))
        bridge.addLine(to: start)
        bridge.addCurve(
            to: end,
            control1: CGPoint(
                x: start.x + distance * 0.34,
                y: saddleY
            ),
            control2: CGPoint(
                x: end.x - distance * 0.34,
                y: saddleY
            )
        )
        bridge.addLine(to: CGPoint(x: end.x, y: baselineY))
        bridge.closeSubpath()
        return bridge
    }
}

@available(macOS 26.0, *)
struct LiquidGlassSolidBlackMaterial {
    static let fillOpacity = 1.0

    nonisolated static func isPresent(
        isVisible: Bool,
        emergence: CGFloat
    ) -> Bool {
        isVisible && emergence.isFinite && emergence > 0.000_1
    }
}

@available(macOS 26.0, *)
struct LiquidGlassSurfaceSnapshot: Equatable {
    let id: GlowID
    let frame: CGRect
    let opacity: Double
    let visibility: Double
    let edgeOpacity: Double
    let lensOpacity: Double
    let dimmingOpacity: Double
    let chromaticDisplacement: CGFloat
    let emergence: CGFloat
    let smoothness: CGFloat
    let horizontalVelocity: CGFloat
    let isVisible: Bool
}

private typealias LiquidGlassSurfaceState = SurfaceMotionState
private typealias LiquidGlassSurfaceVelocity = SurfaceMotionVelocity
private typealias LiquidGlassSurfaceSample = SurfaceMotionSample
private typealias LiquidGlassSurfaceTransition = SurfaceMotionTransition
private typealias LiquidGlassSurfaceTrack = SurfaceMotionTrack

@available(macOS 26.0, *)
private extension LiquidGlassSurfaceSample {
    func snapshot(
        materialOpacity: Double,
        edgeOpacity: Double,
        lensOpacity: Double,
        dimmingOpacity: Double,
        chromaticDisplacement: CGFloat
    ) -> LiquidGlassSurfaceSnapshot {
        let safeVisibility = min(max(state.visibility, 0), 1)
        return LiquidGlassSurfaceSnapshot(
            id: state.id,
            frame: state.frame,
            opacity: safeVisibility * min(max(materialOpacity, 0), 1),
            visibility: safeVisibility,
            edgeOpacity: safeVisibility * min(max(edgeOpacity, 0), 1),
            lensOpacity: safeVisibility * min(max(lensOpacity, 0), 1),
            dimmingOpacity: safeVisibility * min(max(dimmingOpacity, 0), 1),
            chromaticDisplacement: max(chromaticDisplacement, 0),
            emergence: state.emergence,
            smoothness: state.smoothness,
            horizontalVelocity: velocity.frame.origin.x
                + velocity.frame.width * 0.5,
            isVisible: state.isVisible
        )
    }
}

@available(macOS 26.0, *)
@MainActor
@Observable
private final class LiquidGlassSurfaceModel {
    // Native glass and custom grouping join only after silhouettes genuinely
    // overlap. Positive spacing made nearby keys attract each other's outside
    // shoulders before their material touched.
    var spacing: CGFloat = 0
    private(set) var presentationMode: LiquidGlassPresentationMode = .systemGlass
    private(set) var shapeProfile: SurfaceShapeProfile = .currentWave
    private(set) var physicalCaptureIsReady = false
    private(set) var physicalCaptureStopGeneration: UInt = 0
    private(set) var physicalCaptureState: PhysicalCaptureState = .idle
    private(set) var materialOpacity: Double = 0.7
    private(set) var prismaticEdgeOpacity: Double = 0.5
    private(set) var refractionStrength: Double = 1.0
    private(set) var clearLensOpacity: Double = 0.8
    private(set) var localizedDimmingOpacity: Double = 0.1
    private(set) var chromaticDisplacement: CGFloat = 1.2
    private(set) var chordSurfaceStyle: ChordSurfaceStyle = .naturalMerge
    private(set) var chordIntensityMultiplier: Double = 1
    private(set) var activeChordMemberCount = 0
    private(set) var isTimelineActive = false
    private var motionEngine: SurfaceMotionEngine
    @ObservationIgnored
    private var runtimeStatusHandler:
        (@MainActor (GlowRendererRuntimeState) -> Void)?

    init(clock: any SurfaceMotionClock = SystemSurfaceMotionClock()) {
        motionEngine = SurfaceMotionEngine(clock: clock)
    }

    var tracks: [LiquidGlassSurfaceTrack] { motionEngine.tracks }
    var currentTime: TimeInterval { motionEngine.currentTime }

    func setPresentation(
        mode: LiquidGlassPresentationMode,
        shapeProfile: SurfaceShapeProfile
    ) {
        if presentationMode != mode {
            physicalCaptureIsReady = false
        }
        presentationMode = mode
        self.shapeProfile = shapeProfile
    }

    func setPhysicalCaptureReady(_ ready: Bool) {
        physicalCaptureIsReady = ready
    }

    func setChordAppearance(
        _ appearance: ChordAppearance,
        activeMemberCount: Int
    ) {
        let normalized = appearance.normalized
        chordSurfaceStyle = normalized.style
        chordIntensityMultiplier = normalized.intensityMultiplier
        activeChordMemberCount = max(activeMemberCount, 0)
    }

    var solidBlackFillOpacity: Double {
        guard activeChordMemberCount >= 2 else {
            return LiquidGlassSolidBlackMaterial.fillOpacity
        }
        return min(max(chordIntensityMultiplier, 0), 1)
    }

    func setPhysicalCaptureState(_ state: PhysicalCaptureState) {
        physicalCaptureState = state
        publishRuntimeStatus()
    }

    func setRuntimeStatusHandler(
        _ handler: (@MainActor (GlowRendererRuntimeState) -> Void)?
    ) {
        runtimeStatusHandler = handler
        publishRuntimeStatus()
    }

    private func publishRuntimeStatus() {
        let readiness: RendererReadiness
        switch physicalCaptureState {
        case .failed:
            readiness = .fallback
        default:
            readiness = .ready
        }
        runtimeStatusHandler?(GlowRendererRuntimeState(
            readiness: readiness,
            captureState: physicalCaptureState,
            fallbackReason: physicalCaptureState == .failed
                ? "Physical Refraction is using System Glass fallback"
                : nil
        ))
    }

    func stopPhysicalCaptureImmediately() {
        physicalCaptureIsReady = false
        physicalCaptureStopGeneration &+= 1
    }

    func setMaterial(
        bodyOpacity: Float,
        edgeOpacity: Float,
        refractionStrength: CGFloat,
        lensOpacity: Float,
        dimmingOpacity: Float,
        chromaticDisplacement: CGFloat
    ) {
        materialOpacity = Double(
            bodyOpacity.isFinite ? min(max(bodyOpacity, 0), 1) : 0.7
        )
        prismaticEdgeOpacity = Double(
            edgeOpacity.isFinite ? min(max(edgeOpacity, 0), 1) : 0.5
        )
        self.refractionStrength = Double(
            refractionStrength.isFinite
                ? min(max(refractionStrength, 0.5), 2.5)
                : 1
        )
        clearLensOpacity = Double(
            lensOpacity.isFinite ? min(max(lensOpacity, 0), 1) : 0.8
        )
        localizedDimmingOpacity = Double(
            dimmingOpacity.isFinite ? min(max(dimmingOpacity, 0), 1) : 0.1
        )
        self.chromaticDisplacement = chromaticDisplacement.isFinite
            ? max(chromaticDisplacement, 0)
            : 1.2
    }

    func setTracks(_ tracks: [LiquidGlassSurfaceTrack]) {
        motionEngine.setTracks(tracks)
        isTimelineActive = motionEngine.hasActiveTransitions
    }

    func samples(at time: TimeInterval) -> [LiquidGlassSurfaceSample] {
        motionEngine.samples(at: time)
    }
}

@available(macOS 26.0, *)
private struct LiquidGlassSurfaceRoot: View {
    let model: LiquidGlassSurfaceModel
    @Namespace private var glassNamespace

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !model.isTimelineActive)) { _ in
            let timestamp = model.currentTime
            let samples = model.samples(at: timestamp)

            GeometryReader { proxy in
                ZStack {
                    if model.presentationMode == .solidBlack {
                        Canvas { graphics, size in
                            drawSolidBlack(
                                in: &graphics,
                                size: size,
                                samples: samples
                            )
                        }
                    } else if model.presentationMode == .physicalRefraction {
                        if !model.physicalCaptureIsReady {
                            nativeSurfaceLayers(
                                size: proxy.size,
                                samples: samples
                            )
                        }
                        PhysicalRefractionSurfaceView(
                            snapshots: samples.map {
                                $0.snapshot(
                                    materialOpacity: model.materialOpacity,
                                    edgeOpacity: model.prismaticEdgeOpacity,
                                    lensOpacity: model.clearLensOpacity,
                                    dimmingOpacity: model.localizedDimmingOpacity,
                                    chromaticDisplacement: model.chromaticDisplacement
                                )
                            },
                            bodyOpacity: model.materialOpacity,
                            edgeStrength: model.prismaticEdgeOpacity,
                            refractionStrength: model.refractionStrength,
                            stopGeneration: model.physicalCaptureStopGeneration,
                            onCaptureReadinessChanged: { ready in
                                model.setPhysicalCaptureReady(ready)
                            },
                            onCaptureStateChanged: { state in
                                model.setPhysicalCaptureState(state)
                            }
                        )
                    } else {
                        nativeSurfaceLayers(
                            size: proxy.size,
                            samples: samples
                        )
                    }
                }
            }
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func nativeSurfaceLayers(
        size: CGSize,
        samples: [LiquidGlassSurfaceSample]
    ) -> some View {
        if model.chordSurfaceStyle == .naturalMerge {
            // Every held key has a stable system-glass identity, but all of
            // them live inside one container so adjacent lenses can merge.
            GlassEffectContainer(spacing: model.spacing) {
                nativeSurfaceNodes(size: size, samples: samples)
            }
        } else {
            // Separate containers are an explicit material boundary: stable
            // key identities remain, but native glass cannot form bridges.
            ZStack {
                ForEach(samples, id: \.state.id) { sample in
                    GlassEffectContainer(spacing: 0) {
                        nativeSurfaceNode(size: size, sample: sample)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func nativeSurfaceNodes(
        size: CGSize,
        samples: [LiquidGlassSurfaceSample]
    ) -> some View {
        ZStack {
            ForEach(samples, id: \.state.id) { sample in
                nativeSurfaceNode(size: size, sample: sample)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func nativeSurfaceNode(
        size: CGSize,
        sample: LiquidGlassSurfaceSample
    ) -> some View {
        let surface = sample.state
        let visibility = unitValue(surface.visibility)
        let glassShape = LiquidGlassBellShape(
            emergence: surface.emergence,
            smoothness: surface.smoothness,
            flow: normalizedFlow(for: sample),
            profile: model.shapeProfile,
            extendsBelowBaseline:
                model.presentationMode.extendsGlassBelowVisibleBaseline
        )

        return Color.clear
            .glassEffect(.clear, in: glassShape)
            .glassEffectID(surface.id, in: glassNamespace)
            .glassEffectTransition(.matchedGeometry)
            .opacity(visibility * model.clearLensOpacity)
            .frame(
                width: max(surface.frame.width, 1),
                height: max(surface.frame.height, 1)
            )
            .position(
                x: surface.frame.midX,
                y: size.height - surface.frame.midY
            )
    }

    private func drawSolidBlack(
        in graphics: inout GraphicsContext,
        size: CGSize,
        samples: [LiquidGlassSurfaceSample]
    ) {
        let groups = model.chordSurfaceStyle == .naturalMerge
            ? connectedGroups(in: samples, visibilityPolicy: .geometryOnly)
            : independentGroups(in: samples, visibilityPolicy: .geometryOnly)
        for group in groups {
            graphics.fill(
                combinedPath(for: group, canvasHeight: size.height),
                with: .color(
                    .black.opacity(model.solidBlackFillOpacity)
                )
            )
        }
    }

    private func independentGroups(
        in samples: [LiquidGlassSurfaceSample],
        visibilityPolicy: SurfaceVisibilityPolicy
    ) -> [[LiquidGlassSurfaceSample]] {
        samples.compactMap { sample in
            guard sample.state.isVisible else { return nil }
            switch visibilityPolicy {
            case .materialOpacity:
                guard unitValue(sample.state.visibility) > 0.000_1 else {
                    return nil
                }
            case .geometryOnly:
                guard LiquidGlassSolidBlackMaterial.isPresent(
                    isVisible: sample.state.isVisible,
                    emergence: sample.state.emergence
                ) else {
                    return nil
                }
            }
            return [sample]
        }
    }

    private func connectedGroups(
        in samples: [LiquidGlassSurfaceSample],
        visibilityPolicy: SurfaceVisibilityPolicy = .materialOpacity
    ) -> [[LiquidGlassSurfaceSample]] {
        let visible = samples.filter {
            guard $0.state.isVisible else { return false }
            switch visibilityPolicy {
            case .materialOpacity:
                return unitValue($0.state.visibility) > 0.000_1
            case .geometryOnly:
                return LiquidGlassSolidBlackMaterial.isPresent(
                    isVisible: $0.state.isVisible,
                    emergence: $0.state.emergence
                )
            }
        }
        let groups = LiquidGlassTransitionMath.connectedFrameGroups(
            visible.map(\.state.frame),
            spacing: model.spacing
        )
        return groups.map { indices in indices.map { visible[$0] } }
    }

    private enum SurfaceVisibilityPolicy {
        case materialOpacity
        case geometryOnly
    }

    private func combinedPath(
        for samples: [LiquidGlassSurfaceSample],
        canvasHeight: CGFloat
    ) -> Path {
        let orderedSamples = samples.sorted {
            $0.state.frame.midX < $1.state.frame.midX
        }
        let members = orderedSamples.map { sample in
            (
                sample: sample,
                path: surfacePath(for: sample, canvasHeight: canvasHeight)
            )
        }
        var result = Path()
        var hasPath = false

        for member in members {
            if hasPath {
                result = result.union(member.path)
            } else {
                result = member.path
                hasPath = true
            }
        }

        // The native glass nodes merge inside GlassEffectContainer, while this
        // shallow saddle makes the custom backing and refractive perimeter read
        // as the same cohesive material. Because the bridge follows the live
        // presentation frames, it expands during a neighboring press and
        // contracts toward the surviving key during release.
        if members.count > 1 {
            for index in 0..<(members.count - 1) {
                let left = members[index]
                let right = members[index + 1]
                guard LiquidGlassTransitionMath.shouldMerge(
                    left.sample.state.frame,
                    with: right.sample.state.frame,
                    spacing: model.spacing
                ) else {
                    continue
                }
                let bridge = cohesiveBridgePath(
                    from: left,
                    to: right,
                    canvasHeight: canvasHeight
                )
                if !bridge.isEmpty {
                    result = result.union(bridge)
                }
            }
        }

        return result
    }

    private func surfacePath(
        for sample: LiquidGlassSurfaceSample,
        canvasHeight: CGFloat
    ) -> Path {
        let surface = sample.state
        let localRect = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(surface.frame.width, 1),
                height: max(surface.frame.height, 1)
            )
        )
        let localPath = LiquidGlassBellShape(
            emergence: surface.emergence,
            smoothness: surface.smoothness,
            flow: normalizedFlow(for: sample),
            profile: model.shapeProfile,
            minimumRise: model.presentationMode == .solidBlack ? 0 : 0.5
        ).path(in: localRect)
        return localPath.applying(CGAffineTransform(
            translationX: surface.frame.minX,
            y: canvasHeight - surface.frame.maxY
        ))
    }

    private func cohesiveBridgePath(
        from left: (sample: LiquidGlassSurfaceSample, path: Path),
        to right: (sample: LiquidGlassSurfaceSample, path: Path),
        canvasHeight: CGFloat
    ) -> Path {
        let startX = left.sample.state.frame.midX
        let endX = right.sample.state.frame.midX
        let distance = endX - startX
        guard startX.isFinite,
              endX.isFinite,
              canvasHeight.isFinite,
              distance > 0.5 else {
            return Path()
        }

        let leftBounds = left.path.boundingRect
        let rightBounds = right.path.boundingRect
        let materialOverlap = min(leftBounds.maxX, rightBounds.maxX)
            - max(leftBounds.minX, rightBounds.minX)
        guard materialOverlap > 0.5 else { return Path() }

        let startY = leftBounds.minY
        let endY = rightBounds.minY
        guard startY.isFinite, endY.isFinite else { return Path() }

        let averageHeight = (
            leftBounds.height + rightBounds.height
        ) * 0.5
        let averageSmoothness = min(max(
            (
                left.sample.state.smoothness
                    + right.sample.state.smoothness
            ) * 0.5,
            0
        ), 1)
        return LiquidGlassCohesiveBridge.path(
            start: CGPoint(x: startX, y: startY),
            end: CGPoint(x: endX, y: endY),
            baselineY: canvasHeight,
            averageHeight: averageHeight,
            smoothness: averageSmoothness
        )
    }

    private func normalizedFlow(for sample: LiquidGlassSurfaceSample) -> CGFloat {
        let centerVelocity = sample.velocity.frame.origin.x
            + sample.velocity.frame.width * 0.5
        let flowScale = max(sample.state.frame.width * 4.5, 240)
        return min(max(centerVelocity / flowScale, -1), 1)
    }

    private func unitValue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

@available(macOS 26.0, *)
@MainActor
final class LiquidGlassGlowView: NSView, GlowRenderer {
    private let surfaceModel: LiquidGlassSurfaceModel
    private let presentationMode: LiquidGlassPresentationMode
    private var completionTask: Task<Void, Never>?
    private var hostingView: NSView?

    private var activeTargets: [GlowID: GlowTarget] = [:]
    private var activeTargetOrder: [GlowID] = []
    private var configuration = RendererConfiguration.standard

    var view: NSView { self }
    var supportsConcurrentPhysicalTargets: Bool { true }

    private var baseKeyWidth: CGFloat { configuration.baseKeyWidth }
    private var glowHeight: CGFloat { configuration.glowHeight }
    private var widthMultiplier: CGFloat { configuration.widthMultiplier }
    private var maxOpacity: Float { configuration.maximumOpacity }
    private var smoothness: CGFloat { configuration.roundness }
    private var reduceMotionEnabled: Bool { configuration.reduceMotion }
    private var reduceTransparencyEnabled: Bool { configuration.reduceTransparency }
    private var increaseContrastEnabled: Bool { configuration.increaseContrast }
    private var motionProfile: LiquidGlassMotionProfile {
        LiquidGlassMotionProfile(fadeDuration: configuration.fadeDuration)
    }

    init(
        frame frameRect: NSRect,
        presentationMode: LiquidGlassPresentationMode
    ) {
        self.presentationMode = presentationMode
        surfaceModel = LiquidGlassSurfaceModel()
        super.init(frame: frameRect)
        surfaceModel.setPresentation(
            mode: presentationMode,
            shapeProfile: configuration.shapeProfile
        )
        surfaceModel.setChordAppearance(
            configuration.chordAppearance,
            activeMemberCount: 0
        )
        configureView()
        refreshMaterial()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        completionTask?.cancel()
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let host = NSHostingView(rootView: LiquidGlassSurfaceRoot(model: surfaceModel))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.setAccessibilityElement(false)
        host.setAccessibilityChildren([])
        addSubview(host)
        hostingView = host
    }

    func apply(_ configuration: RendererConfiguration) {
        guard self.configuration != configuration else { return }
        let previous = self.configuration
        self.configuration = configuration
        surfaceModel.setPresentation(
            mode: presentationMode,
            shapeProfile: configuration.shapeProfile
        )
        surfaceModel.setChordAppearance(
            configuration.chordAppearance,
            activeMemberCount: activeChordMemberCount
        )
        refreshMaterial()

        if previous.fadeDuration != configuration.fadeDuration,
           let previewID = activeTargetOrder.first(where: {
               if case .preview = $0 { return true }
               return false
           }) {
            retimeVisiblePreview(previewID)
            return
        }

        guard changesGlassGeometry(from: previous, to: configuration) else { return }
        refreshVisibleGeometry()
    }

    func setRuntimeStatusHandler(
        _ handler: (@MainActor (GlowRendererRuntimeState) -> Void)?
    ) {
        if presentationMode == .physicalRefraction {
            surfaceModel.setRuntimeStatusHandler(handler)
        } else {
            handler?(.ready)
        }
    }

    func show(_ target: GlowTarget) {
        let now = currentTime
        finalizeCompletedTransitions(at: now)
        let position = sanitizedPosition(CGFloat(target.horizontalPosition))
        let keyWidth = sanitizedKeyWidth(CGFloat(target.keyWidth))
        let targetFrame = frameForGlass(at: position, keyWidth: keyWidth)
        let hadActiveTargets = !activeTargetOrder.isEmpty
        let existingTrackIndex = surfaceModel.tracks.firstIndex {
            $0.id == target.id
        }
        activeTargets[target.id] = target
        if !activeTargetOrder.contains(target.id) {
            activeTargetOrder.append(target.id)
        }
        syncChordAppearance()

        if let existingTrackIndex {
            let sample = surfaceModel.tracks[existingTrackIndex].sample(at: now)
            retargetSurface(sample, to: targetFrame, at: now)
            return
        }

        // Preserve the fluid one-key travel from the prior renderer. Once the
        // previous key has been released and no chord remains, its presentation
        // state can be handed to the new identity instead of blinking out and
        // growing a second lens from zero.
        if !hadActiveTargets,
           let transferIndex = nearestFadingTrackIndex(
               to: targetFrame,
               at: now
           ) {
            var tracks = surfaceModel.tracks
            let fading = tracks.remove(at: transferIndex).sample(at: now)
            surfaceModel.setTracks(tracks)
            retargetSurface(
                reidentified(fading, as: target.id),
                to: targetFrame,
                at: now
            )
            return
        }

        revealSurface(target.id, at: targetFrame, time: now)
    }

    private func retargetSurface(
        _ sample: LiquidGlassSurfaceSample,
        to targetFrame: CGRect,
        at time: TimeInterval,
        durationOverride: TimeInterval? = nil
    ) {
        var start = sample
        let nearby = LiquidGlassTransitionMath.shouldMerge(
            start.state.frame,
            with: targetFrame,
            spacing: surfaceModel.spacing
        )
        let travelDistance = abs(start.state.frame.midX - targetFrame.midX)
        let normalizedDistance = travelDistance / max(bounds.width * 0.65, 1)
        let naturalDuration = nearby
            ? motionProfile.nearbyMorphDuration
            : motionProfile.travelDuration(normalizedDistance: normalizedDistance)
        let duration = durationOverride ?? naturalDuration

        if reduceMotionEnabled {
            start.state.frame = targetFrame
            start.state.emergence = 1
            start.state.smoothness = smoothness
            start.velocity = .zero
        } else if !nearby {
            let expansionVelocity = LiquidGlassTransitionMath.flowExpansionVelocity(
                distance: travelDistance,
                duration: naturalDuration,
                containerWidth: bounds.width
            )
            start.velocity.frame.size.width += expansionVelocity
            // Expand around the presentation center instead of kicking it in
            // the travel direction.
            start.velocity.frame.origin.x -= expansionVelocity * 0.5
        }

        var destination = start.state
        destination.frame = targetFrame
        destination.visibility = 1
        destination.emergence = 1
        destination.smoothness = smoothness
        destination.isVisible = true

        var tracks = surfaceModel.tracks
        let track = transitionTrack(
            from: start,
            to: destination,
            startTime: time,
            duration: reduceMotionEnabled ? motionProfile.configurationDuration : duration
        )
        replaceOrAppend(track, in: &tracks)
        surfaceModel.setTracks(tracks)
        scheduleCompletionSweep()
    }

    private func revealSurface(
        _ id: GlowID,
        at targetFrame: CGRect,
        time: TimeInterval
    ) {
        let expandedAtStart = reduceMotionEnabled
        let start = LiquidGlassSurfaceState(
            id: id,
            frame: targetFrame,
            visibility: 0,
            emergence: expandedAtStart ? 1 : 0,
            smoothness: smoothness,
            isVisible: true
        )
        var destination = start
        destination.visibility = 1
        destination.emergence = 1
        let sample = LiquidGlassSurfaceSample(state: start, velocity: .zero)
        let track = transitionTrack(
            from: sample,
            to: destination,
            startTime: time,
            duration: motionProfile.revealDuration
        )

        var tracks = surfaceModel.tracks
        replaceOrAppend(track, in: &tracks)
        surfaceModel.setTracks(tracks)
        scheduleCompletionSweep()
    }

    @discardableResult
    func refresh(_ id: GlowID) -> Bool {
        guard activeTargets[id] != nil else { return false }
        let now = currentTime
        finalizeCompletedTransitions(at: now)
        guard let trackIndex = surfaceModel.tracks.firstIndex(where: {
            $0.id == id
        }) else {
            return false
        }
        var start = surfaceModel.tracks[trackIndex].sample(at: now)
        guard start.state.isVisible else { return false }

        if reduceMotionEnabled {
            start.state.emergence = 1
            start.state.smoothness = smoothness
            start.velocity = .zero
        }
        var destination = start.state
        destination.visibility = 1
        destination.emergence = 1
        destination.smoothness = smoothness
        destination.isVisible = true

        var tracks = surfaceModel.tracks
        tracks[trackIndex] = transitionTrack(
            from: start,
            to: destination,
            startTime: now,
            duration: motionProfile.configurationDuration
        )
        surfaceModel.setTracks(tracks)
        scheduleCompletionSweep()
        return true
    }

    func hide(_ id: GlowID) {
        activeTargets.removeValue(forKey: id)
        activeTargetOrder.removeAll { $0 == id }
        syncChordAppearance()

        let now = currentTime
        finalizeCompletedTransitions(at: now)
        guard let trackIndex = surfaceModel.tracks.firstIndex(where: {
            $0.id == id
        }) else { return }
        var start = surfaceModel.tracks[trackIndex].sample(at: now)
        guard start.state.isVisible else { return }
        if reduceMotionEnabled && presentationMode == .solidBlack {
            var tracks = surfaceModel.tracks
            tracks.remove(at: trackIndex)
            surfaceModel.setTracks(tracks)
            return
        }
        if reduceMotionEnabled {
            start.velocity.frame = .zero
            start.velocity.emergence = 0
        }

        var destination = start.state
        destination.visibility = 0
        destination.emergence = reduceMotionEnabled
            ? start.state.emergence
            : 0
        destination.smoothness = smoothness
        destination.isVisible = false

        var tracks = surfaceModel.tracks
        tracks[trackIndex] = transitionTrack(
            from: start,
            to: destination,
            startTime: now,
            duration: motionProfile.fadeOutDuration
        )
        surfaceModel.setTracks(tracks)
        scheduleCompletionSweep()
    }

    func clear() {
        activeTargets.removeAll(keepingCapacity: true)
        activeTargetOrder.removeAll(keepingCapacity: true)
        syncChordAppearance()
        hideAllSurfacesImmediately()
        if presentationMode == .physicalRefraction {
            surfaceModel.stopPhysicalCaptureImmediately()
        }
    }

    private func refreshVisibleGeometry() {
        guard !activeTargetOrder.isEmpty else { return }
        let now = currentTime
        finalizeCompletedTransitions(at: now)
        var tracks = surfaceModel.tracks

        for id in activeTargetOrder {
            guard let target = activeTargets[id],
                  let trackIndex = tracks.firstIndex(where: { $0.id == id }) else {
                continue
            }
            var start = tracks[trackIndex].sample(at: now)
            let targetFrame = frameForGlass(
                at: sanitizedPosition(CGFloat(target.horizontalPosition)),
                keyWidth: sanitizedKeyWidth(CGFloat(target.keyWidth))
            )
            if reduceMotionEnabled {
                start.state.frame = targetFrame
                start.state.emergence = 1
                start.state.smoothness = smoothness
                start.velocity = .zero
            }

            var destination = start.state
            destination.frame = targetFrame
            destination.visibility = 1
            destination.emergence = 1
            destination.smoothness = smoothness
            destination.isVisible = true
            tracks[trackIndex] = transitionTrack(
                from: start,
                to: destination,
                startTime: now,
                duration: motionProfile.configurationDuration
            )
        }

        surfaceModel.setTracks(tracks)
        scheduleCompletionSweep()
    }

    private func retimeVisiblePreview(_ id: GlowID) {
        guard let target = activeTargets[id],
              case .preview = id else {
            return
        }

        let now = currentTime
        finalizeCompletedTransitions(at: now)
        let targetFrame = frameForGlass(
            at: sanitizedPosition(CGFloat(target.horizontalPosition)),
            keyWidth: sanitizedKeyWidth(CGFloat(target.keyWidth))
        )
        guard let trackIndex = surfaceModel.tracks.firstIndex(where: {
            $0.id == id
        }) else {
            revealSurface(id, at: targetFrame, time: now)
            return
        }
        var start = surfaceModel.tracks[trackIndex].sample(at: now)
        guard start.state.isVisible else {
            revealSurface(id, at: targetFrame, time: now)
            return
        }

        if reduceMotionEnabled {
            start.state.frame = targetFrame
            start.state.emergence = 1
            start.state.smoothness = smoothness
            start.velocity = .zero
        } else {
            // Changing the tempo should be visible without restarting opacity or
            // snapping the shape back into the bezel. Give the current surface a
            // center-preserving width impulse so it takes one gentle breath at
            // the newly selected tempo, then settles onto the same key.
            let duration = max(motionProfile.revealDuration, 0.000_001)
            let presentationCenterVelocity = start.velocity.frame.origin.x
                + start.velocity.frame.width * 0.5
            let widthImpulse = max(start.state.frame.width, targetFrame.width)
                * 0.82 / duration
            let combinedWidthVelocity = start.velocity.frame.width + widthImpulse
            start.velocity.frame.size.width = combinedWidthVelocity
            start.velocity.frame.origin.x = presentationCenterVelocity
                - combinedWidthVelocity * 0.5
        }

        var destination = start.state
        destination.frame = targetFrame
        destination.visibility = 1
        destination.emergence = 1
        destination.smoothness = smoothness
        destination.isVisible = true

        var tracks = surfaceModel.tracks
        tracks[trackIndex] = transitionTrack(
            from: start,
            to: destination,
            startTime: now,
            duration: motionProfile.revealDuration
        )
        surfaceModel.setTracks(tracks)
        scheduleCompletionSweep()
    }

    private func nearestFadingTrackIndex(
        to targetFrame: CGRect,
        at time: TimeInterval
    ) -> Int? {
        surfaceModel.tracks.indices
            .filter { activeTargets[surfaceModel.tracks[$0].id] == nil }
            .min { left, right in
                let leftDistance = abs(
                    surfaceModel.tracks[left].sample(at: time).state.frame.midX
                        - targetFrame.midX
                )
                let rightDistance = abs(
                    surfaceModel.tracks[right].sample(at: time).state.frame.midX
                        - targetFrame.midX
                )
                return leftDistance < rightDistance
            }
    }

    private func reidentified(
        _ sample: LiquidGlassSurfaceSample,
        as id: GlowID
    ) -> LiquidGlassSurfaceSample {
        var state = sample.state
        state = LiquidGlassSurfaceState(
            id: id,
            frame: state.frame,
            visibility: state.visibility,
            emergence: state.emergence,
            smoothness: state.smoothness,
            isVisible: state.isVisible
        )
        return LiquidGlassSurfaceSample(state: state, velocity: sample.velocity)
    }

    private func replaceOrAppend(
        _ track: LiquidGlassSurfaceTrack,
        in tracks: inout [LiquidGlassSurfaceTrack]
    ) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
        } else {
            tracks.append(track)
        }
    }

    private func transitionTrack(
        from start: LiquidGlassSurfaceSample,
        to destination: LiquidGlassSurfaceState,
        startTime: TimeInterval,
        duration: TimeInterval
    ) -> LiquidGlassSurfaceTrack {
        let safeDuration = duration.isFinite ? max(duration, 0) : 0
        guard safeDuration > 0 else {
            return LiquidGlassSurfaceTrack(state: destination)
        }
        let initialVelocity = boundedVelocity(
            start.velocity,
            destination: destination,
            duration: safeDuration
        )
        return LiquidGlassSurfaceTrack(
            state: start.state,
            transition: LiquidGlassSurfaceTransition(
                start: start.state,
                destination: destination,
                initialVelocity: initialVelocity,
                startTime: startTime,
                duration: safeDuration
            )
        )
    }

    private func setTracksImmediately(_ tracks: [LiquidGlassSurfaceTrack]) {
        completionTask?.cancel()
        completionTask = nil
        surfaceModel.setTracks(tracks)
    }

    private func hideAllSurfacesImmediately() {
        setTracksImmediately([])
    }

    private func finalizeCompletedTransitions(at time: TimeInterval) {
        var tracks: [LiquidGlassSurfaceTrack] = []
        var changed = false
        for track in surfaceModel.tracks {
            guard let transition = track.transition,
                  transition.isComplete(at: time) else {
                tracks.append(track)
                continue
            }
            changed = true
            if transition.destination.isVisible {
                tracks.append(
                    LiquidGlassSurfaceTrack(state: transition.destination)
                )
            }
        }
        if changed {
            surfaceModel.setTracks(tracks)
        }
    }

    private func scheduleCompletionSweep() {
        completionTask?.cancel()
        completionTask = nil
        let now = currentTime
        let nextEnd = surfaceModel.tracks.compactMap(\.transition?.endTime).min()
        guard let nextEnd else { return }
        let delay = max(nextEnd - now, 0)
        completionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.finalizeCompletedTransitions(at: self.currentTime)
            self.scheduleCompletionSweep()
        }
    }

    private var currentTime: TimeInterval {
        surfaceModel.currentTime
    }

    private var clampedUserOpacity: Float {
        let opacity = configuration.chordAppearance.opacity(
            maxOpacity,
            activeMemberCount: activeChordMemberCount
        )
        guard opacity.isFinite else { return 0.7 }
        return min(max(opacity, 0), 1)
    }

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

    private func syncChordAppearance() {
        surfaceModel.setChordAppearance(
            configuration.chordAppearance,
            activeMemberCount: activeChordMemberCount
        )
        refreshMaterial()
    }

    private var effectiveDisplayOpacity: Float {
        LiquidGlassMaterialMath.displayOpacity(
            userOpacity: clampedUserOpacity,
            reduceTransparency: reduceTransparencyEnabled,
            increaseContrast: increaseContrastEnabled
        )
    }

    private var effectivePrismaticEdgeOpacity: Float {
        LiquidGlassMaterialMath.prismaticEdgeOpacity(
            userOpacity: clampedUserOpacity,
            reduceTransparency: reduceTransparencyEnabled,
            increaseContrast: increaseContrastEnabled
        )
    }

    private var effectiveClearLensOpacity: Float {
        LiquidGlassMaterialMath.clearLensOpacity(
            userOpacity: clampedUserOpacity,
            reduceTransparency: reduceTransparencyEnabled,
            increaseContrast: increaseContrastEnabled
        )
    }

    private var effectiveLocalizedDimmingOpacity: Float {
        LiquidGlassMaterialMath.localizedDimmingOpacity(
            userOpacity: clampedUserOpacity,
            reduceTransparency: reduceTransparencyEnabled,
            increaseContrast: increaseContrastEnabled
        )
    }

    private func refreshMaterial() {
        let edgeOpacity = effectivePrismaticEdgeOpacity
        surfaceModel.setMaterial(
            bodyOpacity: effectiveDisplayOpacity,
            edgeOpacity: edgeOpacity,
            refractionStrength: configuration.refractionStrength,
            lensOpacity: effectiveClearLensOpacity,
            dimmingOpacity: effectiveLocalizedDimmingOpacity,
            chromaticDisplacement: LiquidGlassMaterialMath.chromaticDisplacement(
                edgeOpacity: edgeOpacity
            )
        )
    }

    private func sanitizedPosition(_ position: CGFloat) -> CGFloat {
        guard position.isFinite else { return 0.5 }
        return min(max(position, -0.05), 1.05)
    }

    private func sanitizedKeyWidth(_ keyWidth: CGFloat) -> CGFloat {
        guard keyWidth.isFinite else { return 1 }
        return min(max(keyWidth, 0.05), 5)
    }

    private func frameForGlass(at position: CGFloat, keyWidth: CGFloat) -> CGRect {
        LiquidGlassTransitionMath.bezelFrame(
            in: bounds,
            position: position,
            baseKeyWidth: baseKeyWidth,
            keyWidth: keyWidth,
            widthMultiplier: widthMultiplier,
            glowHeight: glowHeight,
            smoothness: smoothness
        )
    }

    private func changesGlassGeometry(
        from old: RendererConfiguration,
        to new: RendererConfiguration
    ) -> Bool {
        old.baseKeyWidth != new.baseKeyWidth
            || old.glowHeight != new.glowHeight
            || old.widthMultiplier != new.widthMultiplier
            || old.roundness != new.roundness
            || old.shapeProfile != new.shapeProfile
            || old.reduceMotion != new.reduceMotion
    }

    private func boundedVelocity(
        _ velocity: LiquidGlassSurfaceVelocity,
        destination: LiquidGlassSurfaceState,
        duration: TimeInterval
    ) -> LiquidGlassSurfaceVelocity {
        guard duration.isFinite, duration > 0 else { return .zero }

        let horizontalLimit = max(bounds.width * 6, 600)
        let widthLimit = max(bounds.width * 8, 800)
        let verticalLimit = max(bounds.height * 8, 240)
        let widthVelocity = clamped(
            velocity.frame.width,
            magnitude: widthLimit
        )
        let centerVelocity = clamped(
            velocity.frame.origin.x + velocity.frame.width * 0.5,
            magnitude: horizontalLimit
        )
        let destinationIsVisible = destination.isVisible

        return LiquidGlassSurfaceVelocity(
            frame: CGRect(
                x: centerVelocity - widthVelocity * 0.5,
                y: clamped(velocity.frame.origin.y, magnitude: verticalLimit),
                width: widthVelocity,
                height: clamped(velocity.frame.height, magnitude: verticalLimit)
            ),
            visibility: destinationIsVisible
                ? clamped(velocity.visibility, magnitude: 8)
                : min(clamped(velocity.visibility, magnitude: 8), 0),
            emergence: clamped(velocity.emergence, magnitude: 8),
            smoothness: clamped(velocity.smoothness, magnitude: 8)
        )
    }

    private func clamped(_ value: CGFloat, magnitude: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, -magnitude), magnitude)
    }

    private func clamped(_ value: Double, magnitude: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -magnitude), magnitude)
    }

    // Stable test seams: SwiftUI intentionally hides the private system glass
    // implementation, so tests inspect the bounded source state and timeline.
    var testSurfaceSnapshots: [LiquidGlassSurfaceSnapshot] {
        surfaceModel.samples(at: currentTime).map {
            $0.snapshot(
                materialOpacity: surfaceModel.materialOpacity,
                edgeOpacity: surfaceModel.prismaticEdgeOpacity,
                lensOpacity: surfaceModel.clearLensOpacity,
                dimmingOpacity: surfaceModel.localizedDimmingOpacity,
                chromaticDisplacement: surfaceModel.chromaticDisplacement
            )
        }
    }

    var testActiveTransitionDurations: [TimeInterval] {
        surfaceModel.tracks.compactMap(\.transition?.duration)
    }

    var testTimelineIsActive: Bool { surfaceModel.isTimelineActive }
    var testUsesNativeBellShape: Bool { true }
    var testHostingViewCount: Int { hostingView == nil ? 0 : 1 }
    var testMotionProfile: LiquidGlassMotionProfile { motionProfile }
    var testUsesSystemSelectedTimelineCadence: Bool { true }
    var testActiveTargetIDs: [GlowID] { activeTargetOrder }
    var testPresentationMode: LiquidGlassPresentationMode { presentationMode }
    var testExtendsGlassBelowVisibleBaseline: Bool {
        presentationMode.extendsGlassBelowVisibleBaseline
    }
    var testShapeProfile: SurfaceShapeProfile { configuration.shapeProfile }
    var testSolidBlackFillOpacity: Double? {
        guard presentationMode == .solidBlack,
              surfaceModel.samples(at: currentTime).contains(where: {
                  LiquidGlassSolidBlackMaterial.isPresent(
                      isVisible: $0.state.isVisible,
                      emergence: $0.state.emergence
                  )
              }) else {
            return nil
        }
        return surfaceModel.solidBlackFillOpacity
    }
    var testPhysicalCaptureIsReady: Bool {
        surfaceModel.physicalCaptureIsReady
    }
    var testRefractionStrength: Double {
        surfaceModel.refractionStrength
    }
    var testChordSurfaceStyle: ChordSurfaceStyle {
        surfaceModel.chordSurfaceStyle
    }
    var testActiveChordMemberCount: Int {
        surfaceModel.activeChordMemberCount
    }
    var testMaterialOpacity: Double {
        surfaceModel.materialOpacity
    }
    var testVisibleSurfaceGroupCount: Int {
        let frames: [CGRect] = surfaceModel.samples(at: currentTime).compactMap { sample in
            guard sample.state.isVisible, sample.state.visibility > 0.000_1 else {
                return nil
            }
            return sample.state.frame
        }
        if surfaceModel.chordSurfaceStyle == .independent {
            return frames.count
        }
        return LiquidGlassTransitionMath.connectedFrameGroups(
            frames,
            spacing: surfaceModel.spacing
        ).count
    }
}
#endif
