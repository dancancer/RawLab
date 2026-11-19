import XCTest
@testable import RawLabKit

final class EditorLayoutPolicyTests: XCTestCase {
    func testSidePanelBreakpointsAndWidthClamp() {
        XCTAssertFalse(EditorLayoutPolicy.usesSidePanel(width: 390, height: 844, accessibility: false))
        XCTAssertFalse(EditorLayoutPolicy.usesSidePanel(width: 500, height: 900, accessibility: false))
        XCTAssertFalse(EditorLayoutPolicy.usesSidePanel(width: 834, height: 1100, accessibility: false))
        XCTAssertTrue(EditorLayoutPolicy.usesSidePanel(width: 1100, height: 834, accessibility: false))
        XCTAssertFalse(EditorLayoutPolicy.usesSidePanel(width: 1100, height: 834, accessibility: true))

        XCTAssertEqual(EditorLayoutPolicy.sidePanelWidth(totalWidth: 600), 288, accuracy: 0.001)
        XCTAssertEqual(EditorLayoutPolicy.sidePanelWidth(totalWidth: 1100), 336, accuracy: 0.001)
    }

    func testParameterPanelHeightRespectsBoundsAndAccessibilityRatio() {
        XCTAssertEqual(EditorLayoutPolicy.parameterPanelHeight(measuredHeight: 0, totalHeight: 800, accessibility: false), 240, accuracy: 0.001)
        XCTAssertEqual(EditorLayoutPolicy.parameterPanelHeight(measuredHeight: 600, totalHeight: 800, accessibility: false), 416, accuracy: 0.001)
        XCTAssertEqual(EditorLayoutPolicy.parameterPanelHeight(measuredHeight: 600, totalHeight: 800, accessibility: true), 496, accuracy: 0.001)
        XCTAssertEqual(EditorLayoutPolicy.parameterPanelHeight(measuredHeight: 400, totalHeight: 300, accessibility: false), 156, accuracy: 0.001)
        XCTAssertEqual(EditorLayoutPolicy.parameterPanelHeight(measuredHeight: 400, totalHeight: 160, accessibility: false), 44, accuracy: 0.001)
    }

    func testToolGridColumnsHeightsAndScrollFallback() {
        XCTAssertEqual(EditorLayoutPolicy.toolGridColumns(accessibility: false), 4)
        XCTAssertEqual(EditorLayoutPolicy.toolGridColumns(accessibility: true), 3)
        XCTAssertEqual(EditorLayoutPolicy.toolGridMinRowHeight(accessibility: false), 52)
        XCTAssertEqual(EditorLayoutPolicy.toolGridMinRowHeight(accessibility: true), 68)
        XCTAssertEqual(EditorLayoutPolicy.toolGridHeight(side: false, accessibility: false), 116)
        XCTAssertEqual(EditorLayoutPolicy.toolGridHeight(side: false, accessibility: true), 148)
        XCTAssertNil(EditorLayoutPolicy.toolGridHeight(side: true, accessibility: false))

        XCTAssertEqual(EditorLayoutPolicy.editorToolHeight(accessibility: false, bodyLineHeight: 30, standardHeight: 34), 34)
        XCTAssertEqual(EditorLayoutPolicy.editorToolHeight(accessibility: true, bodyLineHeight: 36, standardHeight: 34), 52)
        XCTAssertEqual(EditorLayoutPolicy.singleLineGroupNavigationHeight(captionLineHeight: 14), 44)
        XCTAssertEqual(EditorLayoutPolicy.singleLineGroupNavigationHeight(captionLineHeight: 40), 48)

        XCTAssertFalse(EditorLayoutPolicy.scrollsToolsWithParameters(
            width: 390, height: 844, accessibility: true, bodyLineHeight: 34, groupButtonHeight: 60, toolStripHeight: 90))
        XCTAssertTrue(EditorLayoutPolicy.scrollsToolsWithParameters(
            width: 844, height: 320, accessibility: true, bodyLineHeight: 34, groupButtonHeight: 70, toolStripHeight: 110))
        XCTAssertFalse(EditorLayoutPolicy.scrollsToolsWithParameters(
            width: 844, height: 600, accessibility: true, bodyLineHeight: 34, groupButtonHeight: 70, toolStripHeight: 110))
    }

    func testMobileEditorGroupsAndToolsReflectHdrMode() {
        XCTAssertEqual(EditorLayoutPolicy.mobileEditorGroups(isHDREditing: false).count, 6)
        XCTAssertTrue(EditorLayoutPolicy.mobileEditorGroups(isHDREditing: true).contains(.hdrRendition))
        XCTAssertEqual(EditorLayoutPolicy.mobileEditorTools(for: .looks), [.film, .recipe])
        XCTAssertEqual(EditorLayoutPolicy.mobileEditorTools(for: .detail), [.adjustment(.sharpening), .adjustment(.noiseReduction)])
    }
}
