import CoreGraphics
import Foundation
import QuartzCore

protocol SurfaceMotionClock: Sendable {
    func now() -> TimeInterval
}

struct SystemSurfaceMotionClock: SurfaceMotionClock {
    func now() -> TimeInterval {
        CACurrentMediaTime()
    }
}

struct ClosureSurfaceMotionClock: SurfaceMotionClock {
    private let reader: @Sendable () -> TimeInterval

    init(_ reader: @escaping @Sendable () -> TimeInterval) {
        self.reader = reader
    }

    func now() -> TimeInterval {
        reader()
    }
}

/// A single tempo control for every phase of the Liquid Glass interaction.
///
/// `fadeDuration` remains the literal final fade-out duration for compatibility,
/// while the shorter reveal, retarget, and travel phases scale with the same
/// value. The sublinear exponent keeps the upper end expressive without making
/// ordinary typing feel heavy.
struct LiquidGlassMotionProfile: Equatable {
    let fadeOutDuration: CFTimeInterval
    let revealDuration: CFTimeInterval
    let nearbyMorphDuration: CFTimeInterval
    let configurationDuration: CFTimeInterval
    let minimumTravelDuration: CFTimeInterval
    let maximumTravelDuration: CFTimeInterval

    init(fadeDuration: CFTimeInterval) {
        let safeFade = min(max(fadeDuration.isFinite ? fadeDuration : 1, 0.05), 5)
        let tempo = pow(safeFade, 0.55)

        fadeOutDuration = safeFade
        revealDuration = Self.clamped(0.14 * tempo, to: 0.055...0.42)
        nearbyMorphDuration = Self.clamped(0.10 * tempo, to: 0.045...0.30)
        configurationDuration = Self.clamped(0.07 * tempo, to: 0.035...0.18)
        minimumTravelDuration = Self.clamped(0.13 * tempo, to: 0.06...0.38)
        maximumTravelDuration = Self.clamped(0.24 * tempo, to: 0.075...0.64)
    }

    func travelDuration(normalizedDistance: CGFloat) -> CFTimeInterval {
        let distance: Double
        if normalizedDistance.isFinite {
            distance = min(max(Double(normalizedDistance), 0), 1)
        } else {
            distance = 0.5
        }
        let easedDistance = distance * distance * (3 - 2 * distance)
        return minimumTravelDuration
            + (maximumTravelDuration - minimumTravelDuration) * easedDistance
    }

