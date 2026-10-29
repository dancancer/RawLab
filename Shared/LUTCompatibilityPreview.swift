import Foundation
import CoreGraphics
import Combine
import UniformTypeIdentifiers

struct LUTPreviewSource {
    let name: String
    let copyTo: (URL) throws -> Void
    init(name: String, copyTo: @escaping (URL) throws -> Void) { self.name = name; self.copyTo = copyTo }
    init(url: URL) {
        name = url.lastPathComponent
        copyTo = { destination in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: destination)
        }
    }
}

enum LUTPreviewError: LocalizedError {
    case failed, unsupportedSource, conditions, dimensions
    var errorDescription: String? {
        switch self {
        case .failed: return L10n.text("无法生成预览，请检查照片、LUT 和颜色配置。")
        case .unsupportedSource: return L10n.text("此配置与预览照片类型不匹配，请更换照片或配置。")
        case .conditions: return L10n.text("请先确认同源图片、处理条件和参考来源。")
        case .dimensions: return L10n.text("参考图与预览的比例或尺寸不一致，仅可目视比较。")
        }
    }
}

struct LUTPreviewFrame {
    let pixels: Data
    let width: Int
    let height: Int
    let stride: Int
    var image: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    init(_ buffer: sony2fuji_buffer) throws {
        guard let data = buffer.data, buffer.width > 0, buffer.height > 0, buffer.width <= 1024, buffer.height <= 1024,
              buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8, buffer.stride_bytes == buffer.width * 4,
              buffer.size_bytes == Int(buffer.stride_bytes) * Int(buffer.height) else { throw LUTPreviewError.failed }
        pixels = Data(bytes: data, count: buffer.size_bytes)
        width = Int(buffer.width); height = Int(buffer.height); stride = Int(buffer.stride_bytes)
    }
    func compare(to reference: Self, conditions: LUTReferenceConditions) throws -> LUTPreviewComparison {
        guard conditions.canCompare else { throw LUTPreviewError.conditions }
        guard width == reference.width && height == reference.height else { throw LUTPreviewError.dimensions }
        let text = String(decoding: try JSONEncoder().encode(conditions), as: UTF8.self)
        var blob = sony2fuji_blob()
        defer { sony2fuji_release_blob(&blob) }
        let status = pixels.withUnsafeBytes { a in
            reference.pixels.withUnsafeBytes { b in
                var left = nativeBuffer(a.baseAddress!), right = reference.nativeBuffer(b.baseAddress!)
                return text.withCString { sony2fuji_compare_lut_previews(&left, &right, $0, &blob) }
            }
        }
        guard status == SONY2FUJI_STATUS_OK, let data = blob.data else { throw LUTPreviewError.conditions }
        return try JSONDecoder().decode(LUTPreviewComparison.self, from: Data(bytes: data, count: blob.size_bytes))
    }
    private func nativeBuffer(_ data: UnsafeRawPointer) -> sony2fuji_buffer {
        sony2fuji_buffer(data: UnsafeMutableRawPointer(mutating: data), size_bytes: pixels.count,
            width: UInt32(width), height: UInt32(height), stride_bytes: UInt32(stride), pixel_format: SONY2FUJI_PIXEL_RGBA8)
    }
    static func loadReference(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var input = sony2fuji_buffer(), output = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&input); sony2fuji_release_buffer(&output) }
        guard url.path.withCString({ sony2fuji_load_display_image($0, &input) }) == SONY2FUJI_STATUS_OK else { throw LUTPreviewError.failed }
        let session = try LUTPreviewWorker.newSession()
        defer { sony2fuji_session_destroy(session) }
        var request = LUTPreviewWorker.request()
        LUTPreviewWorker.setDisplayInput(&request, input)
        guard sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_OK else { throw LUTPreviewError.failed }
        return try Self(output)
    }
}

// 仅由串行预览队列使用；源文件副本与 native 会话一起释放。
final class LUTPreviewWorker {
    let directory: URL
    let sourceURL: URL
    let displayInput: Bool
    private let lutURL: URL
    private var session: OpaquePointer?
    private var display = sony2fuji_buffer()

