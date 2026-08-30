import AppKit
import CoreMedia
import CoreVideo
import MetalKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Screen capture is requested only after the user selects the physical effect
/// and explicitly presses the permission button in Settings.
enum ScreenCaptureAuthorization {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    @discardableResult
    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum PhysicalCaptureState: String, CaseIterable, Codable, Sendable {
    case idle
    case starting
    case active
    case gracePeriod
    case stopping
    case permissionRequired
    case failed

    var displayName: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .starting: String(localized: "Starting")
        case .active: String(localized: "Active")
        case .gracePeriod: String(localized: "Stopping soon")
        case .stopping: String(localized: "Stopping")
        case .permissionRequired: String(localized: "Permission required")
        case .failed: String(localized: "Fallback")
        }
    }
}

#if compiler(>=6.2)
enum PhysicalRefractionOptics {
    static let defaultStrength = 1.0
    static let strengthRange = 0.5...2.5
    static let baselineTransmissionLimit: CGFloat = 26
    static let reflectionLimit: CGFloat = 20

    static func sanitizedStrength(_ value: Double) -> Double {
        guard value.isFinite else { return defaultStrength }
        return min(
            max(value, strengthRange.lowerBound),
            strengthRange.upperBound
        )
    }

    /// Increasing strength represents a longer path through the same N-BK7
    /// material. The sampling bound grows with that path so the new upper range
    /// does not simply clamp back to the original 26-point displacement.
    static func transmissionLimit(for strength: Double) -> CGFloat {
        baselineTransmissionLimit * sanitizedStrength(strength)
    }

    static func opticalMargin(for strength: Double) -> CGFloat {
        max(
            transmissionLimit(for: strength),
            reflectionLimit
        ) + 2
    }
}

@available(macOS 26.0, *)
struct PhysicalRefractionSurfaceView: NSViewRepresentable {
    let snapshots: [LiquidGlassSurfaceSnapshot]
    let bodyOpacity: Double
    let edgeStrength: Double
    let refractionStrength: Double
    let stopGeneration: UInt
    let onCaptureReadinessChanged: @MainActor (Bool) -> Void
    let onCaptureStateChanged: @MainActor (PhysicalCaptureState) -> Void

    func makeNSView(context: Context) -> PhysicalRefractionMetalView {
        let view = PhysicalRefractionMetalView(frame: .zero)
        view.onCaptureReadinessChanged = onCaptureReadinessChanged
        view.onCaptureStateChanged = onCaptureStateChanged
        view.update(
            snapshots: snapshots,
            bodyOpacity: bodyOpacity,
            edgeStrength: edgeStrength,
            refractionStrength: refractionStrength,
            stopGeneration: stopGeneration
        )
        return view
    }

    func updateNSView(
        _ nsView: PhysicalRefractionMetalView,
        context: Context
    ) {
        nsView.onCaptureReadinessChanged = onCaptureReadinessChanged
        nsView.onCaptureStateChanged = onCaptureStateChanged
        nsView.update(
            snapshots: snapshots,
            bodyOpacity: bodyOpacity,
            edgeStrength: edgeStrength,
            refractionStrength: refractionStrength,
            stopGeneration: stopGeneration
        )
    }

    static func dismantleNSView(
        _ nsView: PhysicalRefractionMetalView,
        coordinator: Void
    ) {
        nsView.stopCapture()
    }
}

@available(macOS 26.0, *)
@MainActor
final class PhysicalRefractionMetalView: MTKView, MTKViewDelegate {
    private struct Uniforms {
        // width, height, captured strip height, saved opacity control
        var viewport = SIMD4<Float>(repeating: 0)
        // optical depth scale, edge strength, drawable width, drawable height
        var optics = SIMD4<Float>(repeating: 0)
        // path-length multiplier, transmission offset limit, reserved, reserved
        var tuning = SIMD4<Float>(repeating: 0)
        // active surface count, reserved, reserved, reserved
        var counts = SIMD4<UInt32>(repeating: 0)
    }

    private struct Surface {
        // x, top y, width, height in overlay points (top-left coordinates)
        var frame = SIMD4<Float>(repeating: 0)
        // visibility, emergence, smoothness, horizontal flow
        var optical = SIMD4<Float>(repeating: 0)
    }

    private struct FrameResources {
        let uniforms: any MTLBuffer
        let surfaces: any MTLBuffer
    }

