import RawLabKit
import UIKit
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

    init(width: Int = 8, height: Int = 4, hdrValues: [Float]? = nil, sdrValues: [Float]? = nil) throws {
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
        self.statistics = try hdr.withUnsafeBufferPointer { buf in
            try HDRStatistics.analyze(buf, width: width, height: height, stride: width * 3)
        }
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

    @MainActor static func findMTKView(in view: UIView) -> HDRMTKView? {
        if let mtk = view as? HDRMTKView { return mtk }
        for sub in view.subviews {
            if let found = findMTKView(in: sub) { return found }
        }
        return nil
    }

    @MainActor static func pumpMain(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor static func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    @MainActor static func flushDisplayIfNeeded(in view: UIView) {
        CATransaction.flush()
        if let mtk = findMTKView(in: view), mtk.pendingRedrawRequest || mtk.layer.needsDisplay() {
            mtk.layer.displayIfNeeded()
            if mtk.pendingRedrawRequest {
                mtk.draw()
            }
        }
    }

    @MainActor static func main() {
        setbuf(stdout, nil)
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

        // 1. Quantized headroom
        try check(HDRDisplayState.quantizedHeadroom(1.0) == 1.0, "iOS quantizedHeadroom preserves 1.0")
        try check(HDRDisplayState.quantizedHeadroom(1.002) == 1.0, "iOS quantizedHeadroom rounds 1.002 down to 1.0")
        try check(HDRDisplayState.quantizedHeadroom(1.003) == 1.005, "iOS quantizedHeadroom rounds 1.003 up to 1.005")

        // 2. Host HDRCanvas in UIHostingController
        var simulatedHeadroom = 2.0
        HDRCanvasTesting.isActiveOverride = { true }
        HDRCanvasTesting.headroomOverride = { simulatedHeadroom }

        let linear = try TestLinearHDRImage(width: 16, height: 8)
        let state = HDRDisplayState()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let host = UIHostingController(rootView: HDRCanvas(presentation: linear, state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }

        let mtk = try findMTKView(in: host.view) ?? { throw Failure.assertion("HDRMTKView not found in UIHostingController") }()
        try check(mtk.isPaused && mtk.enableSetNeedsDisplay, "iOS MTKView is configured with isPaused=true and enableSetNeedsDisplay=true")

        try check(waitUntil {
            flushDisplayIfNeeded(in: host.view)
            return mtk.drawCallCount >= 1 && linear.planeAccessCount == 1 && !mtk.isHidden && !mtk.pendingRedrawRequest && state.headroom == 2.0
        }, "iOS HDRCanvas completes off-main-thread Metal prepare and draws")
        flushDisplayIfNeeded(in: host.view)
        try check(linear.allPlaneAccessesOffMainThread, "iOS HDRLinearDisplayImage plane prep runs off the main thread")
        try check(linear.rgba16FCallCount == 0, "iOS HDRLinearDisplayImage uses Metal compute instead of CPU rgba16F")

        mtk.resetDrawCallCount()
        pumpMain(seconds: 0.4)
        try check(mtk.drawCallCount == 0, "iOS idle HDRCanvas produces 0 draw calls over 0.4s (actual: \(mtk.drawCallCount))")

        // Mode & falseColor triggers
        mtk.resetDrawCallCount()
        state.mode = .sdr
        try check(waitUntil {
            flushDisplayIfNeeded(in: host.view)
            return mtk.drawCallCount >= 1
        }, "iOS changing state.mode triggers a redraw")
        mtk.resetDrawCallCount()
        pumpMain(seconds: 0.2)
        try check(mtk.drawCallCount == 0, "iOS returns to 0 idle draws after mode change")

        mtk.resetDrawCallCount()
        state.falseColor = true
        try check(waitUntil {
            flushDisplayIfNeeded(in: host.view)
            return mtk.drawCallCount >= 1
        }, "iOS changing state.falseColor triggers a redraw")

        // Fallback spy off-main-thread + headroom quantization
        let spy = SpyFallbackHDRImage()
        state.mode = .automatic
        state.falseColor = false
        mtk.resetDrawCallCount()
        host.rootView = HDRCanvas(presentation: spy, state: state)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try check(waitUntil {
            flushDisplayIfNeeded(in: host.view)
            return spy.callSnapshot.count >= 1 && mtk.drawCallCount >= 1
        }, "iOS updating presentation triggers off-main-thread rgba16F fallback and redraw")
        try check(spy.callSnapshot.allSatisfy { !$0.isMainThread },
                  "iOS fallback HDRDisplayImage.rgba16F runs strictly off the main thread")

        let callsBeforeJitter = spy.callSnapshot.count
        simulatedHeadroom = 2.002
        NotificationCenter.default.post(name: UIScreen.brightnessDidChangeNotification, object: nil)
        pumpMain(seconds: 0.15)
        try check(spy.callSnapshot.count == callsBeforeJitter,
                  "iOS sub-0.005 headroom noise (2.0 -> 2.002) does not re-run tone mapping")

        simulatedHeadroom = 4.0
        mtk.resetDrawCallCount()
        NotificationCenter.default.post(name: UIScreen.brightnessDidChangeNotification, object: nil)
        try check(waitUntil {
            flushDisplayIfNeeded(in: host.view)
            return spy.callSnapshot.count > callsBeforeJitter && mtk.drawCallCount >= 1
        }, "iOS UIScreen.brightnessDidChangeNotification with headroom change triggers re-prepare and redraw")

        // Metal compute parity on iOS
        let device = MTLCreateSystemDefaultDevice()!
        let testPixels: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0.002, 0.005, 0.001), SIMD3(0.002, 0.005, 0.001)),
            (SIMD3(0.5, 0.4, 0.3), SIMD3(0.5, 0.4, 0.3)),
            (SIMD3(6.0, 5.0, 4.0), SIMD3(1.0, 1.0, 1.0))
        ]
        var hdrFlat: [Float] = []
        var sdrFlat: [Float] = []
        for (h, s) in testPixels {
            hdrFlat.append(contentsOf: [h.x, h.y, h.z])
            sdrFlat.append(contentsOf: [s.x, s.y, s.z])
        }
        let parityImage = try TestLinearHDRImage(width: testPixels.count, height: 1, hdrValues: hdrFlat, sdrValues: sdrFlat)
        for params in [
            HDRDisplayParameters(headroom: 1.0, mode: .automatic, falseColor: false),
            HDRDisplayParameters(headroom: 2.0, mode: .automatic, falseColor: false),
            HDRDisplayParameters(headroom: 4.0, mode: .sdr, falseColor: false),
            HDRDisplayParameters(headroom: 2.0, mode: .automatic, falseColor: true)
        ] {
            let gpuData = try HDRCanvasRenderer.metalRGBA16F(linear: parityImage, parameters: params, device: device)
            try gpuData.withUnsafeBytes { raw in
                let gpuWords = raw.bindMemory(to: UInt16.self)
                for i in 0..<testPixels.count {
                    let expectedVec = try HDRDisplayMath.pixel(
                        hdr: testPixels[i].0, sdr: testPixels[i].1,
                        contentHeadroom: parityImage.statistics.headroom, parameters: params
                    )
                    let expectedBits = try HDRDisplayMath.half(expectedVec)
                    for c in 0..<3 {
                        let gVal = Float(Float16(bitPattern: gpuWords[i * 4 + c]))
                        let eVal = Float(Float16(bitPattern: expectedBits[c]))
                        let tol = max(0.002, abs(eVal) * 0.002)
                        try check(abs(gVal - eVal) <= tol,
                                  "iOS Metal parity pixel \(i) ch \(c) for \(params): gpu=\(gVal) cpu=\(eVal)")
                    }
                }
            }
        }

        // #506 Stale-generation concurrency race (.automatic -> .sdr [blocked] -> .automatic)
        simulatedHeadroom = 2.0
        let raceState = HDRDisplayState()
        let slowSpy = SlowRGBA16FSpy()
        defer { slowSpy.releaseSDR.signal() }
        let raceWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let raceHost = UIHostingController(rootView: HDRCanvas(presentation: slowSpy, state: raceState))
        raceWindow.rootViewController = raceHost
        raceWindow.makeKeyAndVisible()
        raceHost.view.frame = raceWindow.bounds
        raceHost.view.layoutIfNeeded()
        defer { raceWindow.isHidden = true; raceWindow.rootViewController = nil }

        let raceMTK = try findMTKView(in: raceHost.view) ?? { throw Failure.assertion("HDRMTKView not found for iOS race test") }()
        try check(waitUntil {
            flushDisplayIfNeeded(in: raceHost.view)
            return slowSpy.callSnapshot.count >= 1 && raceMTK.drawCallCount >= 1 && !raceMTK.pendingRedrawRequest && raceState.headroom == 2.0
        }, "iOS race test initial .automatic render completes")
        pumpMain(seconds: 0.1)
        flushDisplayIfNeeded(in: raceHost.view)

        raceMTK.resetDrawCallCount()
        raceState.mode = .sdr
        try check(waitUntil { slowSpy.sdrEntered.wait(timeout: .now()) == .success },
                  "iOS race test enters blocked rgba16F(.sdr)")

        raceState.mode = .automatic
        pumpMain(seconds: 0.15)
        flushDisplayIfNeeded(in: raceHost.view)
        let callsBeforeRelease = slowSpy.callSnapshot.count
        let drawsBeforeRelease = raceMTK.drawCallCount

        slowSpy.releaseSDR.signal()
        let releaseDeadline = Date().addingTimeInterval(0.3)
        while Date() < releaseDeadline {
            flushDisplayIfNeeded(in: raceHost.view)
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let callsAfter = slowSpy.callSnapshot.count
        let drawsAfter = raceMTK.drawCallCount
        try check(callsBeforeRelease == 2 && callsAfter == 2 && drawsBeforeRelease == 0 && drawsAfter == 0,
                  "iOS stale .sdr completion after .automatic cache hit does not overwrite or redraw (calls=\(callsBeforeRelease)->\(callsAfter), draws=\(drawsBeforeRelease)->\(drawsAfter))")
    }
}
