import XCTest
@testable import RawLabKit

final class RecipeStrengthTransferTests: XCTestCase {
    private let recipeID = "hamada_daylight_v2"
    private let cameraWB = WhiteBalance(temperature: 5200, tint: 8)

    private var macContext: MacAdjustmentTransferContext {
        MacAdjustmentTransferContext(
            identifier: "photo-A",
            isRaw: true,
            availableLookIDs: ["recipe:\(recipeID)", "builtin:PROVIA.cube"]
        )
    }

    private var iosContext: IOSAdjustmentTransferContext {
        IOSAdjustmentTransferContext(
            identifier: "photo-A",
            isRaw: true,
            availableLookIDs: ["recipe:\(recipeID)", "builtin:PROVIA.cube"],
            cameraTemperature: cameraWB.temperature,
            cameraTint: cameraWB.tint
        )
    }

    private func macState(_ settings: Adjustments, filmID: String = "") -> MacPhotoEditState {
        MacPhotoEditState(settings: settings, filmID: filmID, masterRecipeID: settings.masterRecipeID)
    }

    private func makeRecipeSettings(_ recipe: MasterRecipe, strength: Double, version: Int? = nil) -> Adjustments {
        var settings = Adjustments()
        settings.resolveWhiteBalance(cameraWB)
        settings.applyMasterRecipe(recipe)
        if let version { settings.setTransferRecipe(recipe.id, settingsVersion: version) }
        settings.strength = strength
        return settings
    }