    init(lut: URL, source: LUTPreviewSource) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RawLab-LUT-preview-\(UUID().uuidString)", isDirectory: true)
        sourceURL = directory.appendingPathComponent("source").appendingPathExtension((source.name as NSString).pathExtension)
        lutURL = directory.appendingPathComponent("look").appendingPathExtension(lut.pathExtension)
        let type = UTType(filenameExtension: sourceURL.pathExtension)
        displayInput = type?.conforms(to: .image) == true && type?.conforms(to: .rawImage) != true
        session = try Self.newSession()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LUTPreviewSource(url: lut).copyTo(lutURL)
            try source.copyTo(sourceURL)
            if displayInput {
                guard sourceURL.path.withCString({ sony2fuji_load_display_image($0, &display) }) == SONY2FUJI_STATUS_OK else { throw LUTPreviewError.failed }
            }
        } catch {
            sony2fuji_release_buffer(&display); sony2fuji_session_destroy(session); session = nil
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    deinit {
        sony2fuji_release_buffer(&display); sony2fuji_session_destroy(session)
        try? FileManager.default.removeItem(at: directory)
    }
    static func newSession() throws -> OpaquePointer {
        var session: OpaquePointer?
        guard sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, let session else { throw LUTPreviewError.failed }
        var gpu = sony2fuji_gpu_config(version: SONY2FUJI_GPU_CONFIG_VERSION, struct_size: UInt32(MemoryLayout<sony2fuji_gpu_config>.size), mode: SONY2FUJI_GPU_OFF)
        guard sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK,
              sony2fuji_session_set_processing_version(session, SONY2FUJI_PROCESSING_C5_V2) == SONY2FUJI_STATUS_OK,
              sony2fuji_session_set_raw_exposure_mode(session, SONY2FUJI_EXPOSURE_SCENE) == SONY2FUJI_STATUS_OK else {
            sony2fuji_session_destroy(session); throw LUTPreviewError.failed
        }
        return session
    }
    static func request() -> sony2fuji_request {
        var request = sony2fuji_request()
        request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = UInt32(MemoryLayout<sony2fuji_request>.size)
        request.input_type = SONY2FUJI_INPUT_RAW; request.wb_mode = SONY2FUJI_WB_CAMERA; request.wb_mul = (1,1,1,1)
        request.brightness = 1; request.contrast = 1; request.saturation = 1; request.temperature = 6500
        request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = 512
        request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGBA8
        return request
    }
    static func setDisplayInput(_ request: inout sony2fuji_request, _ buffer: sony2fuji_buffer) {
        request.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER
        request.input_pixels = buffer.data.map(UnsafeRawPointer.init)
        request.input_width = buffer.width; request.input_height = buffer.height
        request.input_pixel_format = buffer.pixel_format; request.input_color_space = SONY2FUJI_COLOR_SRGB
    }
    func render(_ draft: LUTCompatibility?) throws -> LUTPreviewFrame {
        if let draft, !draft.supportsPreview(displayInput: displayInput) { throw LUTPreviewError.unsupportedSource }
        var request = Self.request(), output = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&output) }
        if displayInput { Self.setDisplayInput(&request, display) }
        request.lut_strength = draft == nil ? 0 : 1
        let configuration = try draft?.previewRequest()
        let status = sourceURL.path.withCString { sourcePath in
            request.input_path = sourcePath
            return lutURL.path.withCString { lookPath in
                request.lut_path = draft == nil ? nil : lookPath
                if let configuration {
                    return configuration.withCString { sony2fuji_preview_lut_compatibility(session, &request, $0, &output) }
                }
                return sony2fuji_process(session, &request, &output)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { throw LUTPreviewError.failed }
        return try LUTPreviewFrame(output)
    }
}

private final class LUTPreviewCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class LUTCompatibilityPreviewModel: ObservableObject {
    @Published var frames: [String: LUTPreviewFrame] = [:]
    @Published var failures: [String: String] = [:]
    @Published var baseline: LUTPreviewFrame?
    @Published var reference: LUTPreviewFrame?
    @Published var referenceName: String?
    @Published var sourceName: String?
    @Published var displayInput = false
    @Published var isLoading = false
    @Published var notice: String?
    @Published var comparison: LUTPreviewComparison?
    @Published var comparisonError: String?
    private let queue = DispatchQueue(label: "rawlab.lut-compatibility-preview", qos: .userInitiated)
    private var worker: LUTPreviewWorker?
    private var sourceTask = LUTPreviewCancellation()
    private var selectedTask = LUTPreviewCancellation()
    private var referenceTask = LUTPreviewCancellation()
    private var comparisonTask = LUTPreviewCancellation()

