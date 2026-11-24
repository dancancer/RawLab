import Foundation
import zlib

public enum DiagnosticZipError: Error, Sendable {
    case compressionFailed
    case entryTooLarge
}

public struct DiagnosticZipEntry: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public init(name: String, text: String) {
        self.name = name
        self.data = Data(text.utf8)
    }
}

/// Minimal standard PKZIP (Deflate / Store) writer using system zlib.
/// Produces standard archives readable by Finder, Explorer, unzip, Python zipfile, and Android ZipInputStream.
public enum DiagnosticZipArchive {
    public static func build(entries: [DiagnosticZipEntry]) throws -> Data {
        var output = Data()
        var centralDirectory = Data()
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = (1 << 5) | 1 // 1980-01-01 deterministic timestamp

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            guard entry.data.count <= 32 * 1024 * 1024, nameBytes.count <= Int(UInt16.max) else {
                throw DiagnosticZipError.entryTooLarge
            }
            let uncompressedSize = UInt32(entry.data.count)
            let crc = computeCRC32(entry.data)
            let compressed = try deflateRaw(entry.data)
            let useDeflate = !entry.data.isEmpty && compressed.count < entry.data.count
            let payload = useDeflate ? compressed : entry.data
            let method: UInt16 = useDeflate ? 8 : 0
            let compressedSize = UInt32(payload.count)
            let localHeaderOffset = UInt32(output.count)

            // Local file header (signature 0x04034b50)
            output.appendUInt32LE(0x04034b50)
            output.appendUInt16LE(20)               // version needed (2.0)
            output.appendUInt16LE(0x0800)           // UTF-8 filename flag (bit 11)
            output.appendUInt16LE(method)
            output.appendUInt16LE(dosTime)
            output.appendUInt16LE(dosDate)
            output.appendUInt32LE(crc)
            output.appendUInt32LE(compressedSize)
            output.appendUInt32LE(uncompressedSize)
            output.appendUInt16LE(UInt16(nameBytes.count))
            output.appendUInt16LE(0)                // extra field length
            output.append(nameBytes)
            output.append(payload)

            // Central directory header (signature 0x02014b50)
            centralDirectory.appendUInt32LE(0x02014b50)
            centralDirectory.appendUInt16LE(20)     // version made by
            centralDirectory.appendUInt16LE(20)     // version needed
            centralDirectory.appendUInt16LE(0x0800) // UTF-8 filename flag
            centralDirectory.appendUInt16LE(method)
            centralDirectory.appendUInt16LE(dosTime)
            centralDirectory.appendUInt16LE(dosDate)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(compressedSize)
            centralDirectory.appendUInt32LE(uncompressedSize)
            centralDirectory.appendUInt16LE(UInt16(nameBytes.count))
            centralDirectory.appendUInt16LE(0)      // extra length
            centralDirectory.appendUInt16LE(0)      // comment length
            centralDirectory.appendUInt16LE(0)      // disk number
            centralDirectory.appendUInt16LE(0)      // internal attrs
            centralDirectory.appendUInt32LE(0)      // external attrs
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(nameBytes)
        }

        let centralOffset = UInt32(output.count)
        let centralSize = UInt32(centralDirectory.count)
        let count = UInt16(entries.count)
        output.append(centralDirectory)

        // End of central directory record (signature 0x06054b50)
        output.appendUInt32LE(0x06054b50)
        output.appendUInt16LE(0)
        output.appendUInt16LE(0)
        output.appendUInt16LE(count)
        output.appendUInt16LE(count)
        output.appendUInt32LE(centralSize)
        output.appendUInt32LE(centralOffset)
        output.appendUInt16LE(0)
        return output
    }

    private static func computeCRC32(_ data: Data) -> UInt32 {
        let initial = zlib.crc32(0, nil, 0)
        if data.isEmpty { return UInt32(initial) }
        return data.withUnsafeBytes { rawBuffer -> UInt32 in
            guard let base = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return UInt32(initial)
            }
            return UInt32(zlib.crc32(initial, base, uInt(data.count)))
        }
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw DiagnosticZipError.compressionFailed }
        defer { deflateEnd(&stream) }

        let bound = Int(deflateBound(&stream, uLong(data.count))) + 64
        var compressed = Data(count: bound)
        let status: Int32 = data.withUnsafeBytes { inputRaw in
            compressed.withUnsafeMutableBytes { outputRaw in
                guard let inPtr = inputRaw.bindMemory(to: Bytef.self).baseAddress,
                      let outPtr = outputRaw.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_MEM_ERROR
                }
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inPtr)
                stream.avail_in = uInt(data.count)
                stream.next_out = outPtr
                stream.avail_out = uInt(bound)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw DiagnosticZipError.compressionFailed }
        compressed.count = Int(stream.total_out)
        return compressed
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
