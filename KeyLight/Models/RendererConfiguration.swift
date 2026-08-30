import AppKit

/// Shared, testable policy used by both renderers to guarantee that Reduce
/// Motion never schedules position or bounds animations.
enum RendererMotionPolicy {
    static func geometryDuration(
        _ requestedDuration: CFTimeInterval,
        reduceMotion: Bool
    ) -> CFTimeInterval {
        guard !reduceMotion,
              requestedDuration.isFinite,
              requestedDuration > 0 else {
            return 0
        }
        return requestedDuration
    }

    static func allowsGeometryAnimation(reduceMotion: Bool) -> Bool {
        geometryDuration(1, reduceMotion: reduceMotion) > 0
    }
}

/// Complete renderer input applied as one settings transaction.
///
/// The renderers never observe partially updated settings. Numeric values are
/// normalized at the boundary so Classic and the surface renderers receive the same
/// finite configuration without duplicating validation policy.
struct RendererConfiguration: Equatable {
    enum ColorMode: Equatable {
        case solid(NSColor)
        case positionGradient(start: NSColor, end: NSColor)
        case rainbow
        case randomPerKey
    }

    let colorMode: ColorMode
    let shapeProfile: SurfaceShapeProfile
    let baseKeyWidth: CGFloat
    let glowHeight: CGFloat
    let widthMultiplier: CGFloat
    let maximumOpacity: Float
    let refractionStrength: CGFloat
    let fadeDuration: CFTimeInterval
    let roundness: CGFloat
    let fullness: CGFloat
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool
    let randomPreviewFallbackKeyCode: UInt16
    let chordAppearance: ChordAppearance
    let powerSavingMode: PowerSavingMode
    let powerEnvironmentState: PowerEnvironmentState

    init(
        colorMode: ColorMode,
        shapeProfile: SurfaceShapeProfile = .currentWave,
        baseKeyWidth: CGFloat = 60,
        glowHeight: CGFloat = 60,
        widthMultiplier: CGFloat = 1,
        maximumOpacity: Float = 0.7,
        refractionStrength: CGFloat = 1,
        fadeDuration: CFTimeInterval = 1.5,
        roundness: CGFloat = 1,
        fullness: CGFloat = 0.5,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false,
        randomPreviewFallbackKeyCode: UInt16 = 9_999,
        chordAppearance: ChordAppearance = .default,
        powerSavingMode: PowerSavingMode = .automatic,
        powerEnvironmentState: PowerEnvironmentState = .normal
    ) {
        self.colorMode = colorMode
        self.shapeProfile = shapeProfile
        self.baseKeyWidth = Self.sanitized(
            baseKeyWidth,
            default: 60,
            range: 1 ... 500
        )
        self.glowHeight = Self.sanitized(
            glowHeight,
            default: 60,
            range: 4 ... 200
        )
        self.widthMultiplier = Self.sanitized(
            widthMultiplier,
            default: 1,
            range: 0.05 ... 5
        )
        self.maximumOpacity = Self.sanitized(
            maximumOpacity,
            default: 0.7,
            range: 0 ... 1
        )
        self.refractionStrength = Self.sanitized(
            refractionStrength,
            default: 1,
            range: 0.5 ... 2.5
        )
        self.fadeDuration = Self.sanitized(
            fadeDuration,
            default: 1,
            range: 0.05 ... 5
        )
        self.roundness = Self.sanitized(
            roundness,
            default: 1,
            range: 0 ... 1
        )
        self.fullness = Self.sanitized(
            fullness,
            default: 0.5,
            range: 0 ... 1
        )
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.randomPreviewFallbackKeyCode = randomPreviewFallbackKeyCode
        self.chordAppearance = chordAppearance.normalized
        self.powerSavingMode = powerSavingMode
        self.powerEnvironmentState = powerEnvironmentState
    }

    var automaticPowerSavingIsActive: Bool {
        powerSavingMode == .automatic
            && powerEnvironmentState.requiresFallback
    }

    func resolvedEffectStyle(for selectedStyle: EffectStyle) -> EffectStyle {
        if automaticPowerSavingIsActive,
           selectedStyle.supportedStyle == .physicalRefraction {
            return EffectStyle.systemGlass.resolvedForCurrentSystem
        }
        return selectedStyle.resolvedForCurrentSystem
    }

    static let standard = RendererConfiguration(
        colorMode: .solid(NSColor(red: 0.2, green: 0.6, blue: 1, alpha: 1))
    )

    /// Returns nil only for solid color, allowing Classic Glow to retain its
    /// existing color-array cache for the common path.
    func resolvedColorOverride(for target: GlowTarget) -> NSColor? {
        switch colorMode {
        case .solid:
            return nil
        case .positionGradient(let start, let end):
            return Self.interpolateColor(
                from: start,
                to: end,
                fraction: CGFloat(target.horizontalPosition)
            )
        case .rainbow:
            let position = CGFloat(target.horizontalPosition)
            return NSColor(
                hue: position,
                saturation: 0.9,
                brightness: 1,
                alpha: 1
            )
        case .randomPerKey:
            return Self.randomColor(
                for: target.colorReferenceKeyCode ?? randomPreviewFallbackKeyCode
            )
        }
    }

    func resolvedColor(for target: GlowTarget) -> NSColor {
        resolvedColorOverride(for: target) ?? solidColor
    }

    var solidColor: NSColor {
        switch colorMode {
        case .solid(let color):
            return color
        case .positionGradient(let start, _):
            return start
        case .rainbow, .randomPerKey:
            return NSColor(red: 0.2, green: 0.6, blue: 1, alpha: 1)
        }
    }

    private static func randomColor(for keyCode: UInt16) -> NSColor {
        let seed = UInt32(keyCode) &* 1_103_515_245 &+ 12_345
        let hue = CGFloat(seed % 10_000) / 10_000
        return NSColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1)
    }

    private static func interpolateColor(
        from: NSColor,
        to: NSColor,
        fraction: CGFloat
    ) -> NSColor {
        let t = max(0, min(1, fraction))
        let fromColor = from.usingColorSpace(.sRGB) ?? from
        let toColor = to.usingColorSpace(.sRGB) ?? to

        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        var tr: CGFloat = 0
        var tg: CGFloat = 0
        var tb: CGFloat = 0
        var ta: CGFloat = 0

        fromColor.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        toColor.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)

        return NSColor(
            red: fr + (tr - fr) * t,
            green: fg + (tg - fg) * t,
            blue: fb + (tb - fb) * t,
            alpha: fa + (ta - fa) * t
        )
    }

    private static func sanitized<T: BinaryFloatingPoint>(
        _ value: T,
        default defaultValue: T,
        range: ClosedRange<T>
    ) -> T {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
