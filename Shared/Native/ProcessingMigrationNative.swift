import Foundation

struct ProcessingMigrationParameters {
    let exposure: Double
    let contrast: Double
    let highlights: Double
    let shadows: Double
    let saturation: Double
    let blackPoint: Double
    let whitePoint: Double
    let vibrance: Double
    let clarity: Double
    let dehaze: Double
}

struct ProcessingMigrationOutcome {
    let accepted: Bool
    let parameters: ProcessingMigrationParameters
    let quality: ProcessingMigrationQuality

    init(_ value: sony2fuji_processing_migration_result) {
        accepted = value.disposition == Int32(SONY2FUJI_MIGRATION_ACCEPTED.rawValue)
        parameters = .init(exposure: Double(value.exposure_ev), contrast: Double(value.contrast),
            highlights: Double(value.highlights), shadows: Double(value.shadows), saturation: Double(value.saturation),
            blackPoint: Double(value.black_point), whitePoint: Double(value.white_point), vibrance: Double(value.vibrance),
            clarity: Double(value.clarity), dehaze: Double(value.dehaze))
        quality = .init(rgbRMSE: Double(value.rgb_rmse), p99Error: Double(value.p99_error),
            worstTileRMSE: Double(value.worst_tile_rmse), detailRMSE: Double(value.detail_rmse),
            evaluations: Int(value.evaluation_count))
    }
}
