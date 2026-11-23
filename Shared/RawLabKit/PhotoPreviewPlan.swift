import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PhotoPreviewResourceSpec: Equatable, Sendable {
    public let url: URL
    public let maximumBytes: Int?
    public let expectedSHA256: String?
    public let missingFileOnFailure: Bool

    public init(
        url: URL,
        maximumBytes: Int? = nil,
        expectedSHA256: String? = nil,
        missingFileOnFailure: Bool = false
    ) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.expectedSHA256 = expectedSHA256
        self.missingFileOnFailure = missingFileOnFailure
    }
}

public struct PhotoPreviewResourceRequirement: Equatable, Sendable {
    public let url: URL
    public let expectedHexDigest: String
    public let maximumBytes: Int?
    public let missingFileOnFailure: Bool

    public init(
        url: URL,
        expectedHexDigest: String,
        maximumBytes: Int? = nil,
        missingFileOnFailure: Bool = false
    ) {
        self.url = url
        self.expectedHexDigest = expectedHexDigest
        self.maximumBytes = maximumBytes
        self.missingFileOnFailure = missingFileOnFailure
    }
}

public enum PhotoPreviewOutputFormat: Equatable, Sendable {
    case png
    case jpeg(quality: CGFloat)
}

public enum PhotoPreviewThumbnailCodec {
    public static func encodeThumbnail(
        _ image: CGImage,
        maxEdge: Int,
        format: PhotoPreviewOutputFormat
    ) throws -> Data {
        let scale = min(1, Double(maxEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let utType: UTType
        let properties: CFDictionary?
        switch format {
        case .png:
            utType = .png
            properties = nil
        case .jpeg(let quality):
            utType = .jpeg
            properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        }
        guard let small = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, small, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }

    public static func decodeCGImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            // 不兜 NSImage/UIImage 懒解码：损坏半写文件可能返回 0×0 空白图，必须立即可解出 CGImage。
            return nil
        }
        return cgImage
    }
}

public struct PhotoPreviewPlan: Equatable, Sendable {
    public static let hdrLookMaximumBytes = 32 * 1024 * 1024

    public let key: PhotoPreviewCacheKey
    public let resourceRequirements: [PhotoPreviewResourceRequirement]

    public init(key: PhotoPreviewCacheKey, resourceRequirements: [PhotoPreviewResourceRequirement]) {
        self.key = key
        self.resourceRequirements = resourceRequirements
    }

    public static func resolveHDRResourceSpecs(
        hdr: HDRSettings,
        hdrLookDirectory: URL = HDRLookSettings.directory,
        profileURLProvider: (HDRCameraProfile) throws -> URL
    ) throws -> [PhotoPreviewResourceSpec] {
        guard hdr.lookSettings.isValid else { throw CocoaError(.fileNoSuchFile) }
        var specs: [PhotoPreviewResourceSpec] = []
        if let asset = hdr.lookSettings.asset(in: hdrLookDirectory) {
            guard asset.isFileURL else { throw CocoaError(.fileNoSuchFile) }
            specs.append(PhotoPreviewResourceSpec(
                url: asset,
                maximumBytes: hdrLookMaximumBytes,
                expectedSHA256: hdr.lookSettings.sha256,
                missingFileOnFailure: true
            ))
        } else {
            guard hdr.lookSettings.isDefault else { throw CocoaError(.fileNoSuchFile) }
        }
        if let profile = hdr.cameraDevelopmentSettings.cameraProfile {
            specs.append(PhotoPreviewResourceSpec(url: try profileURLProvider(profile)))
        }
        return specs
    }