    private static let maximumSurfaceCount = 32
    private static let bufferedFrameCount = 3
    private static let uniformStride = 256

    private let commandQueue: (any MTLCommandQueue)?
    private let pipelineState: (any MTLRenderPipelineState)?
    private let textureCache: CVMetalTextureCache?
    private var initializationFailure: String?
    private let capture = ScreenBackdropCapture()
    private let frameResourceSemaphore = DispatchSemaphore(
        value: bufferedFrameCount
    )
    private var frameResources: [FrameResources] = []
    private var frameResourceIndex = 0

    private var snapshots: [LiquidGlassSurfaceSnapshot] = []
    private var bodyOpacity: Double = 0.7
    private var edgeStrength: Double = 0.5
    private var refractionStrength = PhysicalRefractionOptics.defaultStrength
    private var captureIsReady = false
    private var captureDisplayID: CGDirectDisplayID?
    private var captureOverlayHeight: CGFloat = 0
    private var geometryUpdateIsScheduled = false
    private var forceCaptureOnNextGeometryUpdate = false
    private var captureStopTask: Task<Void, Never>?
    private var captureState: PhysicalCaptureState = .idle
    private var cachedFrameSequence: UInt64?
    private var cachedImageTexture: CVMetalTexture?
    private var cachedTexture: (any MTLTexture)?
    private var lastPresentedFrameSequence: UInt64?
    private var lastStopGeneration: UInt?

    var onCaptureReadinessChanged: (@MainActor (Bool) -> Void)?
    var onCaptureStateChanged: (@MainActor (PhysicalCaptureState) -> Void)?

    override var isOpaque: Bool { false }

    var rendererIsReady: Bool { initializationFailure == nil }
    var currentCaptureState: PhysicalCaptureState { captureState }

    #if DEBUG
    var testHasPendingCaptureStop: Bool { captureStopTask != nil }

    /// Arms only the lifecycle state for deterministic tests. It never creates
    /// an SCStream, captures a frame, or requests Screen Recording access.
    func testArmCaptureAsActive() {
        captureStopTask?.cancel()
        captureStopTask = nil
        captureDisplayID = 1
        captureIsReady = true
        setCaptureState(.active)
    }

    func testBeginCaptureGracePeriod() {
        beginCaptureGracePeriod()
    }
    #endif

    override init(frame frameRect: NSRect, device: (any MTLDevice)? = nil) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        var queue: (any MTLCommandQueue)?
        var pipeline: (any MTLRenderPipelineState)?
        var cache: CVMetalTextureCache?
        var failure: String?

        if let metalDevice {
            queue = metalDevice.makeCommandQueue()
            guard queue != nil else {
                commandQueue = nil
                pipelineState = nil
                textureCache = nil
                initializationFailure = "Metal command queue unavailable"
                super.init(frame: frameRect, device: metalDevice)
                configureFrameResources()
                configureMetalView()
                return
            }

            if let library = Self.makeShaderLibrary(device: metalDevice),
               let vertex = library.makeFunction(name: "keyLightRefractionVertex"),
               let fragment = library.makeFunction(name: "keyLightRefractionFragment") {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = "KeyLight Physical Refraction"
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                do {
                    pipeline = try metalDevice.makeRenderPipelineState(
                        descriptor: descriptor
                    )
                } catch {
                    failure = "Metal pipeline unavailable: \(error.localizedDescription)"
                }
            } else {
                failure = "Compiled Physical Refraction shaders unavailable"
            }

            if failure == nil {
                let status = CVMetalTextureCacheCreate(
                    kCFAllocatorDefault,
                    nil,
                    metalDevice,
                    nil,
                    &cache
                )
                if status != kCVReturnSuccess || cache == nil {
                    failure = "Metal texture cache unavailable"
                }
            }
        } else {
            failure = "Metal device unavailable"
        }

