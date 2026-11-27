import RawLabKit
import AppKit
import SwiftUI
import Metal
import MetalKit

private final class TestLinearHDRImage: HDRLinearDisplayImage {
    let width: Int
    let height: Int
    let statistics: HDRStatistics
    let sdrImage: CGImage
    let hdrPixels: [Float]
    let sdrPixels: [Float]
    private let lock = NSLock()
    private(set) var linearPlaneAccessThreads: [Bool] = []
    private(set) var rgba16FCallCount = 0

    init(width: Int = 8, height: Int = 4, hdrValues: [Float]? = nil, sdrValues: [Float]? = nil,
         contentHeadroom: Float = 4) throws {
        self.width = width
        self.height = height
        let count = width * height * 3
        var hdr = hdrValues ?? [Float](repeating: 0, count: count)
        var sdr = sdrValues ?? [Float](repeating: 0, count: count)
        if hdrValues == nil {
            for i in 0..<(width * height) {
                let scale = Float(i + 1) * 0.25
                hdr[i * 3] = scale
                hdr[i * 3 + 1] = scale * 0.8
                hdr[i * 3 + 2] = scale * 0.4
                sdr[i * 3] = min(1, scale * 0.5)
                sdr[i * 3 + 1] = min(1, scale * 0.4)
                sdr[i * 3 + 2] = min(1, scale * 0.2)
            }
        }
        self.hdrPixels = hdr
        self.sdrPixels = sdr
        // 统计由共享核心计算，这里只需要 Metal 内核读取的内容峰值。
        self.statistics = HDRStatistics(bins: [Double](repeating: 0, count: 256), aboveWhite: 0,
                                        headroom: contentHeadroom, pixels: width * height)
        let rgba = [UInt8](repeating: 255, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        self.sdrImage = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    var planeAccessCount: Int {
        lock.lock(); defer { lock.unlock() }
        return linearPlaneAccessThreads.count
    }

    var allPlaneAccessesOffMainThread: Bool {
        lock.lock(); defer { lock.unlock() }
        return !linearPlaneAccessThreads.isEmpty && linearPlaneAccessThreads.allSatisfy { !$0 }
    }

    func withLinearPlanes<T>(
        _ body: (_ hdr: UnsafeBufferPointer<Float>, _ hdrStrideFloats: Int,
                 _ sdr: UnsafeBufferPointer<Float>, _ sdrStrideFloats: Int) throws -> T
    ) throws -> T {
        lock.lock()
        linearPlaneAccessThreads.append(Thread.isMainThread)
        lock.unlock()
        return try hdrPixels.withUnsafeBufferPointer { hdrBuf in
            try sdrPixels.withUnsafeBufferPointer { sdrBuf in
                try body(hdrBuf, width * 3, sdrBuf, width * 3)
            }
        }
    }

    func rgba16F(_ parameters: HDRDisplayParameters) throws -> Data {
        lock.lock()
        rgba16FCallCount += 1
        lock.unlock()
        throw HDRDisplayFailure.invalidBuffer
    }
}

private final class SpyFallbackHDRImage: HDRDisplayImage {
    let width = 4
    let height = 4
    let statistics = HDRStatistics(bins: [Double](repeating: 0, count: 256), aboveWhite: 1, headroom: 4.0, pixels: 16)
    let sdrImage: CGImage
    private let lock = NSLock()
    var shouldThrow = false
    private(set) var recordedCalls: [(isMainThread: Bool, parameters: HDRDisplayParameters)] = []

    init() {
        let rgba = [UInt8](repeating: 128, count: 4 * 4 * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        self.sdrImage = CGImage(
            width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4 * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    var callSnapshot: [(isMainThread: Bool, parameters: HDRDisplayParameters)] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    func rgba16F(_ parameters: HDRDisplayParameters) throws -> Data {
        lock.lock()
        recordedCalls.append((Thread.isMainThread, parameters))
        let fail = shouldThrow
        lock.unlock()
        if fail { throw HDRDisplayFailure.nonfinite }
        var bytes = Data(count: width * height * 8)
        bytes.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt16.self)
            for i in 0..<(width * height) {
                out[i * 4] = 0x3c00
                out[i * 4 + 1] = 0x3c00
                out[i * 4 + 2] = 0x3c00
                out[i * 4 + 3] = 0x3c00
            }
        }
        return bytes
    }
}

private final class SlowRGBA16FSpy: HDRDisplayImage {
    let width = 4
    let height = 4
    let statistics = HDRStatistics(bins: [Double](repeating: 0, count: 256), aboveWhite: 1, headroom: 4.0, pixels: 16)
    let sdrImage: CGImage
    private let lock = NSLock()
    private(set) var calls: [HDRPreviewMode] = []
    let sdrEntered = DispatchSemaphore(value: 0)
    let releaseSDR = DispatchSemaphore(value: 0)
    // Signalled when the blocked .sdr call has really returned, so tests wait on the event
    // instead of guessing how long the released worker takes to resume.
    let sdrExited = DispatchSemaphore(value: 0)

    init() {
        let rgba = [UInt8](repeating: 128, count: 4 * 4 * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        self.sdrImage = CGImage(
            width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4 * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    var callSnapshot: [HDRPreviewMode] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func rgba16F(_ parameters: HDRDisplayParameters) throws -> Data {
        lock.lock()
        calls.append(parameters.mode)
        lock.unlock()
        defer { if parameters.mode == .sdr { sdrExited.signal() } }
        if parameters.mode == .sdr {
            sdrEntered.signal()
            releaseSDR.wait()
        }
        var bytes = Data(count: width * height * 8)
        bytes.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt16.self)
            for i in 0..<(width * height) {
                out[i * 4] = 0x3c00
                out[i * 4 + 1] = 0x3c00
                out[i * 4 + 2] = 0x3c00
                out[i * 4 + 3] = 0x3c00
            }
        }
        return bytes
    }
}

private func halfBitsToFloat(_ bits: UInt16) -> Float {
    let sign = UInt32(bits >> 15) << 31
    let exp = UInt32((bits >> 10) & 0x1f)
    let mant = UInt32(bits & 0x3ff)
    if exp == 0 {
        if mant == 0 { return Float(bitPattern: sign) }
        var m = mant
        var e: Int32 = 127 - 14
        while (m & 0x400) == 0 { m <<= 1; e -= 1 }
        m &= 0x3ff
        return Float(bitPattern: sign | (UInt32(e) << 23) | (m << 13))
    }
    if exp == 0x1f {
        return Float(bitPattern: sign | 0x7f80_0000 | (mant << 13))
    }
    return Float(bitPattern: sign | ((exp + 112) << 23) | (mant << 13))
}

@main struct HDRCanvasTests {
    enum Failure: Error, CustomStringConvertible {
        case assertion(String)
        var description: String {
            switch self { case .assertion(let msg): return msg }
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
        print("PASS: \(message)")
    }

    @MainActor static func findMTKView(in view: NSView) -> HDRMTKView? {
        if let mtk = view as? HDRMTKView { return mtk }
        for sub in view.subviews {
            if let found = findMTKView(in: sub) { return found }
        }
        return nil
    }

    @MainActor static func pumpStep(until limit: Date) {
        if let event = NSApp.nextEvent(matching: .any, until: limit, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    @MainActor static func pumpMain(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pumpStep(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    // The first visible frame can be followed by layout-driven frames; idle checks must start
    // from a quiet canvas. A canvas that never goes quiet still fails the following idle check.
    @MainActor static func drainPendingDraws(_ mtk: HDRMTKView, quiet: TimeInterval = 0.2, attempts: Int = 15) {
        for _ in 0..<attempts {
            mtk.resetDrawCallCount()
            pumpMain(seconds: quiet)
            if mtk.drawCallCount == 0 { return }
        }
    }

    @MainActor static func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pumpStep(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        do {
            try run()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run() throws {
        defer {
            HDRCanvasTesting.isActiveOverride = nil
            HDRCanvasTesting.headroomOverride = nil
            HDRCanvasTesting.onDraw = nil
        }

        // 1. Quantized headroom rounding
        try check(HDRDisplayState.quantizedHeadroom(1.0) == 1.0, "quantizedHeadroom preserves 1.0")
        try check(HDRDisplayState.quantizedHeadroom(1.002) == 1.0, "quantizedHeadroom rounds 1.002 down to 1.0")
        try check(HDRDisplayState.quantizedHeadroom(1.003) == 1.005, "quantizedHeadroom rounds 1.003 up to 1.005")
        try check(HDRDisplayState.quantizedHeadroom(.nan) == 1.0, "quantizedHeadroom clamps NaN to 1.0")

        // 2. Idle draw count == 0, paused MTKView, off-main-thread HDRLinearDisplayImage prep, and redraw triggers
        var simulatedHeadroom = 2.0
        HDRCanvasTesting.isActiveOverride = { true }
        HDRCanvasTesting.headroomOverride = { simulatedHeadroom }

        let linear = try TestLinearHDRImage(width: 16, height: 8)
        let state = HDRDisplayState()
        let host = NSHostingView(rootView: HDRCanvas(presentation: linear, state: state))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()

        let mtk = try findMTKView(in: host) ?? { throw Failure.assertion("HDRMTKView not found in NSHostingView") }()
        try check(mtk.isPaused && mtk.enableSetNeedsDisplay, "MTKView is configured with isPaused=true and enableSetNeedsDisplay=true")

        try check(waitUntil { mtk.drawCallCount >= 1 && linear.planeAccessCount == 1 && !mtk.isHidden },
                  "Initial HDRCanvas render completes off main thread and draws")
        try check(linear.allPlaneAccessesOffMainThread, "HDRLinearDisplayImage plane prep runs off the main thread")
        try check(linear.rgba16FCallCount == 0, "HDRLinearDisplayImage path uses Metal compute instead of CPU rgba16F")

        drainPendingDraws(mtk)
        mtk.resetDrawCallCount()
        pumpMain(seconds: 0.4)
        try check(mtk.drawCallCount == 0, "Idle HDRCanvas produces 0 draw calls over 0.4s (actual: \(mtk.drawCallCount))")

        // Mode change trigger
        mtk.resetDrawCallCount()
        state.mode = .sdr
        try check(waitUntil { mtk.drawCallCount >= 1 }, "Changing state.mode triggers a redraw")
        mtk.resetDrawCallCount()
        pumpMain(seconds: 0.2)
        try check(mtk.drawCallCount == 0, "Canvas returns to 0 idle draws after mode change")

        // False color change trigger
        mtk.resetDrawCallCount()
        state.falseColor = true
        try check(waitUntil { mtk.drawCallCount >= 1 }, "Changing state.falseColor triggers a redraw")
        mtk.resetDrawCallCount()
        pumpMain(seconds: 0.2)
        try check(mtk.drawCallCount == 0, "Canvas returns to 0 idle draws after falseColor change")

        // Resize / drawableSizeWillChange trigger does not re-upload linear planes
        let uploadsBeforeResize = linear.planeAccessCount
        mtk.resetDrawCallCount()
        mtk.delegate?.mtkView(mtk, drawableSizeWillChange: CGSize(width: 400, height: 300))
        try check(waitUntil { mtk.drawCallCount >= 1 }, "drawableSizeWillChange triggers a redraw")
        try check(linear.planeAccessCount == uploadsBeforeResize, "Resize redraw reuses cached linear source buffers")

        // 3. Fallback spy HDRDisplayImage: off-main-thread rgba16F + quantized headroom + failure recovery
        let spy = SpyFallbackHDRImage()
        state.mode = .automatic
        state.falseColor = false
        mtk.resetDrawCallCount()
        host.rootView = HDRCanvas(presentation: spy, state: state)
        host.layoutSubtreeIfNeeded()
        try check(waitUntil { spy.callSnapshot.count >= 1 && mtk.drawCallCount >= 1 },
                  "Updating presentation triggers off-main-thread rgba16F fallback and redraw")
        try check(spy.callSnapshot.allSatisfy { !$0.isMainThread },
                  "Fallback HDRDisplayImage.rgba16F runs strictly off the main thread")

        // Sub-0.005 headroom jitter must NOT trigger re-tone-mapping
        let callsBeforeJitter = spy.callSnapshot.count
        simulatedHeadroom = 2.002
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        pumpMain(seconds: 0.15)
        try check(spy.callSnapshot.count == callsBeforeJitter,
                  "Sub-0.005 headroom noise (2.0 -> 2.002) is quantized and does not re-run tone mapping")

        // Real headroom jump DOES trigger re-tone-mapping
        simulatedHeadroom = 4.0
        mtk.resetDrawCallCount()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try check(waitUntil { spy.callSnapshot.count > callsBeforeJitter && mtk.drawCallCount >= 1 },
                  "Significant headroom change triggers background re-prepare and redraw")
        try check(spy.callSnapshot.last?.parameters.headroom == 4.0,
                  "Updated headroom (4.0) reaches HDRDisplayParameters")

        // Failure sets displayFailed and hides view; replacing with valid presentation recovers cleanly
        let failingSpy = SpyFallbackHDRImage()
        failingSpy.shouldThrow = true
        host.rootView = HDRCanvas(presentation: failingSpy, state: state)
        host.layoutSubtreeIfNeeded()
        try check(waitUntil { state.displayFailed && mtk.isHidden },
                  "Render error sets displayFailed=true and hides MTKView")

        mtk.resetDrawCallCount()
        host.rootView = HDRCanvas(presentation: linear, state: state)
        host.layoutSubtreeIfNeeded()
        try check(waitUntil { !state.displayFailed && !mtk.isHidden && mtk.drawCallCount >= 1 },
                  "Replacing failed presentation clears isHidden and resumes rendering")

        // 4. Metal compute shader vs shared-core golden pixel parity. Pixels and goldens come from
        // Shared/fixtures/hdr-display-goldens-v1.json, which the core test checks bit-exact.
        let device = MTLCreateSystemDefaultDevice()!
        let goldens = try HDRDisplayGoldenSet.load("mac")
        let parityImage = try TestLinearHDRImage(width: goldens.pixelCount, height: 1, hdrValues: goldens.hdr,
                                                 sdrValues: goldens.sdr, contentHeadroom: goldens.contentHeadroom)
        let parityCases = goldens.cases.map { ($0.parameters, $0.halves) }
        for (params, expected) in parityCases {
            let gpuData = try HDRCanvasRenderer.metalRGBA16F(linear: parityImage, parameters: params, device: device)
            try check(gpuData.count == goldens.pixelCount * 8, "Metal compute output byte count matches RGBA16F")
            try gpuData.withUnsafeBytes { raw in
                let gpuWords = raw.bindMemory(to: UInt16.self)
                for i in 0..<goldens.pixelCount {
                    let expectedBits = expected[(i * 3)..<(i * 3 + 3)].map { $0 }
                    let gpuAlpha = gpuWords[i * 4 + 3]
                    try check(gpuAlpha == 0x3c00, "Metal compute alpha channel is 1.0h")
                    for c in 0..<3 {
                        let gWord = gpuWords[i * 4 + c]
                        try check(gWord & 0x7c00 != 0x7c00, "Metal output half is finite")
                        let gVal = halfBitsToFloat(gWord)
                        let eVal = halfBitsToFloat(expectedBits[c])
                        let tol = max(0.002, abs(eVal) * 0.002)
                        try check(abs(gVal - eVal) <= tol,
                                  "Metal parity pixel \(i) ch \(c) for \(params): gpu=\(gVal) cpu=\(eVal)")
                    }
                }
            }
        }

        // Unrepresentable FP16 overflow check
        let overflowImage = try TestLinearHDRImage(
            width: 1, height: 1,
            hdrValues: [100_000, 0, 0],
            sdrValues: [1, 0, 0]
        )
        var threwOverflow = false
        do {
            _ = try HDRCanvasRenderer.metalRGBA16F(
                linear: overflowImage,
                parameters: HDRDisplayParameters(headroom: 65504, mode: .automatic, falseColor: false),
                device: device
            )
        } catch HDRDisplayFailure.unrepresentable {
            threwOverflow = true
        }
        try check(threwOverflow, "Metal compute rejects FP16 overflow values with HDRDisplayFailure.unrepresentable")

        // 5. #506 Stale-generation concurrency race (.automatic -> .sdr [blocked] -> .automatic)
        simulatedHeadroom = 2.0
        let raceState = HDRDisplayState()
        let slowSpy = SlowRGBA16FSpy()
        defer { slowSpy.releaseSDR.signal() }
        let raceHost = NSHostingView(rootView: HDRCanvas(presentation: slowSpy, state: raceState))
        raceHost.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let raceWindow = NSWindow(contentRect: raceHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        raceWindow.isReleasedWhenClosed = false
        raceWindow.contentView = raceHost
        raceWindow.orderBack(nil)
        defer { raceWindow.contentView = nil; raceWindow.close() }
        raceHost.layoutSubtreeIfNeeded()

        let raceMTK = try findMTKView(in: raceHost) ?? { throw Failure.assertion("HDRMTKView not found for race test") }()
        try check(waitUntil { slowSpy.callSnapshot.count >= 1 && raceMTK.drawCallCount >= 1 },
                  "Race test initial .automatic render completes")

        drainPendingDraws(raceMTK)
        raceMTK.resetDrawCallCount()
        raceState.mode = .sdr
        try check(waitUntil { slowSpy.sdrEntered.wait(timeout: .now()) == .success },
                  "Race test enters blocked rgba16F(.sdr)")

        raceState.mode = .automatic
        pumpMain(seconds: 0.15)
        let callsBeforeRelease = slowSpy.callSnapshot.count
        let drawsBeforeRelease = raceMTK.drawCallCount

        slowSpy.releaseSDR.signal()
        try check(waitUntil { slowSpy.sdrExited.wait(timeout: .now()) == .success },
                  "Released stale rgba16F(.sdr) returns")
        // The stale result now hops back to the main queue; give it the same window as before.
        pumpMain(seconds: 0.3)
        let callsAfter = slowSpy.callSnapshot.count
        let drawsAfter = raceMTK.drawCallCount
        try check(callsBeforeRelease == 2 && callsAfter == 2 && drawsBeforeRelease == 0 && drawsAfter == 0,
                  "Stale .sdr completion after .automatic cache hit does not overwrite or redraw (calls=\(callsBeforeRelease)->\(callsAfter), draws=\(drawsBeforeRelease)->\(drawsAfter))")
    }
}
