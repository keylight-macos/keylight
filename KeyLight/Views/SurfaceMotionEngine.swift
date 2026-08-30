import CoreGraphics
import Foundation

struct SurfaceMotionState: Identifiable, Equatable, Sendable {
    let id: GlowID
    var frame: CGRect = .zero
    var visibility: Double = 0
    var emergence: CGFloat = 0
    var smoothness: CGFloat = 0.7069
    var isVisible = false
}

struct SurfaceMotionVelocity: Equatable, Sendable {
    var frame = CGRect.zero
    var visibility: Double = 0
    var emergence: CGFloat = 0
    var smoothness: CGFloat = 0

    static let zero = SurfaceMotionVelocity()
}

struct SurfaceMotionSample: Equatable, Sendable {
    var state: SurfaceMotionState
    var velocity: SurfaceMotionVelocity
}

struct SurfaceMotionTransition: Equatable, Sendable {
    let start: SurfaceMotionState
    let destination: SurfaceMotionState
    let initialVelocity: SurfaceMotionVelocity
    let startTime: TimeInterval
    let duration: TimeInterval

    var endTime: TimeInterval { startTime + duration }

    func isComplete(at time: TimeInterval) -> Bool {
        !duration.isFinite || duration <= 0 || time >= endTime
    }

    func sample(at time: TimeInterval) -> SurfaceMotionSample {
        guard duration.isFinite, duration > 0 else {
            return SurfaceMotionSample(state: destination, velocity: .zero)
        }

        let progress = min(max((time - startTime) / duration, 0), 1)
        if progress >= 1 {
            return SurfaceMotionSample(state: destination, velocity: .zero)
        }

        let x = Self.hermite(
            start.frame.origin.x,
            destination.frame.origin.x,
            initialVelocity.frame.origin.x,
            duration,
            progress
        )
        let y = Self.hermite(
            start.frame.origin.y,
            destination.frame.origin.y,
            initialVelocity.frame.origin.y,
            duration,
            progress
        )
        let width = Self.hermite(
            start.frame.width,
            destination.frame.width,
            initialVelocity.frame.width,
            duration,
            progress
        )
        let height = Self.hermite(
            start.frame.height,
            destination.frame.height,
            initialVelocity.frame.height,
            duration,
            progress
        )
        let visibility = Self.hermite(
            start.visibility,
            destination.visibility,
            initialVelocity.visibility,
            duration,
            progress
        )
        let emergence = Self.hermite(
            start.emergence,
            destination.emergence,
            initialVelocity.emergence,
            duration,
            progress
        )
        let smoothness = Self.hermite(
            start.smoothness,
            destination.smoothness,
            initialVelocity.smoothness,
            duration,
            progress
        )

        return SurfaceMotionSample(
            state: SurfaceMotionState(
                id: start.id,
                frame: CGRect(
                    x: x.value,
                    y: y.value,
                    width: max(finite(width.value, fallback: destination.frame.width), 1),
                    height: max(finite(height.value, fallback: destination.frame.height), 1)
                ),
                visibility: Self.unitValue(
                    visibility.value,
                    fallback: destination.visibility
                ),
                emergence: Self.unitValue(
                    emergence.value,
                    fallback: destination.emergence
                ),
                smoothness: Self.unitValue(
                    smoothness.value,
                    fallback: destination.smoothness
                ),
                isVisible: start.isVisible || destination.isVisible
            ),
            velocity: SurfaceMotionVelocity(
                frame: CGRect(
                    x: x.velocity,
                    y: y.velocity,
                    width: width.velocity,
                    height: height.velocity
                ),
                visibility: visibility.velocity,
                emergence: emergence.velocity,
                smoothness: smoothness.velocity
            )
        )
    }

    private static func hermite(
        _ start: CGFloat,
        _ destination: CGFloat,
        _ initialVelocity: CGFloat,
        _ duration: TimeInterval,
        _ progress: Double
    ) -> (value: CGFloat, velocity: CGFloat) {
        let result = hermite(
            Double(start),
            Double(destination),
            Double(initialVelocity),
            duration,
            progress
        )
        return (CGFloat(result.value), CGFloat(result.velocity))
    }

    private static func hermite(
        _ start: Double,
        _ destination: Double,
        _ initialVelocity: Double,
        _ duration: TimeInterval,
        _ progress: Double
    ) -> (value: Double, velocity: Double) {
        let safeStart = start.isFinite ? start : 0
        let safeDestination = destination.isFinite ? destination : safeStart
        let safeVelocity = initialVelocity.isFinite ? initialVelocity : 0
        let safeDuration = duration.isFinite ? max(duration, 0.000_001) : 0.000_001
        let t = min(max(progress, 0), 1)
        let t2 = t * t
        let t3 = t2 * t

        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let value = h00 * safeStart
            + h10 * safeDuration * safeVelocity
            + h01 * safeDestination

        let dh00 = 6 * t2 - 6 * t
        let dh10 = 3 * t2 - 4 * t + 1
        let dh01 = -6 * t2 + 6 * t
        let velocity = (
            dh00 * safeStart
                + dh10 * safeDuration * safeVelocity
                + dh01 * safeDestination
        ) / safeDuration

        return (value, velocity)
    }

    private static func unitValue(
        _ value: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return min(max(fallback, 0), 1) }
        return min(max(value, 0), 1)
    }

    private static func unitValue(
        _ value: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard value.isFinite else { return min(max(fallback, 0), 1) }
        return min(max(value, 0), 1)
    }

    private func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? value : fallback
    }
}

struct SurfaceMotionTrack: Identifiable, Equatable, Sendable {
    let id: GlowID
    var state: SurfaceMotionState
    var transition: SurfaceMotionTransition?

    init(id: GlowID) {
        self.id = id
        state = SurfaceMotionState(id: id)
    }

    init(
        state: SurfaceMotionState,
        transition: SurfaceMotionTransition? = nil
    ) {
        id = state.id
        self.state = state
        self.transition = transition
    }

    func sample(at time: TimeInterval) -> SurfaceMotionSample {
        transition?.sample(at: time)
            ?? SurfaceMotionSample(state: state, velocity: .zero)
    }
}

/// Renderer-independent owner for persistent surface tracks and monotonic time.
/// Material-specific presenters remain free to choose how those tracks draw.
struct SurfaceMotionEngine: Sendable {
    private let clock: any SurfaceMotionClock
    private(set) var tracks: [SurfaceMotionTrack] = []

    init(clock: any SurfaceMotionClock = SystemSurfaceMotionClock()) {
        self.clock = clock
    }

    var currentTime: TimeInterval { clock.now() }
    var hasActiveTransitions: Bool {
        tracks.contains { $0.transition != nil }
    }

    mutating func setTracks(_ tracks: [SurfaceMotionTrack]) {
        var seen: Set<GlowID> = []
        self.tracks = tracks.filter { seen.insert($0.id).inserted }
    }

    func samples(at time: TimeInterval) -> [SurfaceMotionSample] {
        tracks.map { $0.sample(at: time) }
    }
}