        commandQueue = queue
        pipelineState = pipeline
        textureCache = cache
        initializationFailure = failure
        super.init(frame: frameRect, device: metalDevice)
        configureFrameResources()
        configureMetalView()
    }

    private func configureFrameResources() {
        guard initializationFailure == nil,
              let device else { return }
        let uniformLength = Self.uniformStride * Self.maximumSurfaceCount
        let surfaceLength = MemoryLayout<Surface>.stride
            * Self.maximumSurfaceCount
        var resources: [FrameResources] = []
        for index in 0..<Self.bufferedFrameCount {
            guard let uniforms = device.makeBuffer(
                length: uniformLength,
                options: .storageModeShared
            ), let surfaces = device.makeBuffer(
                length: surfaceLength,
                options: .storageModeShared
            ) else {
                initializationFailure = "Metal frame buffers unavailable"
                frameResources = []
                return
            }
            uniforms.label = "KeyLight Refraction Uniforms \(index)"
            surfaces.label = "KeyLight Refraction Surfaces \(index)"
            resources.append(FrameResources(
                uniforms: uniforms,
                surfaces: surfaces
            ))
        }
        frameResources = resources
    }

    private static func makeShaderLibrary(
        device: any MTLDevice
    ) -> (any MTLLibrary)? {
        try? device.makeDefaultLibrary(bundle: .main)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        captureStopTask?.cancel()
        capture.stop()
    }

    private func configureMetalView() {
        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        preferredFramesPerSecond = Self.preferredFrameRate(for: window?.screen)
        enableSetNeedsDisplay = true
        isPaused = true
        autoResizeDrawable = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopCapture()
        } else {
            preferredFramesPerSecond = Self.preferredFrameRate(for: window?.screen)
            scheduleGeometryUpdate(forceCapture: !snapshots.isEmpty)
        }
    }

    override func layout() {
        super.layout()
        // MTKView can ask AppKit to reconcile its backing drawable after
        // drawableSize changes. Defer that mutation until this layout pass has
        // completed so it cannot recursively enter layoutSubtreeIfNeeded.
        scheduleGeometryUpdate(forceCapture: false)
    }

    func update(
        snapshots: [LiquidGlassSurfaceSnapshot],
        bodyOpacity: Double,
        edgeStrength: Double,
        refractionStrength: Double = PhysicalRefractionOptics.defaultStrength,
        stopGeneration: UInt = 0
    ) {
        if let lastStopGeneration, lastStopGeneration != stopGeneration {
            stopCapture()
        }
        lastStopGeneration = stopGeneration
        let previouslyHadVisibleSurfaces = !self.snapshots.isEmpty
        self.snapshots = Array(
            snapshots
                .filter { $0.isVisible && $0.visibility > 0.000_1 }
                .prefix(Self.maximumSurfaceCount)
        )
        self.bodyOpacity = bodyOpacity.isFinite
            ? min(max(bodyOpacity, 0), 1)
            : 0.7
        self.edgeStrength = edgeStrength.isFinite
            ? min(max(edgeStrength, 0), 1)
            : 0.5
        self.refractionStrength =
            PhysicalRefractionOptics.sanitizedStrength(refractionStrength)

        if self.snapshots.isEmpty {
            if previouslyHadVisibleSurfaces {
                // Present one transparent frame before pausing so the last
                // refracted silhouette cannot remain in the drawable.
                setNeedsDisplay(bounds)
                beginCaptureGracePeriod()
            }
        } else {
            captureStopTask?.cancel()
            captureStopTask = nil
            if captureState == .gracePeriod {
                setCaptureState(captureIsReady ? .active : .starting)
            }
            scheduleGeometryUpdate(forceCapture: captureDisplayID == nil)
            setNeedsDisplay(bounds)
        }
    }

    func stopCapture() {
        let hadCapture = captureDisplayID != nil
        captureStopTask?.cancel()
        captureStopTask = nil
        setCaptureState(.stopping)
        captureDisplayID = nil
        captureOverlayHeight = 0
        capture.stop()
        releaseCachedTexture()
        lastPresentedFrameSequence = nil
        setCaptureReady(false)
        setCaptureState(.idle)
        if hadCapture {
            KeyLightSignposts.captureStopped()
        }
    }

    private func beginCaptureGracePeriod() {
        guard captureDisplayID != nil else { return }
        captureStopTask?.cancel()
        setCaptureState(.gracePeriod)
        captureStopTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self, self.snapshots.isEmpty else { return }
            self.stopCapture()
        }
    }

    nonisolated static func preferredFrameRate(for screen: NSScreen?) -> Int {
        guard let maximum = screen?.maximumFramesPerSecond else { return 60 }
        return maximum >= 100 ? 120 : 60
    }

    private func resizeDrawable() {
        let backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        // The silhouette is procedural, so rendering it below the window's
        // backing scale exposes the Metal pixel grid as visible stair steps.
        // Keep the captured strip bandwidth-efficient, but rasterize the
        // optical boundary at the display's actual pixel density.
        let renderScale = Self.renderScale(for: backingScale)
        layer?.contentsScale = renderScale
        drawableSize = CGSize(
            width: max(bounds.width * renderScale, 1),
            height: max(bounds.height * renderScale, 1)
        )
    }

    nonisolated static func renderScale(for backingScale: CGFloat) -> CGFloat {
        guard backingScale.isFinite else { return 2 }
        return max(backingScale, 1)
    }

    private func scheduleGeometryUpdate(forceCapture: Bool) {
        forceCaptureOnNextGeometryUpdate =
            forceCaptureOnNextGeometryUpdate || forceCapture
        guard !geometryUpdateIsScheduled else { return }
        geometryUpdateIsScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryUpdateIsScheduled = false
            guard self.window != nil else { return }
            let shouldForceCapture = self.forceCaptureOnNextGeometryUpdate
            self.forceCaptureOnNextGeometryUpdate = false
            self.resizeDrawable()
            if !self.snapshots.isEmpty {
                self.startCaptureIfNeeded(force: shouldForceCapture)
            }
        }
    }

    private func startCaptureIfNeeded(force: Bool) {
        guard rendererIsReady else {
            setCaptureState(.failed)
            setCaptureReady(false)
            return
        }
        guard ScreenCaptureAuthorization.isGranted else {
            setCaptureState(.permissionRequired)
            setCaptureReady(false)
            return
        }
        guard let screen = window?.screen,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            return
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let overlayHeight = max(bounds.height, 1)
        let heightChanged = abs(overlayHeight - captureOverlayHeight) > 2
        guard force || captureDisplayID != displayID || heightChanged else {
            return
        }

        captureDisplayID = displayID
        captureOverlayHeight = overlayHeight
        setCaptureState(.starting)
        setCaptureReady(false)
        KeyLightSignposts.captureStarted()
        capture.start(
            displayID: displayID,
            overlayHeightPoints: overlayHeight,
            readinessHandler: { [weak self] ready in
            Task { @MainActor [weak self] in
                self?.setCaptureReady(ready, failure: !ready)
            }
        }, frameHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.snapshots.isEmpty else { return }
                self.setNeedsDisplay(self.bounds)
            }
        }
        )
    }

    private func setCaptureReady(_ ready: Bool, failure: Bool = false) {
        guard captureIsReady != ready else {
            if failure,
               captureDisplayID != nil,
               captureState != .permissionRequired,
               captureState != .stopping {
                handleCaptureFailure()
            }
            return
        }
        captureIsReady = ready
        if ready {
            setCaptureState(snapshots.isEmpty ? .gracePeriod : .active)
        } else if failure,
                  captureDisplayID != nil,
                  captureState != .permissionRequired,
                  captureState != .stopping {
            handleCaptureFailure()
        }
        onCaptureReadinessChanged?(ready)
    }

    private func handleCaptureFailure() {
        let hadCapture = captureDisplayID != nil
        captureDisplayID = nil
        captureOverlayHeight = 0
        capture.stop()
        releaseCachedTexture()
        lastPresentedFrameSequence = nil
        setCaptureState(.failed)
        if hadCapture {
            KeyLightSignposts.captureStopped()
        }
    }

    private func setCaptureState(_ state: PhysicalCaptureState) {
        guard captureState != state else { return }
        captureState = state
        onCaptureStateChanged?(state)
    }

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {}

    func draw(in view: MTKView) {
        guard let renderPass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandQueue,
              let pipelineState,
              !frameResources.isEmpty else {
            return
        }
        guard frameResourceSemaphore.wait(timeout: .now()) == .success else {
            return
        }
        var committed = false
        defer {
            if !committed {
                frameResourceSemaphore.signal()
            }
        }
        let resources = frameResources[frameResourceIndex]
        frameResourceIndex = (frameResourceIndex + 1) % frameResources.count
        guard
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPass
              ) else {
            return
        }

        encoder.label = "KeyLight Physical Refraction Pass"
        encoder.setRenderPipelineState(pipelineState)
        var encodedFrameSequence: UInt64?

        if let capturedFrame = capture.latestFrame(),
           let capturedTexture = texture(for: capturedFrame) {
            encodedFrameSequence = capturedFrame.sequence
            let surfaces = makeSurfaces()
            var surfaceOffset = 0
            var uniformOffset = 0
            for group in makeSurfaceGroups(from: surfaces) {
                var uniforms = Uniforms(
                    viewport: SIMD4<Float>(
                        Float(max(bounds.width, 1)),
                        Float(max(bounds.height, 1)),
                        capturedFrame.captureHeightPoints,
                        Float(bodyOpacity)
                    ),
                    optics: SIMD4<Float>(
                        Float(0.95 + edgeStrength * 1.10),
                        Float(edgeStrength),
                        Float(max(drawableSize.width, 1)),
                        Float(max(drawableSize.height, 1))
                    ),
                    tuning: SIMD4<Float>(
                        Float(refractionStrength),
                        Float(
                            PhysicalRefractionOptics.transmissionLimit(
                                for: refractionStrength
                            )
                        ),
                        0,
                        0
                    ),
                    counts: SIMD4<UInt32>(
                        UInt32(group.surfaces.count),
                        0,
                        0,
                        0
                    )
                )
                let uniformLength = MemoryLayout<Uniforms>.stride
                withUnsafeBytes(of: &uniforms) { bytes in
                    guard let source = bytes.baseAddress else { return }
                    resources.uniforms.contents()
                        .advanced(by: uniformOffset)
                        .copyMemory(from: source, byteCount: uniformLength)
                }
                encoder.setFragmentBuffer(
                    resources.uniforms,
                    offset: uniformOffset,
                    index: 0
                )
                let groupByteCount = group.surfaces.count
                    * MemoryLayout<Surface>.stride
                group.surfaces.withUnsafeBytes { bytes in
                    if let baseAddress = bytes.baseAddress {
                        resources.surfaces.contents()
                            .advanced(by: surfaceOffset)
                            .copyMemory(
                                from: baseAddress,
                                byteCount: groupByteCount
                            )
                    }
                }
                encoder.setFragmentBuffer(
                    resources.surfaces,
                    offset: surfaceOffset,
                    index: 1
                )
                encoder.setFragmentTexture(capturedTexture, index: 0)
                if let scissor = makeScissorRect(for: group.surfaces) {
                    encoder.setScissorRect(scissor)
                }
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 3
                )
                uniformOffset += Self.uniformStride
                surfaceOffset += groupByteCount
            }
        }

        encoder.endEncoding()
        let semaphore = frameResourceSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        committed = true
        if let encodedFrameSequence,
           encodedFrameSequence != lastPresentedFrameSequence {
            if let lastPresentedFrameSequence,
               encodedFrameSequence > lastPresentedFrameSequence + 1 {
                KeyLightSignposts.frameDropped(
                    sequence: encodedFrameSequence
                )
            }
            lastPresentedFrameSequence = encodedFrameSequence
            KeyLightSignposts.framePresented(sequence: encodedFrameSequence)
        }
    }

    private func makeSurfaces() -> [Surface] {
        let viewHeight = max(bounds.height, 1)
        return snapshots.map { snapshot in
            let frame = snapshot.frame
            let centerVelocity = snapshot.horizontalVelocity
            let flowScale = max(frame.width * 4.5, 240)
            let flow = min(max(centerVelocity / flowScale, -1), 1)
            return Surface(
                frame: SIMD4<Float>(
                    Float(frame.minX),
                    Float(viewHeight - frame.maxY),
                    Float(max(frame.width, 1)),
                    Float(max(frame.height, 1))
                ),
                optical: SIMD4<Float>(
                    Float(min(max(snapshot.visibility, 0), 1)),
                    Float(min(max(snapshot.emergence, 0), 1)),
                    Float(min(max(snapshot.smoothness, 0), 1)),
                    Float(flow)
                )
            )
        }
    }

    private func makeScissorRect(
        for surfaces: [Surface]
    ) -> MTLScissorRect? {
        guard !surfaces.isEmpty,
              bounds.width > 0,
              bounds.height > 0,
              drawableSize.width > 0,
              drawableSize.height > 0 else {
            return nil
        }

        let opticalMargin = PhysicalRefractionOptics.opticalMargin(
            for: refractionStrength
        )
        var pointBounds = CGRect.null
        for surface in surfaces {
            pointBounds = pointBounds.union(CGRect(
                x: CGFloat(surface.frame.x),
                y: CGFloat(surface.frame.y),
                width: CGFloat(surface.frame.z),
                height: CGFloat(surface.frame.w)
            ))
        }
        pointBounds = pointBounds
            .insetBy(dx: -opticalMargin, dy: -opticalMargin)
            .intersection(bounds)
        guard !pointBounds.isNull,
              !pointBounds.isEmpty else {
            return nil
        }

        let scaleX = drawableSize.width / bounds.width
        let scaleY = drawableSize.height / bounds.height
        let minX = max(Int(floor(pointBounds.minX * scaleX)), 0)
        let minY = max(Int(floor(pointBounds.minY * scaleY)), 0)
        let maxX = min(
            Int(ceil(pointBounds.maxX * scaleX)),
            Int(drawableSize.width)
        )
        let maxY = min(
            Int(ceil(pointBounds.maxY * scaleY)),
            Int(drawableSize.height)
        )
        guard maxX > minX, maxY > minY else { return nil }
        return MTLScissorRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private struct SurfaceGroup {
        var surfaces: [Surface]
        var bounds: CGRect
    }

    /// Groups only surfaces whose expanded optical footprints overlap. Each
    /// group gets its own draw and scissor, so distant chords never shade the
    /// empty pixels between their keys.
    private func makeSurfaceGroups(from surfaces: [Surface]) -> [SurfaceGroup] {
        let margin = PhysicalRefractionOptics.opticalMargin(
            for: refractionStrength
        )
        var groups: [SurfaceGroup] = []

        for surface in surfaces {
            let frame = CGRect(
                x: CGFloat(surface.frame.x),
                y: CGFloat(surface.frame.y),
                width: CGFloat(surface.frame.z),
                height: CGFloat(surface.frame.w)
            ).insetBy(dx: -margin, dy: -margin)
            let touchingIndices = groups.indices.filter {
                groups[$0].bounds.intersects(frame)
            }
            guard let first = touchingIndices.first else {
                groups.append(SurfaceGroup(surfaces: [surface], bounds: frame))
                continue
            }

            groups[first].surfaces.append(surface)
            groups[first].bounds = groups[first].bounds.union(frame)
            for index in touchingIndices.dropFirst().reversed() {
                groups[first].surfaces.append(contentsOf: groups[index].surfaces)
                groups[first].bounds = groups[first].bounds.union(groups[index].bounds)
                groups.remove(at: index)
            }
        }
        return groups
    }

    private func texture(
        for frame: CapturedBackdropFrame
    ) -> (any MTLTexture)? {
        if cachedFrameSequence == frame.sequence {
            return cachedTexture
        }
        guard let textureCache else { return nil }
        let pixelBuffer = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var imageTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &imageTexture
        )
        guard status == kCVReturnSuccess,
              let imageTexture,
              let texture = CVMetalTextureGetTexture(imageTexture) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            releaseCachedTexture()
            return nil
        }
        cachedFrameSequence = frame.sequence
        cachedImageTexture = imageTexture
        cachedTexture = texture
        return texture
    }

    private func releaseCachedTexture() {
        cachedFrameSequence = nil
        cachedImageTexture = nil
        cachedTexture = nil
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }
}