    // 渲染请求里是 Float；粘贴前后必须是同一个 Float，不留容差。
    private func assertSameRenderFloat(_ actual: Double, _ expected: Double, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Float(actual), Float(expected), message, file: file, line: line)
    }

    // Defect A: Mac recipe copy/paste (.standard, .all, .modified) at strengths not exactly representable as Float.
    func testMacRecipeFullAndModifiedCopyPasteAcrossNonFloatExactStrengths() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))
        let strengths = [0.0, 0.01, 0.1, 0.3, 0.351, 0.7, 0.8, 1.3, 1.99, 2.0]

        for strength in strengths {
            var source = makeRecipeSettings(recipe, strength: strength)
            source.exposure = -0.6
            source.contrast = 0.9
            source.highlights = -0.15
            source.shadows = 0.25
            source.saturation = 1.15
            source.setHSL(.hue, channel: 0, value: 12.5)
            source.blackPoint = -15
            source.clarity = 20

            var neutralTarget = Adjustments()
            neutralTarget.resolveWhiteBalance(cameraWB)

            for scope in [AdjustmentTransferScope.standard, .all] {
                let payload = try MacAdjustmentTransfer.capture(scope: scope, snapshot: macState(source), context: macContext)
                XCTAssertEqual(payload[.strength]?.number, payload.source.recipe?.strength, "strength \(strength)")

                let pasted = try MacAdjustmentTransfer.prepare(payload: payload, target: macState(neutralTarget), context: macContext).settings
                XCTAssertEqual(pasted.masterRecipeID, source.masterRecipeID, "strength \(strength)")
                XCTAssertEqual(pasted.recipeScale, source.recipeScale, "strength \(strength)")
                XCTAssertEqual(pasted.strength, strength, "the pasted strength is the value the user typed, at \(strength)")

                let expectedEffective = AdjustmentTransfer.effectiveNumbers(source, context: macContext.withMacCapabilities())
                let actualEffective = AdjustmentTransfer.effectiveNumbers(pasted, context: macContext.withMacCapabilities())
                for field in [AdjustmentTransferField.exposure, .contrast, .highlights, .shadows, .saturation, .hslHueRed, .blackPoint, .clarity] {
                    assertSameRenderFloat(actualEffective[field]!, expectedEffective[field]!, "scope \(scope) field \(field.rawValue) at \(strength)")
                }

                // Same-photo paste remains a no-op and does not rewrite the photo's stored Double strength.
                let samePhoto = try MacAdjustmentTransfer.prepare(payload: payload, target: macState(source), context: macContext)
                XCTAssertEqual(samePhoto, macState(source), "same-photo no-op at \(strength)")
            }

            // .modified with custom WB materializes modified recipe fields as an independent LUT while preserving rendered effect.
            var modifiedSource = source
            modifiedSource.whiteBalanceMode = .custom
            modifiedSource.temperature = 5600
            let modifiedPayload = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: macState(modifiedSource), context: macContext)
            let modifiedTarget = makeRecipeSettings(recipe, strength: 1.0)
            let pastedModified = try MacAdjustmentTransfer.prepare(payload: modifiedPayload, target: macState(modifiedTarget), context: macContext).settings
            XCTAssertEqual(pastedModified.strength, strength, "modified strength \(strength)")
            let modifiedExpected = AdjustmentTransfer.effectiveNumbers(modifiedSource, context: macContext.withMacCapabilities())[.exposure]!
            let modifiedActual = AdjustmentTransfer.effectiveNumbers(pastedModified, context: macContext.withMacCapabilities())[.exposure]!
            assertSameRenderFloat(modifiedActual, modifiedExpected, "modified exposure at \(strength)")
        }

        // Independent (non-recipe) look on Mac still preserves exact Double strength.
        var independentSource = Adjustments()
        independentSource.strength = 0.7
        let independentPayload = try MacAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: macState(independentSource), context: macContext)
        XCTAssertEqual(independentPayload[.strength]?.number, 0.7)
        let independentTarget = macState(Adjustments(), filmID: "builtin:PROVIA.cube")
        let pastedIndependent = try MacAdjustmentTransfer.prepare(payload: independentPayload, target: independentTarget, context: macContext)
        XCTAssertEqual(pastedIndependent.settings.strength, 0.7)
    }

    // Defect B: Single recipe-scaled field copy/paste across strength pairs on BOTH Mac and iOS wrappers.
    func testSingleRecipeFieldGridPreservesEffectOnMacAndIOS() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))
        let strengths = [0.1, 0.3, 0.5, 0.7, 0.9, 1.1, 1.8]
        let exposures = [0.1, 0.75, 1.3, -0.6]

        for s1 in strengths {
            for s2 in strengths {
                for e in exposures {
                    let source = {
                        var s = makeRecipeSettings(recipe, strength: s1)
                        s.exposure = e
                        return s
                    }()
                    var target = source
                    target.strength = s2
                    target.exposure = 0

                    // 期望值按 Windows 的算法独立算出：全程 Double，到渲染请求才转 Float。
                    let expectedEffective = e * s1
                    let requiredLogical = expectedEffective / s2
                    let inRange = AdjustmentParameter.exposure.spec.range.contains(requiredLogical)

                    // Mac wrapper
                    let macPayload = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: macState(source), context: macContext)
                    if inRange {
                        let pasted = try MacAdjustmentTransfer.prepare(payload: macPayload, target: macState(target), context: macContext).settings
                        XCTAssertEqual(pasted.strength, s2, "Mac target strength unchanged \(s1)->\(s2)")
                        let actual = AdjustmentTransfer.effectiveNumbers(pasted, context: macContext.withMacCapabilities())[.exposure]!
                        assertSameRenderFloat(actual, expectedEffective, "Mac exposure \(s1)->\(s2) e=\(e)")
                    } else {
                        XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(payload: macPayload, target: macState(target), context: macContext)) { error in
                            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("native range"))
                        }
                    }

                    // iOS wrapper
                    let iosPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: PhotoEditState(settings: source), context: iosContext)
                    if inRange {
                        let pasted = try IOSAdjustmentTransfer.prepare(payload: iosPayload, target: PhotoEditState(settings: target), context: iosContext).settings
                        XCTAssertEqual(pasted.strength, s2, "iOS target strength unchanged \(s1)->\(s2)")
                        let actual = AdjustmentTransfer.effectiveNumbers(pasted, context: iosContext.withIOSCapabilities())[.exposure]!
                        assertSameRenderFloat(actual, expectedEffective, "iOS exposure \(s1)->\(s2) e=\(e)")
                    } else {
                        XCTAssertThrowsError(try IOSAdjustmentTransfer.prepare(payload: iosPayload, target: PhotoEditState(settings: target), context: iosContext)) { error in
                            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("native range"))
                        }
                    }
                }
            }
        }
    }

    // Covers the other recipe-scaled fields (pairs that were wrongly rejected before the fix) and genuine rejections.
    func testOtherRecipeScaledFieldsAndGenuineUnrepresentableRejections() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))

        struct CaseSpec {
            let field: AdjustmentTransferField
            let s1: Double
            let s2: Double
            let apply: (inout Adjustments) -> Void
            let reset: (inout Adjustments) -> Void
        }

        let cases: [CaseSpec] = [
            // Pairs rejected before the fix: Mac mixed Float/Double scaling, and Float-narrowed scaling on iOS
            .init(field: .exposure, s1: 0.9, s2: 1.1, apply: { $0.exposure = 0.75 }, reset: { $0.exposure = 0 }),
            .init(field: .exposure, s1: 1.8, s2: 1.1, apply: { $0.exposure = 0.75 }, reset: { $0.exposure = 0 }),
            .init(field: .contrast, s1: 0.3, s2: 1.6, apply: { $0.contrast = 0.9 }, reset: { $0.contrast = 1 }),
            .init(field: .saturation, s1: 0.3, s2: 1.6, apply: { $0.saturation = 0.9 }, reset: { $0.saturation = 1 }),
            .init(field: .highlights, s1: 0.1, s2: 0.1, apply: { $0.highlights = -0.15 }, reset: { $0.highlights = 0 }),
            .init(field: .shadows, s1: 0.1, s2: 0.1, apply: { $0.shadows = -0.3 }, reset: { $0.shadows = 0 }),
            .init(field: .hslHueRed, s1: 0.1, s2: 0.1, apply: { $0.setHSL(.hue, channel: 0, value: 12.5) }, reset: { $0.setHSL(.hue, channel: 0, value: 0) }),
            .init(field: .blackPoint, s1: 0.3, s2: 0.7, apply: { $0.blackPoint = -20 }, reset: { $0.blackPoint = 0 }),
            .init(field: .clarity, s1: 0.7, s2: 1.3, apply: { $0.clarity = 25 }, reset: { $0.clarity = 0 }),
            .init(field: .sCurve, s1: 0.3, s2: 0.8, apply: { $0.toneCurve = 0.25 }, reset: { $0.toneCurve = 0 }),
            .init(field: .tint, s1: 1.8, s2: 1.1, apply: { $0.tint = 12 }, reset: { $0.tint = 0 }),
            .init(field: .gradingShadows, s1: 0.9, s2: 1.1, apply: { $0.gradingSettings.shadows = ColorGradingWheel(hue: 210, saturation: 75, luminance: -15) }, reset: { $0.gradingSettings.shadows = ColorGradingWheel() }),
        ]

        for item in cases {
            var source = makeRecipeSettings(recipe, strength: item.s1, version: 4)
            item.apply(&source)
            var target = source
            target.strength = item.s2
            item.reset(&target)

            let macPayload = try MacAdjustmentTransfer.capture(scope: .custom([item.field]), snapshot: macState(source), context: macContext)
            let macPasted = try MacAdjustmentTransfer.prepare(payload: macPayload, target: macState(target), context: macContext).settings
            XCTAssertEqual(macPasted.strength, item.s2, "Mac \(item.field.rawValue)")

            let iosPayload = try IOSAdjustmentTransfer.capture(scope: .custom([item.field]), snapshot: PhotoEditState(settings: source), context: iosContext)
            let iosPasted = try IOSAdjustmentTransfer.prepare(payload: iosPayload, target: PhotoEditState(settings: target), context: iosContext).settings
            XCTAssertEqual(iosPasted.strength, item.s2, "iOS \(item.field.rawValue)")

            if item.field == .tint {
                let expectedTint = cameraWB.tint + source.tint * item.s1
                assertSameRenderFloat(AdjustmentTransfer.renderWB(macPasted, context: macContext.withMacCapabilities()).tint, expectedTint, "Mac tint")
                assertSameRenderFloat(AdjustmentTransfer.renderWB(iosPasted, context: iosContext.withIOSCapabilities()).tint, expectedTint, "iOS tint")
            } else if item.field == .gradingShadows {
                let expectedSat = source.renderGradingSettings.shadows.saturation
                let expectedLum = source.renderGradingSettings.shadows.luminance
                assertSameRenderFloat(macPasted.renderGradingSettings.shadows.saturation, expectedSat, "Mac grading sat")
                assertSameRenderFloat(macPasted.renderGradingSettings.shadows.luminance, expectedLum, "Mac grading lum")
                assertSameRenderFloat(iosPasted.renderGradingSettings.shadows.saturation, expectedSat, "iOS grading sat")
                assertSameRenderFloat(iosPasted.renderGradingSettings.shadows.luminance, expectedLum, "iOS grading lum")
            } else {
                let macExpected = AdjustmentTransfer.effectiveNumbers(source, context: macContext.withMacCapabilities())[item.field]!
                let macActual = AdjustmentTransfer.effectiveNumbers(macPasted, context: macContext.withMacCapabilities())[item.field]!
                assertSameRenderFloat(macActual, macExpected, "Mac \(item.field.rawValue)")

                let iosExpected = AdjustmentTransfer.effectiveNumbers(source, context: iosContext.withIOSCapabilities())[item.field]!
                let iosActual = AdjustmentTransfer.effectiveNumbers(iosPasted, context: iosContext.withIOSCapabilities())[item.field]!
                assertSameRenderFloat(iosActual, iosExpected, "iOS \(item.field.rawValue)")
            }
        }

        // Genuinely unrepresentable cases MUST still be rejected on both platforms:
        // 1) Zero target strength with a non-neutral value (including tiny values well above 1e-12).
        for e in [0.4, 1e-5] {
            var source = makeRecipeSettings(recipe, strength: 0.7)
            source.exposure = e
            var zeroTarget = source
            zeroTarget.strength = 0
            zeroTarget.exposure = 0

            let macPayload = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: macState(source), context: macContext)
            XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(payload: macPayload, target: macState(zeroTarget), context: macContext)) { error in
                XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("light.exposure"))
            }
            let iosPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: PhotoEditState(settings: source), context: iosContext)
            XCTAssertThrowsError(try IOSAdjustmentTransfer.prepare(payload: iosPayload, target: PhotoEditState(settings: zeroTarget), context: iosContext)) { error in
                XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("light.exposure"))
            }
        }

        // 2) Out-of-range HSL inversion (30 * 0.4 / 0.1 = 120 > 100).
        var hslSource = makeRecipeSettings(recipe, strength: 0.4)
        hslSource.setHSL(.hue, channel: 0, value: 30)
        var hslTarget = hslSource
        hslTarget.strength = 0.1
        hslTarget.setHSL(.hue, channel: 0, value: 0)
        let macHSL = try MacAdjustmentTransfer.capture(scope: .custom([.hslHueRed]), snapshot: macState(hslSource), context: macContext)
        XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(payload: macHSL, target: macState(hslTarget), context: macContext)) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("color.hsl.hue.red"))
        }
        let iosHSL = try IOSAdjustmentTransfer.capture(scope: .custom([.hslHueRed]), snapshot: PhotoEditState(settings: hslSource), context: iosContext)
        XCTAssertThrowsError(try IOSAdjustmentTransfer.prepare(payload: iosHSL, target: PhotoEditState(settings: hslTarget), context: iosContext)) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("color.hsl.hue.red"))
        }
    }

    // Cross-client Windows-style Double strength payload pasted onto both Mac and iOS.
    func testDoubleStrengthDesktopPayloadPastesCleanlyOnMacAndIOS() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))
        for strength in [0.3, 0.7, 1.43] {
            var source = makeRecipeSettings(recipe, strength: strength, version: 4)
            source.exposure = -0.6
            source.contrast = 0.3
            source.blackPoint = 21.3
            source.clarity = -15
            var values = MacAdjustmentTransfer.values(macState(source), isRaw: true)
            values[AdjustmentTransferField.strength.rawValue] = .number(strength)
            let payload = try AdjustmentTransferPayload(
                source: .init(identifier: "windows-photo", isRaw: true, processingVersion: 3,
                              recipe: .init(id: recipe.id, strength: strength, settingsVersion: 4)),
                values: values.filter { AdjustmentTransferField.common.contains(AdjustmentTransferField(rawValue: $0.key)!) }
            )

            var neutral = Adjustments()
            neutral.resolveWhiteBalance(cameraWB)

            let macPasted = try MacAdjustmentTransfer.prepare(payload: payload, target: macState(neutral), context: macContext).settings
            let iosPasted = try IOSAdjustmentTransfer.prepare(payload: payload, target: PhotoEditState(settings: neutral), context: iosContext).settings
            XCTAssertEqual(macPasted.masterRecipeID, recipe.id)
            XCTAssertEqual(iosPasted.masterRecipeID, recipe.id)

            let expectedExposure = -0.6 * strength
            let expectedContrast = 1.0 + (0.3 - 1.0) * strength
            let expectedBlack = 21.3 * strength
            assertSameRenderFloat(AdjustmentTransfer.effectiveNumbers(macPasted, context: macContext.withMacCapabilities())[.exposure]!, expectedExposure, "Mac desktop exposure at \(strength)")
            assertSameRenderFloat(AdjustmentTransfer.effectiveNumbers(macPasted, context: macContext.withMacCapabilities())[.contrast]!, expectedContrast, "Mac desktop contrast at \(strength)")
            assertSameRenderFloat(AdjustmentTransfer.effectiveNumbers(macPasted, context: macContext.withMacCapabilities())[.blackPoint]!, expectedBlack, "Mac desktop blackPoint at \(strength)")
            assertSameRenderFloat(AdjustmentTransfer.effectiveNumbers(iosPasted, context: iosContext.withIOSCapabilities())[.exposure]!, expectedExposure, "iOS desktop exposure at \(strength)")
            assertSameRenderFloat(AdjustmentTransfer.effectiveNumbers(iosPasted, context: iosContext.withIOSCapabilities())[.contrast]!, expectedContrast, "iOS desktop contrast at \(strength)")
            assertSameRenderFloat(AdjustmentTransfer.effectiveNumbers(iosPasted, context: iosContext.withIOSCapabilities())[.blackPoint]!, expectedBlack, "iOS desktop blackPoint at \(strength)")
        }
    }
}