    static func key(_ draft: LUTCompatibility) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? String(decoding: encoder.encode(draft.contract), as: UTF8.self)) ?? ""
    }
    func frame(for draft: LUTCompatibility) -> LUTPreviewFrame? { frames[Self.key(draft)] }
    func load(lut: URL, source: LUTPreviewSource, draft: LUTCompatibility) {
        sourceTask.cancel(); selectedTask.cancel(); referenceTask.cancel(); comparisonTask.cancel()
        let task = LUTPreviewCancellation(); sourceTask = task
        frames = [:]; failures = [:]; baseline = nil; reference = nil; referenceName = nil; comparison = nil; comparisonError = nil
        sourceName = source.name; notice = nil; isLoading = true
        queue.async {
            guard !task.isCancelled else { return }
            self.worker = nil
            do {
                let worker = try LUTPreviewWorker(lut: lut, source: source)
                self.worker = worker
                let baseline = try worker.render(nil)
                DispatchQueue.main.async { if !task.isCancelled { self.displayInput = worker.displayInput; self.baseline = baseline } }
                for candidate in draft.candidates ?? [] {
                    guard !task.isCancelled else { break }
                    guard let configured = draft.applying(candidate, displayInput: worker.displayInput) else { continue }
                    let key = Self.key(configured)
                    do {
                        let frame = try worker.render(configured)
                        DispatchQueue.main.async { if !task.isCancelled { self.frames[key] = frame } }
                    } catch {
                        let message = error.localizedDescription
                        DispatchQueue.main.async { if !task.isCancelled { self.failures[key] = message } }
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { if !task.isCancelled { self.notice = message } }
            }
            DispatchQueue.main.async { if !task.isCancelled { self.isLoading = false } }
        }
    }
    func preview(_ draft: LUTCompatibility) {
        selectedTask.cancel(); comparisonTask.cancel(); comparison = nil; comparisonError = nil
        guard draft.hasCompleteContract, sourceName != nil, frame(for: draft) == nil else { return }
        let task = LUTPreviewCancellation(), source = sourceTask; selectedTask = task
        let key = Self.key(draft)
        queue.async {
            guard !task.isCancelled, !source.isCancelled, let worker = self.worker else { return }
            do {
                let frame = try worker.render(draft)
                DispatchQueue.main.async { if !task.isCancelled && !source.isCancelled { self.frames[key] = frame } }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { if !task.isCancelled && !source.isCancelled { self.failures[key] = message } }
            }
        }
    }
    func loadReference(_ url: URL) {
        referenceTask.cancel(); comparisonTask.cancel()
        let task = LUTPreviewCancellation(); referenceTask = task
        reference = nil; referenceName = url.lastPathComponent; comparison = nil; comparisonError = nil
        queue.async {
            do {
                let frame = try LUTPreviewFrame.loadReference(url)
                DispatchQueue.main.async { if !task.isCancelled { self.reference = frame } }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { if !task.isCancelled { self.comparisonError = message } }
            }
        }
    }
    func compare(_ draft: LUTCompatibility, conditions: LUTReferenceConditions) {
        comparisonTask.cancel(); comparison = nil; comparisonError = nil
        guard let frame = frame(for: draft), let reference, conditions.canCompare else { return }
        let task = LUTPreviewCancellation(); comparisonTask = task
        queue.async {
            do {
                let report = try frame.compare(to: reference, conditions: conditions)
                DispatchQueue.main.async { if !task.isCancelled { self.comparison = report } }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { if !task.isCancelled { self.comparisonError = message } }
            }
        }
    }
    func close() {
        sourceTask.cancel(); selectedTask.cancel(); referenceTask.cancel(); comparisonTask.cancel()
        queue.async { self.worker = nil }
    }
}