private struct CapturedBackdropFrame {
    let pixelBuffer: CVPixelBuffer
    let captureHeightPoints: Float
    let sequence: UInt64
}

/// Captures only the display's bottom strip. Frames stay IOSurface-backed and
/// cross into Metal through CVMetalTextureCache; KeyLight never reads, stores,
/// logs, OCRs, or transmits their pixels.
private final class ScreenBackdropCapture:
    NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable
{
    private static let transparentBlack = CGColor(
        red: 0,
        green: 0,
        blue: 0,
        alpha: 0
    )

    private let lock = NSLock()
    private let outputQueue = DispatchQueue(
        label: "com.keylight.physical-refraction.capture",
        qos: .userInteractive
    )

    private var stream: SCStream?
    private var frame: CapturedBackdropFrame?
    private var generation: UInt = 0
    private var readinessHandler: (@Sendable (Bool) -> Void)?
    private var frameHandler: (@Sendable () -> Void)?
    private var hasDeliveredReadyFrame = false
    private var frameSequence: UInt64 = 0

    func start(
        displayID: CGDirectDisplayID,
        overlayHeightPoints: CGFloat,
        readinessHandler: @escaping @Sendable (Bool) -> Void,
        frameHandler: @escaping @Sendable () -> Void
    ) {
        stop()
        guard ScreenCaptureAuthorization.isGranted else {
            readinessHandler(false)
            return
        }

        let activeGeneration = lock.withLock { () -> UInt in
            generation &+= 1
            self.readinessHandler = readinessHandler
            self.frameHandler = frameHandler
            hasDeliveredReadyFrame = false
            frame = nil
            return generation
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startStream(
                    displayID: displayID,
                    overlayHeightPoints: overlayHeightPoints,
                    generation: activeGeneration
                )
            } catch {
                self.publishReadiness(
                    false,
                    generation: activeGeneration
                )
            }
        }
    }

    func stop() {
        let oldStream = lock.withLock { () -> SCStream? in
            generation &+= 1
            let oldStream = stream
            stream = nil
            frame = nil
            hasDeliveredReadyFrame = false
            readinessHandler = nil
            frameHandler = nil
            return oldStream
        }
        if let oldStream {
            Task {
                try? await oldStream.stopCapture()
            }
        }
    }

    func latestFrame() -> CapturedBackdropFrame? {
        lock.withLock { frame }
    }

    private func startStream(
        displayID: CGDirectDisplayID,
        overlayHeightPoints: CGFloat,
        generation activeGeneration: UInt
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: {
            $0.displayID == displayID
        }) else {
            throw CaptureError.displayUnavailable
        }

        let currentPID = getpid()
        let ownApplications = content.applications.filter {
            $0.processID == currentPID
        }
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == currentPID
        }
        let filter: SCContentFilter
        if !ownApplications.isEmpty {
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
        } else if !ownWindows.isEmpty {
            // Some agent-style LSUIElement processes are absent from the
            // application list even though their overlay window is shareable.
            // Exclude those windows directly so a stale optical ridge cannot
            // feed back into the next captured frame.
            filter = SCContentFilter(
                display: display,
                excludingWindows: ownWindows
            )
        } else {
            throw CaptureError.currentProcessUnavailable
        }

        let displayWidth = CGFloat(display.width)
        let displayHeight = CGFloat(display.height)
        let captureHeight = min(
            max(overlayHeightPoints + 80, 180),
            displayHeight
        )
        let sourceRect = CGRect(
            x: 0,
            y: max(displayHeight - captureHeight, 0),
            width: displayWidth,
            height: captureHeight
        )

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        // One output pixel per logical point is half Retina on the common 2x
        // display while remaining crisp enough for a 120-point optical strip.
        configuration.width = max(Int(displayWidth.rounded(.up)), 1)
        configuration.height = max(Int(captureHeight.rounded(.up)), 1)
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: 30
        )
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.backgroundColor = Self.transparentBlack
        configuration.shouldBeOpaque = false

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: outputQueue
        )

        let shouldStart = lock.withLock { () -> Bool in
            guard generation == activeGeneration else { return false }
            self.stream = stream
            return true
        }
        guard shouldStart else {
            throw CancellationError()
        }
        try await stream.startCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let update = lock.withLock {
            guard self.stream === stream else {
                return (
                    handler: Optional<(@Sendable (Bool) -> Void)>.none,
                    frameHandler: Optional<(@Sendable () -> Void)>.none,
                    generation: generation
                )
            }
            frameSequence &+= 1
            frame = CapturedBackdropFrame(
                pixelBuffer: pixelBuffer,
                captureHeightPoints: Float(
                    CVPixelBufferGetHeight(pixelBuffer)
                ),
                sequence: frameSequence
            )
            let capturedFrameHandler = frameHandler
            guard !hasDeliveredReadyFrame else {
                return (
                    handler: Optional<(@Sendable (Bool) -> Void)>.none,
                    frameHandler: capturedFrameHandler,
                    generation: generation
                )
            }
            hasDeliveredReadyFrame = true
            return (readinessHandler, capturedFrameHandler, generation)
        }
        update.handler?(true)
        update.frameHandler?()
    }

    func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {
        let handler = lock.withLock {
            guard self.stream === stream else {
                return Optional<(@Sendable (Bool) -> Void)>.none
            }
            generation &+= 1
            let handler = readinessHandler
            self.stream = nil
            frame = nil
            hasDeliveredReadyFrame = false
            readinessHandler = nil
            frameHandler = nil
            return handler
        }
        handler?(false)
    }

    private func publishReadiness(
        _ ready: Bool,
        generation expectedGeneration: UInt
    ) {
        let handler = lock.withLock {
            generation == expectedGeneration ? readinessHandler : nil
        }
        handler?(ready)
    }

    private enum CaptureError: Error {
        case displayUnavailable
        case currentProcessUnavailable
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
#endif
