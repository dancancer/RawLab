import RawLabKit
import SwiftUI
import MetalKit
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class HDRDisplayState: ObservableObject {
    @Published var mode = HDRPreviewMode.automatic
    @Published var falseColor = false
    @Published var retry = 0
    @Published private(set) var headroom = 1.0
    @Published private(set) var displayFailed = false

    static func quantizedHeadroom(_ raw: Double) -> Double {
        let safe = raw.isFinite ? min(65504.0, max(1.0, raw)) : 1.0
        return (safe * 200.0).rounded() / 200.0
    }

    func update(headroom: Double, failed: Bool) {
        if abs(self.headroom - headroom) > 0.004999 { self.headroom = headroom }
        if displayFailed != failed { displayFailed = failed }
    }
}

enum HDRCanvasTesting {
    static var isActiveOverride: (() -> Bool)?
    static var headroomOverride: (() -> Double)?
    static var onDraw: ((MTKView) -> Void)?
}

struct HDRCanvas: View {
    let presentation: HDRDisplayImage
    @ObservedObject var state: HDRDisplayState
    var body: some View {
        ZStack {
            Image(decorative: presentation.sdrImage, scale: 1).resizable().interpolation(.high)
            HDRMetalCanvas(presentation: presentation, state: state).id(state.retry)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

final class HDRMTKView: MTKView {
    var onEnvironmentChange: (() -> Void)?
    private(set) var drawCallCount = 0
    private(set) var pendingRedrawRequest = false

    func recordRedrawRequest() {
        pendingRedrawRequest = true
    }

    func recordDrawCall() {
        pendingRedrawRequest = false
        drawCallCount &+= 1
    }

    func resetDrawCallCount() {
        drawCallCount = 0
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onEnvironmentChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onEnvironmentChange?()
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onEnvironmentChange?()
    }
    #endif
}

private struct HDRToneMapUniforms {
    var width: UInt32
    var height: UInt32
    var contentHeadroom: Float
    var safeHeadroom: Float
    var shoulderA: Float
    var isHDR: UInt32
    var falseColor: UInt32
}

private struct LinearSourceBuffers {
    let hdr: MTLBuffer
    let sdr: MTLBuffer
    let width: Int
    let height: Int
    let contentHeadroom: Float
}

final class HDRCanvasRenderer: NSObject, MTKViewDelegate {
    var presentation: HDRDisplayImage
    let state: HDRDisplayState
    private weak var view: HDRMTKView?
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let computePipeline: MTLComputePipelineState
    private let prepareQueue = DispatchQueue(label: "com.rawlab.hdr-canvas.prepare", qos: .userInitiated)

    private var texture: MTLTexture?
    private weak var readyPresentation: AnyObject?
    private var readyParameters: HDRDisplayParameters?
    private weak var drawnPresentation: AnyObject?
    private var drawnParameters: HDRDisplayParameters?
    private weak var cachedSourcePresentation: AnyObject?
    private var cachedSourceBuffers: LinearSourceBuffers?
    private var inFlightPresentation: AnyObject?
    private var inFlightParameters: HDRDisplayParameters?
    private var generation: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct HDRUniforms {
        uint width;
        uint height;
        float contentHeadroom;
        float safeHeadroom;
        float shoulderA;
        uint isHDR;
        uint falseColor;
    };

    kernel void hdr_tonemap(
        device const float* hdr [[buffer(0)]],
        device const float* sdr [[buffer(1)]],
        constant HDRUniforms& u [[buffer(2)]],
        device atomic_uint* errorFlag [[buffer(3)]],
        texture2d<half, access::write> outTex [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.width || gid.y >= u.height) { return; }
        uint idx = (gid.y * u.width + gid.x) * 3u;
        float3 h = float3(hdr[idx], hdr[idx + 1u], hdr[idx + 2u]);
        float3 s = float3(sdr[idx], sdr[idx + 1u], sdr[idx + 2u]);
        if (!isfinite(h.x) || !isfinite(h.y) || !isfinite(h.z) ||
            !isfinite(s.x) || !isfinite(s.y) || !isfinite(s.z) ||
            !isfinite(u.contentHeadroom) || u.contentHeadroom < 1.0f) {
            atomic_store_explicit(errorFlag, 1u, memory_order_relaxed);
            return;
        }
        float y = 0.2126f * h.x + 0.7152f * h.y + 0.0722f * h.z;
        float3 p;
        if (u.falseColor != 0u) {
            if (y > u.safeHeadroom) { p = float3(1.0f, 0.0f, 0.35f); }
            else if (y > 1.0f) { p = float3(1.0f, 0.6f, 0.0f); }
            else if (y <= 0.01f) { p = float3(0.02f, 0.15f, 0.7f); }
            else { p = float3(0.35f); }
        } else {
            float3 val = (u.isHDR != 0u) ? h : s;
            if (u.isHDR != 0u && y > 1.0f && u.contentHeadroom > u.safeHeadroom) {
                float mapped = 1.0f + (y - 1.0f) / (1.0f + u.shoulderA * (y - 1.0f));
                val *= (mapped / y);
            }
            p = float3(
                0.8224619687143623f * val.x + 0.17753803128563775f * val.y,
                0.03319419885096156f * val.x + 0.9668058011490385f * val.y,
                0.01708263072112004f * val.x + 0.07239744066396347f * val.y + 0.9105199286149166f * val.z
            );
            if (u.isHDR == 0u) {
                p = clamp(p, 0.0f, 1.0f);
            }
        }
        half3 hp = half3(p);
        if (!isfinite(hp.x) || !isfinite(hp.y) || !isfinite(hp.z)) {
            atomic_store_explicit(errorFlag, 1u, memory_order_relaxed);
            return;
        }
        outTex.write(half4(hp, half(1.0h)), gid);
    }

    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex hdr_vertex(uint i [[vertex_id]]) {
        const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
        Vertex v;
        v.position = float4(p[i], 0, 1);
        v.uv = float2((p[i].x + 1) * 0.5, (1 - p[i].y) * 0.5);
        return v;
    }
    fragment half4 hdr_fragment(Vertex v [[stage_in]], texture2d<half> image [[texture(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(s, v.uv);
    }
    """

    init(presentation: HDRDisplayImage, state: HDRDisplayState, device: MTLDevice, view: HDRMTKView) throws {
        self.presentation = presentation
        self.state = state
        self.view = view
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw HDRDisplayFailure.invalidBuffer }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        guard let computeFunction = library.makeFunction(name: "hdr_tonemap"),
              let vertexFunction = library.makeFunction(name: "hdr_vertex"),
              let fragmentFunction = library.makeFunction(name: "hdr_fragment") else {
            throw HDRDisplayFailure.invalidBuffer
        }
        computePipeline = try device.makeComputePipelineState(function: computeFunction)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()

        state.$mode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.scheduleUpdate()
        }.store(in: &cancellables)
        state.$falseColor.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.scheduleUpdate()
        }.store(in: &cancellables)

        registerNotifications()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func registerNotifications() {
        let center = NotificationCenter.default
        #if os(macOS)
        let activeNames: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didChangeScreenParametersNotification
        ]
        for name in activeNames {
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                self?.scheduleUpdate()
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.releaseResources()
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = self.view?.window, (note.object as AnyObject?) === window else { return }
            self.scheduleUpdate()
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = self.view?.window, (note.object as AnyObject?) === window else { return }
            if window.occlusionState.contains(.visible) {
                self.scheduleUpdate()
            } else {
                self.releaseResources()
            }
        })
        #else
        let activeNames: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIScreen.brightnessDidChangeNotification,
            UIScreen.referenceDisplayModeStatusDidChangeNotification,
            UIScreen.capturedDidChangeNotification,
            UIScreen.modeDidChangeNotification,
            UIScene.didActivateNotification
        ]
        for name in activeNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleUpdate()
            })
        }
        let resignNames: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification
        ]
        for name in resignNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.releaseResources()
            })
        }
        #endif
    }

    private func isViewActive(_ view: MTKView) -> Bool {
        if let override = HDRCanvasTesting.isActiveOverride {
            return override()
        }
        #if os(macOS)
        return NSApp.isActive && view.window?.isVisible == true
        #else
        return UIApplication.shared.applicationState == .active && view.window != nil
        #endif
    }

    private func currentHeadroom(for view: MTKView) -> Double {
        let raw: Double
        if let override = HDRCanvasTesting.headroomOverride {
            raw = override()
        } else {
            #if os(macOS)
            raw = Double(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
            #else
            raw = Double(view.window?.windowScene?.screen.currentEDRHeadroom ?? 1)
            #endif
        }
        return HDRDisplayState.quantizedHeadroom(raw)
    }

    private func requestRedraw(_ view: MTKView) {
        (view as? HDRMTKView)?.recordRedrawRequest()
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    func releaseResources() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.releaseResources() }
            return
        }
        generation &+= 1
        inFlightPresentation = nil
        inFlightParameters = nil
        texture = nil
        readyPresentation = nil
        readyParameters = nil
        drawnPresentation = nil
        drawnParameters = nil
        cachedSourcePresentation = nil
        cachedSourceBuffers = nil
        view?.releaseDrawables()
    }

    func scheduleUpdate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleUpdate() }
            return
        }
        guard let view else { return }
        guard isViewActive(view) else {
            releaseResources()
            return
        }
        let headroom = currentHeadroom(for: view)
        let desired = HDRDisplayParameters(headroom: headroom, mode: state.mode, falseColor: state.falseColor)
        if readyPresentation !== presentation {
            texture = nil
            readyPresentation = nil
            readyParameters = nil
            drawnPresentation = nil
            drawnParameters = nil
        }
        if readyPresentation === presentation && readyParameters == desired && texture != nil {
            generation &+= 1
            inFlightPresentation = nil
            inFlightParameters = nil
            if view.isHidden {
                view.isHidden = false
                requestRedraw(view)
            } else if drawnPresentation !== presentation || drawnParameters != desired {
                requestRedraw(view)
            }
            return
        }
        prepareIfNeeded(for: desired, in: view)
    }

    private func prepareIfNeeded(for desired: HDRDisplayParameters, in view: HDRMTKView) {
        let targetPresentation = presentation
        if inFlightPresentation === targetPresentation && inFlightParameters == desired {
            return
        }
        generation &+= 1
        let gen = generation
        inFlightPresentation = targetPresentation
        inFlightParameters = desired
        let reusableSource = (cachedSourcePresentation === targetPresentation) ? cachedSourceBuffers : nil

        prepareQueue.async { [weak self, weak view, device, queue, computePipeline] in
            guard let self else { return }
            do {
                let preparedTexture: MTLTexture
                let sourceForCache: LinearSourceBuffers?
                if let linear = targetPresentation as? HDRLinearDisplayImage {
                    let source: LinearSourceBuffers
                    if let reusableSource {
                        source = reusableSource
                    } else {
                        source = try Self.makeLinearSourceBuffers(linear: linear, device: device)
                    }
                    preparedTexture = try Self.renderComputeTexture(
                        source: source,
                        parameters: desired,
                        device: device,
                        queue: queue,
                        pipeline: computePipeline
                    )
                    sourceForCache = source
                } else {
                    let data = try targetPresentation.rgba16F(desired)
                    preparedTexture = try Self.makeTexture(
                        fromRGBA16F: data,
                        width: targetPresentation.width,
                        height: targetPresentation.height,
                        device: device
                    )
                    sourceForCache = nil
                }
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.generation == gen, self.presentation === targetPresentation else { return }
                    self.inFlightPresentation = nil
                    self.inFlightParameters = nil
                    if let sourceForCache {
                        self.cachedSourcePresentation = targetPresentation
                        self.cachedSourceBuffers = sourceForCache
                    } else {
                        self.cachedSourcePresentation = nil
                        self.cachedSourceBuffers = nil
                    }
                    self.texture = preparedTexture
                    self.readyPresentation = targetPresentation
                    self.readyParameters = desired
                    view.isHidden = false
                    self.publish(headroom: desired.safeHeadroom, failed: false)
                    self.requestRedraw(view)
                }
            } catch {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.generation == gen, self.presentation === targetPresentation else { return }
                    self.inFlightPresentation = nil
                    self.inFlightParameters = nil
                    self.texture = nil
                    self.readyPresentation = nil
                    self.readyParameters = nil
                    self.drawnPresentation = nil
                    self.drawnParameters = nil
                    self.cachedSourcePresentation = nil
                    self.cachedSourceBuffers = nil
                    view.isHidden = true
                    view.releaseDrawables()
                    self.publish(headroom: desired.safeHeadroom, failed: true)
                }
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        requestRedraw(view)
        if texture == nil {
            scheduleUpdate()
        }
    }

    func draw(in view: MTKView) {
        (view as? HDRMTKView)?.recordDrawCall()
        HDRCanvasTesting.onDraw?(view)
        guard isViewActive(view) else {
            releaseResources()
            return
        }
        let headroom = currentHeadroom(for: view)
        let desired = HDRDisplayParameters(headroom: headroom, mode: state.mode, falseColor: state.falseColor)
        if readyPresentation !== presentation {
            texture = nil
            readyPresentation = nil
            readyParameters = nil
            drawnPresentation = nil
            drawnParameters = nil
        }
        if readyPresentation !== presentation || readyParameters != desired || texture == nil {
            if let mtk = view as? HDRMTKView {
                prepareIfNeeded(for: desired, in: mtk)
            }
            guard texture != nil, readyPresentation === presentation, readyParameters == desired else {
                return
            }
        } else if inFlightPresentation != nil || inFlightParameters != nil {
            generation &+= 1
            inFlightPresentation = nil
            inFlightParameters = nil
        }
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        guard let texture,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            view.isHidden = true
            view.releaseDrawables()
            texture = nil
            readyPresentation = nil
            readyParameters = nil
            drawnPresentation = nil
            drawnParameters = nil
            publish(headroom: headroom, failed: true)
            return
        }
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let framePresentation = presentation
        let frameParameters = desired
        command.addCompletedHandler { [weak self, weak view] completed in
            guard completed.status == .error else { return }
            DispatchQueue.main.async {
                guard let self, let view,
                      self.readyPresentation === framePresentation,
                      self.readyParameters == frameParameters else { return }
                view.isHidden = true
                view.isPaused = true
                view.releaseDrawables()
                self.texture = nil
                self.readyPresentation = nil
                self.readyParameters = nil
                self.drawnPresentation = nil
                self.drawnParameters = nil
                self.state.update(headroom: headroom, failed: true)
            }
        }
        command.present(drawable)
        command.commit()
        drawnPresentation = presentation
        drawnParameters = desired
        view.isHidden = false
        publish(headroom: headroom, failed: false)
    }

    private func publish(headroom: Double, failed: Bool) {
        guard abs(state.headroom - headroom) > 0.004999 || state.displayFailed != failed else { return }
        DispatchQueue.main.async { [weak state] in state?.update(headroom: headroom, failed: failed) }
    }

    private static func makeLinearSourceBuffers(linear: HDRLinearDisplayImage, device: MTLDevice) throws -> LinearSourceBuffers {
        let width = linear.width, height = linear.height
        let contentHeadroom = linear.statistics.headroom
        guard width > 0, height > 0, width <= 128_000_000 / height,
              contentHeadroom.isFinite, contentHeadroom >= 1 else {
            throw HDRDisplayFailure.invalidBuffer
        }
        let pixelFloats = width * 3
        let totalFloats = pixelFloats * height
        let byteCount = totalFloats * MemoryLayout<Float>.size
        guard let hdrMetal = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let sdrMetal = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw HDRDisplayFailure.invalidBuffer
        }
        try linear.withLinearPlanes { hdr, hdrStride, sdr, sdrStride in
            guard hdrStride >= pixelFloats, sdrStride >= pixelFloats,
                  hdr.count >= (height - 1) * hdrStride + pixelFloats,
                  sdr.count >= (height - 1) * sdrStride + pixelFloats,
                  let hdrBase = hdr.baseAddress, let sdrBase = sdr.baseAddress else {
                throw HDRDisplayFailure.invalidBuffer
            }
            let hdrDst = hdrMetal.contents().assumingMemoryBound(to: Float.self)
            let sdrDst = sdrMetal.contents().assumingMemoryBound(to: Float.self)
            if hdrStride == pixelFloats {
                memcpy(hdrDst, hdrBase, byteCount)
            } else {
                for row in 0..<height {
                    memcpy(hdrDst + row * pixelFloats, hdrBase + row * hdrStride, pixelFloats * MemoryLayout<Float>.size)
                }
            }
            if sdrStride == pixelFloats {
                memcpy(sdrDst, sdrBase, byteCount)
            } else {
                for row in 0..<height {
                    memcpy(sdrDst + row * pixelFloats, sdrBase + row * sdrStride, pixelFloats * MemoryLayout<Float>.size)
                }
            }
        }
        return LinearSourceBuffers(hdr: hdrMetal, sdr: sdrMetal, width: width, height: height, contentHeadroom: contentHeadroom)
    }

    private static func renderComputeTexture(
        source: LinearSourceBuffers,
        parameters: HDRDisplayParameters,
        device: MTLDevice,
        queue: MTLCommandQueue,
        pipeline: MTLComputePipelineState
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let outTexture = device.makeTexture(descriptor: desc),
              let errorBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw HDRDisplayFailure.invalidBuffer
        }
        errorBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee = 0
        let h = parameters.safeHeadroom
        let c = Double(source.contentHeadroom)
        let isHDR = parameters.mode == .automatic && h > 1
        let shoulderA: Float = (isHDR && c > h) ? Float((c - h) / ((h - 1.0) * (c - 1.0))) : 0
        var uniforms = HDRToneMapUniforms(
            width: UInt32(source.width),
            height: UInt32(source.height),
            contentHeadroom: source.contentHeadroom,
            safeHeadroom: Float(h),
            shoulderA: shoulderA,
            isHDR: isHDR ? 1 : 0,
            falseColor: parameters.falseColor ? 1 : 0
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source.hdr, offset: 0, index: 0)
        encoder.setBuffer(source.sdr, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<HDRToneMapUniforms>.size, index: 2)
        encoder.setBuffer(errorBuffer, offset: 0, index: 3)
        encoder.setTexture(outTexture, index: 0)
        let w = pipeline.threadExecutionWidth
        let tgH = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerThreadgroup = MTLSize(width: w, height: tgH, depth: 1)
        let threadgroups = MTLSize(
            width: (source.width + w - 1) / w,
            height: (source.height + tgH - 1) / tgH,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw HDRDisplayFailure.invalidBuffer
        }
        if errorBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee != 0 {
            throw HDRDisplayFailure.unrepresentable
        }
        return outTexture
    }

    private static func makeTexture(fromRGBA16F data: Data, width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
        guard width > 0, height > 0, data.count >= width * height * 8 else {
            throw HDRDisplayFailure.invalidBuffer
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let replacement = device.makeTexture(descriptor: desc) else {
            throw HDRDisplayFailure.invalidBuffer
        }
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            replacement.replace(
                region: MTLRegionMake2D(0, 0, desc.width, desc.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: desc.width * 8
            )
        }
        return replacement
    }

    /// Executes the exact Metal compute pipeline and reads back the `.rgba16Float` output bytes for parity verification.
    static func metalRGBA16F(linear: HDRLinearDisplayImage, parameters: HDRDisplayParameters, device: MTLDevice) throws -> Data {
        guard let queue = device.makeCommandQueue() else { throw HDRDisplayFailure.invalidBuffer }
        let library = try device.makeLibrary(source: metalSource, options: nil)
        guard let computeFunction = library.makeFunction(name: "hdr_tonemap") else {
            throw HDRDisplayFailure.invalidBuffer
        }
        let pipeline = try device.makeComputePipelineState(function: computeFunction)
        let source = try makeLinearSourceBuffers(linear: linear, device: device)
        let texture = try renderComputeTexture(source: source, parameters: parameters, device: device, queue: queue, pipeline: pipeline)
        let bytesPerRow = source.width * 8
        let byteCount = bytesPerRow * source.height
        guard let readback = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else {
            throw HDRDisplayFailure.invalidBuffer
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw HDRDisplayFailure.invalidBuffer
        }
        return Data(bytes: readback.contents(), count: byteCount)
    }
}

private func makeHDRMetalView(presentation: HDRDisplayImage, state: HDRDisplayState) -> (HDRMTKView, HDRCanvasRenderer?) {
    let view = HDRMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = .rgba16Float
    #if os(macOS)
    view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    #endif
    view.framebufferOnly = true
    view.isPaused = true
    view.enableSetNeedsDisplay = true
    view.clearColor = MTLClearColorMake(0, 0, 0, 1)
    if let layer = view.layer as? CAMetalLayer {
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.edrMetadata = nil
    }
    let renderer = view.device.flatMap { try? HDRCanvasRenderer(presentation: presentation, state: state, device: $0, view: view) }
    view.delegate = renderer
    if let renderer {
        view.onEnvironmentChange = { [weak renderer] in
            renderer?.scheduleUpdate()
        }
        renderer.scheduleUpdate()
    } else {
        view.isHidden = true
        DispatchQueue.main.async { state.update(headroom: 1, failed: true) }
    }
    return (view, renderer)
}

#if os(macOS)
private struct HDRMetalCanvas: NSViewRepresentable {
    let presentation: HDRDisplayImage
    let state: HDRDisplayState
    final class Coordinator { var renderer: HDRCanvasRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> HDRMTKView {
        let (view, renderer) = makeHDRMetalView(presentation: presentation, state: state)
        context.coordinator.renderer = renderer
        return view
    }
    func updateNSView(_ view: HDRMTKView, context: Context) {
        context.coordinator.renderer?.presentation = presentation
        context.coordinator.renderer?.scheduleUpdate()
    }
    static func dismantleNSView(_ view: HDRMTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.onEnvironmentChange = nil
        view.delegate = nil
        view.releaseDrawables()
        coordinator.renderer?.releaseResources()
        coordinator.renderer = nil
    }
}
#else
private struct HDRMetalCanvas: UIViewRepresentable {
    let presentation: HDRDisplayImage
    let state: HDRDisplayState
    final class Coordinator { var renderer: HDRCanvasRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> HDRMTKView {
        let (view, renderer) = makeHDRMetalView(presentation: presentation, state: state)
        context.coordinator.renderer = renderer
        return view
    }
    func updateUIView(_ view: HDRMTKView, context: Context) {
        context.coordinator.renderer?.presentation = presentation
        context.coordinator.renderer?.scheduleUpdate()
    }
    static func dismantleUIView(_ view: HDRMTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.onEnvironmentChange = nil
        view.delegate = nil
        view.releaseDrawables()
        coordinator.renderer?.releaseResources()
        coordinator.renderer = nil
    }
}
#endif