    private static func clamped(
        _ value: CFTimeInterval,
        to range: ClosedRange<CFTimeInterval>
    ) -> CFTimeInterval {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum LiquidGlassTransitionMath {
    /// Builds a shallow, bottom-connected glass bump. Smoothness deliberately
    /// controls both the shoulder curve and the physical footprint: the low end
    /// becomes a compact key-sized lens, while the high end retains the broad
    /// flowing wave used for softer transitions.
    static func bezelFrame(
        in bounds: CGRect,
        position: CGFloat,
        baseKeyWidth: CGFloat,
        keyWidth: CGFloat,
        widthMultiplier: CGFloat,
        glowHeight: CGFloat,
        smoothness: CGFloat = 0.7069
    ) -> CGRect {
        let containerWidth = finite(bounds.width, default: 0, minimum: 0)
        let containerHeight = finite(bounds.height, default: 0, minimum: 0)
        let safePosition = min(max(finite(position, default: 0.5), -0.05), 1.05)
        let safeBaseWidth = finite(baseKeyWidth, default: 60, minimum: 1)
        let safeKeyWidth = min(max(finite(keyWidth, default: 1), 0.05), 5)
        let safeWidthMultiplier = min(max(finite(widthMultiplier, default: 1), 0.05), 5)
        let safeGlowHeight = min(max(finite(glowHeight, default: 60), 4), 200)
        let profileWidthScale = smoothnessWidthScale(smoothness)

        let maximumWidth = max(containerWidth * 1.25, 64)
        let requestedWidth = safeBaseWidth
            * safeKeyWidth
            * 4.2
            * safeWidthMultiplier
            * profileWidthScale
        let height = bezelHeight(
            glowHeight: safeGlowHeight,
            containerHeight: containerHeight
        )
        let minimumAspectRatio = 2.4 + 3.1 * profileWidthScale
        let minimumProfileWidth = max(height * minimumAspectRatio, 36)
        let width = min(
            max(requestedWidth.isFinite ? requestedWidth : maximumWidth, minimumProfileWidth),
            maximumWidth
        )
        let centerX = containerWidth * safePosition

        return CGRect(
            x: centerX - width * 0.5,
            y: -height * 0.28,
            width: width,
            height: height
        )
    }

    /// Uses most of the slider travel for compact-to-medium profiles and keeps
    /// the broadest wave at the far right. This makes the low end materially
    /// tighter instead of merely changing the curvature inside the same frame.
    static func smoothnessWidthScale(_ smoothness: CGFloat) -> CGFloat {
        let safeSmoothness = min(max(finite(smoothness, default: 0.7069), 0), 1)
        let curved = CGFloat(pow(Double(safeSmoothness), 2.15))
        return 0.36 + 0.64 * curved
    }

    /// Maps the established saved height value onto the smaller Liquid Glass
    /// visual scale. Existing themes therefore keep their data while the
    /// default 80-point setting becomes a subtle ~23-point bump. The four-point
    /// input endpoint remains a genuinely tiny four-point effect.
    static func bezelHeight(glowHeight: CGFloat, containerHeight: CGFloat) -> CGFloat {
        let safeGlowHeight = min(max(finite(glowHeight, default: 60), 4), 200)
        let safeContainerHeight = finite(containerHeight, default: 120, minimum: 0)
        let requestedHeight = 3 + safeGlowHeight * 0.25
        let maximumHeight = max(safeContainerHeight * 0.48, 4)
        return min(max(requestedHeight, 4), maximumHeight)
    }

    static func shouldMerge(_ sourceFrame: CGRect, with destinationFrame: CGRect, spacing: CGFloat) -> Bool {
        let values = [
            sourceFrame.minX,
            sourceFrame.minY,
            sourceFrame.width,
            sourceFrame.height,
            destinationFrame.minX,
            destinationFrame.minY,
            destinationFrame.width,
            destinationFrame.height,
            spacing
        ]
        guard values.allSatisfy(\.isFinite) else { return false }

        let centerDistance = abs(sourceFrame.midX - destinationFrame.midX)
        let horizontalGap = centerDistance - (sourceFrame.width + destinationFrame.width) * 0.5
        return horizontalGap <= max(spacing, 0)
    }

    /// Returns transitive left-to-right groups for surfaces whose glass
    /// boundaries touch or fall within the container spacing. The renderer
    /// uses the same groups for its neutral backing and chromatic perimeter, so
    /// adjacent held keys have one outside border and no doubled inner seam.
    static func connectedFrameGroups(
        _ frames: [CGRect],
        spacing: CGFloat
    ) -> [[Int]] {
        guard !frames.isEmpty else { return [] }

        var parents = Array(frames.indices)

        func root(of index: Int) -> Int {
            var current = index
            while parents[current] != current {
                current = parents[current]
            }
            return current
        }

        for left in frames.indices {
            for right in frames.indices where right > left {
                guard shouldMerge(
                    frames[left],
                    with: frames[right],
                    spacing: spacing
                ) else {
                    continue
                }

                let leftRoot = root(of: left)
                let rightRoot = root(of: right)
                if leftRoot != rightRoot {
                    parents[rightRoot] = leftRoot
                }
            }
        }

        var grouped: [Int: [Int]] = [:]
        for index in frames.indices {
            grouped[root(of: index), default: []].append(index)
        }

        let orderedGroups = grouped.values.map { indices in
            indices.sorted { left, right in
                let leftX = frames[left].minX.isFinite
                    ? frames[left].minX
                    : .infinity
                let rightX = frames[right].minX.isFinite
                    ? frames[right].minX
                    : .infinity
                if leftX == rightX {
                    return left < right
                }
                return leftX < rightX
            }
        }

        return orderedGroups.sorted { lhs, rhs in
            let leftX = lhs
                .map { frames[$0].minX }
                .filter(\.isFinite)
                .min() ?? .infinity
            let rightX = rhs
                .map { frames[$0].minX }
                .filter(\.isFinite)
                .min() ?? .infinity
            if leftX == rightX {
                return (lhs.min() ?? 0) < (rhs.min() ?? 0)
            }
            return leftX < rightX
        }
    }

    /// Initial width velocity for a distant retarget. Hermite integration turns
    /// this into a bounded mid-flight stretch that expands around the surface
    /// center and relaxes into the destination key.
    static func flowExpansionVelocity(
        distance: CGFloat,
        duration: CFTimeInterval,
        containerWidth: CGFloat
    ) -> CGFloat {
        guard distance.isFinite,
              duration.isFinite,
              duration > 0,
              containerWidth.isFinite,
              containerWidth > 0 else {
            return 0
        }

        let safeDistance = max(abs(distance), 0)
        let desired = safeDistance * 4.2 / duration
        let bounded = containerWidth * 3.0 / duration
        return min(desired, bounded)
    }

    private static func finite(
        _ value: CGFloat,
        default defaultValue: CGFloat,
        minimum: CGFloat? = nil
    ) -> CGFloat {
        guard value.isFinite else { return defaultValue }
        guard let minimum else { return value }
        return max(value, minimum)
    }
}

enum LiquidGlassMaterialMath {
    static let increasedContrastMaterialFloor: Float = 0.30
    static let reducedTransparencyMaterialFloor: Float = 0.45

    static func accessibilityFloor(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Float {
        if reduceTransparency {
            return reducedTransparencyMaterialFloor
        }
        if increaseContrast {
            return increasedContrastMaterialFloor
        }
        return 0
    }

    /// The normal opacity path is deliberately literal: the renderer's visible
    /// output matches the saved slider value. Accessibility options may raise
    /// that output to their required minimum, but never compress the remainder
    /// of the slider range through a permanent material floor.
    static func displayOpacity(
        userOpacity: Float,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Float {
        let safeOpacity = userOpacity.isFinite ? min(max(userOpacity, 0), 1) : 0.7
        let floor = accessibilityFloor(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
        return max(safeOpacity, floor)
    }

    /// Keeps optical edge energy independent from the frosted body. A low body
    /// opacity therefore reads as a clear lens with pronounced chromatic
    /// refraction instead of making the complete surface disappear.
    static func prismaticEdgeOpacity(
        userOpacity: Float,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Float {
        let safeOpacity = userOpacity.isFinite ? min(max(userOpacity, 0), 1) : 0.7
        let inverseOpacity = pow(1 - safeOpacity, 0.65)
        var edgeOpacity = 0.29 + 0.71 * inverseOpacity

        if increaseContrast {
            edgeOpacity += 0.08
        }
        if reduceTransparency {
            edgeOpacity = max(edgeOpacity, 0.48)
        }
        return min(max(edgeOpacity, 0), 1)
    }

    /// Clear glass carries the actual backdrop lensing. It remains strong as
    /// body opacity falls, so "transparent" means a clear, refractive lens
    /// rather than an effect that simply disappears.
    static func clearLensOpacity(
        userOpacity: Float,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Float {
        let safeOpacity = userOpacity.isFinite ? min(max(userOpacity, 0), 1) : 0.7
        let inverseOpacity = pow(1 - safeOpacity, 0.55)
        var lensOpacity = 0.66 + 0.34 * inverseOpacity

        if increaseContrast {
            lensOpacity = max(lensOpacity, 0.76)
        }
        if reduceTransparency {
            lensOpacity = min(lensOpacity, 0.72)
        }
        return min(max(lensOpacity, 0), 1)
    }

    /// Clear glass needs a localized neutral backing at higher body-opacity
    /// settings. The backing is stable rather than backdrop-adaptive, avoiding
    /// the regular material's gray-to-white appearance changes while typing.
    static func localizedDimmingOpacity(
        userOpacity: Float,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Float {
        let bodyOpacity = displayOpacity(
            userOpacity: userOpacity,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
        var dimmingOpacity = 0.015 + 0.17 * pow(bodyOpacity, 1.25)

        if increaseContrast {
            dimmingOpacity = max(dimmingOpacity, 0.12)
        }
        if reduceTransparency {
            dimmingOpacity = max(dimmingOpacity, 0.28)
        }
        return min(max(dimmingOpacity, 0), 0.36)
    }

    /// Chromatic dispersion is represented by small opposing edge offsets,
    /// never by a color band stretched across the surface.
    static func chromaticDisplacement(edgeOpacity: Float) -> CGFloat {
        let safeEdgeOpacity = edgeOpacity.isFinite
            ? min(max(edgeOpacity, 0), 1)
            : 0.5
        return 0.55 + 1.80 * CGFloat(pow(safeEdgeOpacity, 1.25))
    }

}