    public static func evaluateResources(
        _ specs: [PhotoPreviewResourceSpec],
        includeFileIdentity: Bool,
        digestCache: FileDigestCache = .shared,
        onHash: (() -> Void)? = nil
    ) throws -> (requirements: [PhotoPreviewResourceRequirement], encodedResources: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var requirements: [PhotoPreviewResourceRequirement] = []
        requirements.reserveCapacity(specs.count)

        if includeFileIdentity {
            var fingerprints: [Data] = []
            fingerprints.reserveCapacity(specs.count)
            for spec in specs {
                let result: (identity: OriginalFileIdentity, digest: Data, hex: String, fingerprint: FileStatFingerprint)
                do {
                    result = try digestCache.digestAndFingerprint(
                        for: spec.url,
                        maximumBytes: spec.maximumBytes,
                        returnOnUnstableThirdAttempt: true,
                        onHash: onHash
                    )
                } catch {
                    if spec.missingFileOnFailure { throw CocoaError(.fileNoSuchFile) }
                    throw error
                }
                if let expected = spec.expectedSHA256, result.hex != expected {
                    throw CocoaError(.fileNoSuchFile)
                }
                requirements.append(PhotoPreviewResourceRequirement(
                    url: spec.url,
                    expectedHexDigest: result.hex,
                    maximumBytes: spec.maximumBytes,
                    missingFileOnFailure: spec.missingFileOnFailure
                ))
                let identity = try encoder.encode(result.identity)
                fingerprints.append(identity + result.digest)
            }
            return (requirements, try encoder.encode(fingerprints))
        }

        var hexDigests: [String] = []
        hexDigests.reserveCapacity(specs.count)
        for spec in specs {
            let hex: String
            do {
                hex = try digestCache.digest(for: spec.url, maximumBytes: spec.maximumBytes)
            } catch {
                if spec.missingFileOnFailure { throw CocoaError(.fileNoSuchFile) }
                throw error
            }
            if let expected = spec.expectedSHA256, hex != expected {
                throw CocoaError(.fileNoSuchFile)
            }
            requirements.append(PhotoPreviewResourceRequirement(
                url: spec.url,
                expectedHexDigest: hex,
                maximumBytes: spec.maximumBytes,
                missingFileOnFailure: spec.missingFileOnFailure
            ))
            hexDigests.append(hex)
        }
        return (requirements, try encoder.encode(hexDigests))
    }

    public static func areResourcesCurrent(
        _ requirements: [PhotoPreviewResourceRequirement],
        digestCache: FileDigestCache = .shared
    ) throws -> Bool {
        for requirement in requirements {
            let hex: String
            do {
                hex = try digestCache.digest(for: requirement.url, maximumBytes: requirement.maximumBytes)
            } catch {
                if requirement.missingFileOnFailure { throw CocoaError(.fileNoSuchFile) }
                throw error
            }
            guard hex == requirement.expectedHexDigest else {
                if requirement.missingFileOnFailure { throw CocoaError(.fileNoSuchFile) }
                return false
            }
        }
        return true
    }

    public func areResourcesCurrent(digestCache: FileDigestCache = .shared) throws -> Bool {
        try Self.areResourcesCurrent(resourceRequirements, digestCache: digestCache)
    }
}

public enum EditedPhotoPreviewCoordinator {
    public static func loadOrRenderThumbnail<Plan>(
        cache: EditedPhotoPreviewCache,
        makePlan: () throws -> Plan,
        isCurrent: (Plan) throws -> Bool,
        key: (Plan) -> PhotoPreviewCacheKey,
        decodeCached: (Data) -> Bool = { PhotoPreviewThumbnailCodec.decodeCGImage($0) != nil },
        render: (Plan) throws -> CGImage,
        encode: (CGImage) throws -> Data,
        onCacheHit: (() -> Void)? = nil,
        onCacheMissWrite: ((Plan, Data) -> Void)? = nil
    ) throws -> (key: PhotoPreviewCacheKey, data: Data, cgImage: CGImage?) {
        try Task.checkCancellation()
        let plan = try makePlan()
        guard try isCurrent(plan) else { throw AdjustmentCommitError.expired }
        let cacheKey = key(plan)
        if let cached = try? cache.read(cacheKey), decodeCached(cached) {
            try Task.checkCancellation()
            guard try isCurrent(plan) else { throw AdjustmentCommitError.expired }
            onCacheHit?()
            return (cacheKey, cached, nil)
        }
        let cgImage = try render(plan)
        try Task.checkCancellation()
        guard try isCurrent(plan) else { throw AdjustmentCommitError.expired }
        let data = try encode(cgImage)
        try Task.checkCancellation()
        guard try isCurrent(plan) else { throw AdjustmentCommitError.expired }
        try? cache.write(data, for: cacheKey)
        onCacheMissWrite?(plan, data)
        return (cacheKey, data, cgImage)
    }

    @discardableResult
    public static func acceptThumbnail<Plan>(
        cache: EditedPhotoPreviewCache,
        makePlan: () throws -> Plan,
        isCurrent: (Plan) throws -> Bool,
        key: (Plan) -> PhotoPreviewCacheKey,
        encode: () throws -> Data,
        onAccepted: ((Plan, Data) -> Void)? = nil
    ) throws -> (key: PhotoPreviewCacheKey, data: Data) {
        let plan = try makePlan()
        guard try isCurrent(plan) else { throw AdjustmentCommitError.expired }
        let data = try encode()
        try Task.checkCancellation()
        guard try isCurrent(plan) else { throw AdjustmentCommitError.expired }
        let cacheKey = key(plan)
        try cache.write(data, for: cacheKey)
        onAccepted?(plan, data)
        return (cacheKey, data)
    }
}
