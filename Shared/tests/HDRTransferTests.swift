import Foundation

@main enum HDRTransferTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
    static func main() throws {
        var source = HDRSettings(); source.exposure = 1; source.temperature = 10000; source.tint = 42
        source.contrast = -25; source.highlights = 50; source.shadows = 20; source.saturation = -30
        source.geometry.quarterTurns = 1
        let payload = try HDRAdjustmentTransfer.capture(settings: source, identifier: "hdr-source", processingVersion: 2, scope: .all)
        check(payload.payloadVersion == 2 && payload.scopeVersion == 2 && payload.source.hdrProcessingVersion == 1,
            "HDR payload lost its independent version")
        check(payload[.temperature] == nil && payload[.hdrTemperature] == .number(10000) && payload[.hdrTint] == .number(42),
            "relative WB was stored as RAW Kelvin")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: data)
        let unchanged = try HDRAdjustmentTransfer.prepare(payload: decoded, target: source)
        check(unchanged == source, "copying identical logical values created a false history change")
        let target = try HDRAdjustmentTransfer.prepare(payload: decoded, target: HDRSettings())
        let deltas = [target.exposure-source.exposure, target.contrast-source.contrast, target.highlights-source.highlights,
            target.shadows-source.shadows, target.saturation-source.saturation]
        check(deltas.allSatisfy { abs($0) <= 1e-12 } && target.geometry == source.geometry &&
            target.temperature == source.temperature && target.tint == source.tint,
            "HDR payload round-trip changed UI scale or geometry")
        do { _ = try HDRAdjustmentTransfer.legacyPayload(payload); fatalError("relative HDR WB was applied to an SDR/RAW target") }
        catch AdjustmentTransferError.incompatible {}
        let exposure = try HDRAdjustmentTransfer.capture(settings: source, identifier: "hdr-source", processingVersion: 2, scope: .custom([.exposure]))
        let compatible = try HDRAdjustmentTransfer.legacyPayload(exposure)
        check(compatible.payloadVersion == 1 && compatible.source.hdrProcessingVersion == nil && compatible[.exposure] == .number(1),
            "common-value transfer changed mode or lost compatibility")
        let v1 = try AdjustmentTransferPayload(source: .init(identifier: "old", isRaw: true, processingVersion: 1, recipe: nil),
            values: [AdjustmentTransferField.exposure.rawValue: .number(2)])
        check(v1.payloadVersion == 1, "old payload was automatically upgraded")
        let fromOld = try HDRAdjustmentTransfer.prepare(payload: v1, target: source)
        check(fromOld.exposure == 2 && fromOld.temperature == 10000 && fromOld.mode == .hdr, "v1 common transfer replaced HDR context")
        let invalid = try AdjustmentTransferPayload(source: v1.source, values: [AdjustmentTransferField.exposure.rawValue: .number(8)])
        do { _ = try HDRAdjustmentTransfer.prepare(payload: invalid, target: source); fatalError("HDR destination silently clamped out-of-range input") }
        catch AdjustmentTransferError.incompatible {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdjustmentPresetStore(directory: directory)
        let preset = try store.create(name: "HDR preset", payload: payload)
        check(preset.payload.payloadVersion == 2 && preset.payload.source.hdrProcessingVersion == 1, "preset stripped HDR source context")
        let neutral=HDRSettings()
        let forSDR=try HDRAdjustmentTransfer.batchPayload(settings:neutral,identifier:"source",processingVersion:2,targetIsHDR:false)
        check(!forSDR.fields.contains(where:\.isHDRRelative),"neutral HDR WB must leave another family's WB unchanged")
        let forHDR=try HDRAdjustmentTransfer.batchPayload(settings:neutral,identifier:"source",processingVersion:2,targetIsHDR:true)
        check(forHDR.fields.contains(.hdrTemperature) && forHDR.fields.contains(.cropWidth),"HDR target did not receive complete HDR snapshot")
        var nonneutral=neutral; nonneutral.tint=15
        let unsupported=try HDRAdjustmentTransfer.batchPayload(settings:nonneutral,identifier:"source",processingVersion:2,targetIsHDR:false)
        do { _ = try HDRAdjustmentTransfer.legacyPayload(unsupported); fatalError("nonneutral relative WB silently applied to another family") }
        catch AdjustmentTransferError.incompatible {}
        print("PASS HDR v2 payload, relative WB identity, mixed-mode preflight and preset persistence")
    }
}
