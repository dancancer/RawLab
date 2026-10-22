import Foundation

extension ProcessorExportTests {
    static func checkNativeBufferOwnership() throws {
        let processor = Sony2FujiProcessor()
        var native = sony2fuji_buffer()
        let pointer = malloc(4096)!
        pointer.initializeMemory(as: UInt8.self, repeating: 73, count: 4096)
        native.data = pointer
        native.size_bytes = 4096
        native.width = 32; native.height = 32; native.stride_bytes = 128
        native.pixel_format = SONY2FUJI_PIXEL_RGBA8
        defer { sony2fuji_release_buffer(&native) }
        let buffer = try processor.takeBuffer(&native, semantic: .display)
        check(native.data == nil && native.size_bytes == 0 && native.width == 0,
              "taking a native buffer clears the caller's ownership")
        check(buffer.data.withUnsafeBytes { $0.baseAddress == UnsafeRawPointer(pointer) },
              "native output moves into Data without a second pixel allocation")
        sony2fuji_release_buffer(&native)
        check(buffer.data.count == 4096 && buffer.data.allSatisfy { $0 == 73 } &&
              buffer.width == 32 && buffer.height == 32 && buffer.stride == 128 &&
              buffer.pixelFormat == SONY2FUJI_PIXEL_RGBA8 && buffer.semantic == .display,
              "Data retains pixels and metadata after the caller releases the empty native buffer")
    }
}
