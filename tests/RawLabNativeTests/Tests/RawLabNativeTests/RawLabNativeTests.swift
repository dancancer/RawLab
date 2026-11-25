import Foundation
import XCTest
import RawLabKit
import RawLabNative

final class RawLabNativeTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLabNativeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testDCPCompilerRejectsMalformedDataWithSpecificError() {
        XCTAssertThrowsError(try DCPCompiler.compile(data: Data("not-a-dcp".utf8), sourceName: "bad.dcp")) { error in
            XCTAssertEqual(error as? DCPCompilerError, .malformed)
        }
    }

    func testToneCurveSamplingEvaluatesIdentityAndParametricCurve() {
        let identity = ToneCurveSettings()
        let pts = identity.sampledPoints(channel: .rgb, count: 17)
        XCTAssertEqual(pts.count, 17)
        XCTAssertEqual(pts.first?.x ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(pts.first?.y ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(pts.last?.x ?? -1, 1, accuracy: 1e-6)
        XCTAssertEqual(pts.last?.y ?? -1, 1, accuracy: 1e-6)

        var boosted = ToneCurveSettings()
        boosted.parametric.lights = 40
        let midValue = boosted.sampledParametricValue(at: 0.5)
        XCTAssertGreaterThan(midValue, 0.5)
    }

    func testLookLibraryImportRenameAndRemoveCUBE() throws {
        let cubeURL = temporaryRoot.appendingPathComponent("NeutralTest.cube")
        let cubeText = """
        #Gamma:sRGB to sRGB
        #Gamut:ITU-R BT.709 to ITU-R BT.709
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        try Data(cubeText.utf8).write(to: cubeURL)

        let libDir = temporaryRoot.appendingPathComponent("Looks", isDirectory: true)
        let library = try LookLibrary(directory: libDir)
        XCTAssertTrue(library.isReadable)
        XCTAssertTrue(library.looks.isEmpty)

        let imported = try library.importLook(from: cubeURL)
        XCTAssertEqual(imported.format, "cube")
        XCTAssertEqual(library.looks.count, 1)

        try library.rename(id: imported.id, to: "Renamed Test")
        let reloaded = try LookLibrary(directory: libDir)
        XCTAssertEqual(reloaded.looks.first?.name, "Renamed Test")

        try reloaded.remove(id: imported.id)
        XCTAssertTrue(try LookLibrary(directory: libDir).looks.isEmpty)
    }
}
