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

    // Removing a recipe materializes its scaled values; the render request must not move at any one-percent strength.
    func testRemovingRecipeKeepsRenderRequestAtEveryPercentStrength() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))
        for step in 0...200 {
            let strength = Double(step) / 100
            var settings = makeRecipeSettings(recipe, strength: strength, version: 4)
            settings.exposure = -0.6
            settings.contrast = 0.9
            settings.tint = 12
            settings.toneCurve = 0.75
            settings.blackPoint = -20
            settings.clarity = 25
            settings.gradingSettings.shadows = ColorGradingWheel(hue: 210, saturation: 75, luminance: -15)
            let before = settings.resolvedRenderValues()
            let tone = settings.renderToneSettings, atmosphere = settings.renderAtmosphereSettings, grading = settings.renderGradingSettings

            XCTAssertTrue(settings.clearMasterRecipe(isRaw: true), "recipe can be removed at \(strength)")
            XCTAssertNil(settings.masterRecipeID)
            XCTAssertEqual(settings.resolvedRenderValues(), before, "core render request unchanged at \(strength)")
            XCTAssertEqual(settings.renderToneSettings, tone, "tone controls unchanged at \(strength)")
            XCTAssertEqual(settings.renderAtmosphereSettings, atmosphere, "atmosphere unchanged at \(strength)")
            XCTAssertEqual(settings.renderGradingSettings, grading, "grading unchanged at \(strength)")
        }
    }

    func testGlobalGradingWheelConvertsByRecipeStrengthOnMacAndIOS() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))

        // (a) Pasting global wheel across different v4 recipe strengths preserves rendered global wheel.
        var source = makeRecipeSettings(recipe, strength: 0.5, version: 4)
        source.gradingSettings.global = ColorGradingWheel(hue: 180, saturation: 40, luminance: 20)
        var target = makeRecipeSettings(recipe, strength: 2.0, version: 4)
        target.gradingSettings.global = ColorGradingWheel()

        let macGlobalPayload = try MacAdjustmentTransfer.capture(scope: .custom([.gradingGlobal]), snapshot: macState(source), context: macContext)
        let macGlobalPasted = try MacAdjustmentTransfer.prepare(payload: macGlobalPayload, target: macState(target), context: macContext).settings
        XCTAssertEqual(macGlobalPasted.gradingSettings.global, ColorGradingWheel(hue: 180, saturation: 10, luminance: 5))
        XCTAssertEqual(macGlobalPasted.renderGradingSettings.global, ColorGradingWheel(hue: 180, saturation: 20, luminance: 10))

        let iosGlobalPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.gradingGlobal]), snapshot: PhotoEditState(settings: source), context: iosContext)
        let iosGlobalPasted = try IOSAdjustmentTransfer.prepare(payload: iosGlobalPayload, target: PhotoEditState(settings: target), context: iosContext).settings
        XCTAssertEqual(iosGlobalPasted.gradingSettings.global, ColorGradingWheel(hue: 180, saturation: 10, luminance: 5))
        XCTAssertEqual(iosGlobalPasted.renderGradingSettings.global, ColorGradingWheel(hue: 180, saturation: 20, luminance: 10))

        // (b) Pasting only recipe strength preserves target's rendered global wheel.
        var strengthSource = Adjustments()
        strengthSource.strength = 2.0
        let macStrengthPayload = try MacAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: macState(strengthSource), context: macContext)
        let macStrengthPasted = try MacAdjustmentTransfer.prepare(payload: macStrengthPayload, target: macState(source), context: macContext).settings
        XCTAssertEqual(macStrengthPasted.strength, 2.0)
        XCTAssertEqual(macStrengthPasted.gradingSettings.global, ColorGradingWheel(hue: 180, saturation: 10, luminance: 5))
        XCTAssertEqual(macStrengthPasted.renderGradingSettings.global, ColorGradingWheel(hue: 180, saturation: 20, luminance: 10))

        let iosStrengthPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: PhotoEditState(settings: strengthSource), context: iosContext)
        let iosStrengthPasted = try IOSAdjustmentTransfer.prepare(payload: iosStrengthPayload, target: PhotoEditState(settings: source), context: iosContext).settings
        XCTAssertEqual(iosStrengthPasted.strength, 2.0)
        XCTAssertEqual(iosStrengthPasted.gradingSettings.global, ColorGradingWheel(hue: 180, saturation: 10, luminance: 5))
        XCTAssertEqual(iosStrengthPasted.renderGradingSettings.global, ColorGradingWheel(hue: 180, saturation: 20, luminance: 10))

        // (c) Full v4 recipe paste carries the logical global wheel unchanged at strength 0 and clamped strength 2.0.
        var neutralTarget = Adjustments()
        neutralTarget.resolveWhiteBalance(cameraWB)
        for (strength, wheel) in [(0.0, ColorGradingWheel(hue: 180, saturation: 20, luminance: 10)),
                                  (2.0, ColorGradingWheel(hue: 180, saturation: 80, luminance: 60))] {
            var fullSource = makeRecipeSettings(recipe, strength: strength, version: 4)
            fullSource.gradingSettings.global = wheel
            let macFull = try MacAdjustmentTransfer.capture(scope: .standard, snapshot: macState(fullSource), context: macContext)
            let macFullPasted = try MacAdjustmentTransfer.prepare(payload: macFull, target: macState(neutralTarget), context: macContext).settings
            XCTAssertEqual(macFullPasted.gradingSettings.global, wheel, "Mac full recipe global wheel at \(strength)")

            let iosFull = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: PhotoEditState(settings: fullSource), context: iosContext)
            let iosFullPasted = try IOSAdjustmentTransfer.prepare(payload: iosFull, target: PhotoEditState(settings: neutralTarget), context: iosContext).settings
            XCTAssertEqual(iosFullPasted.gradingSettings.global, wheel, "iOS full recipe global wheel at \(strength)")
        }

        // (d) Unrepresentable global wheel requests fail with .unrepresentable("color.grading.global"), matching zone wheels.
        var zeroTarget = makeRecipeSettings(recipe, strength: 0.0, version: 4)
        zeroTarget.gradingSettings.global = ColorGradingWheel()
        var neutralSource = Adjustments()
        neutralSource.gradingSettings.global = ColorGradingWheel(hue: 180, saturation: 20, luminance: 10)
        let macNeutralGlobal = try MacAdjustmentTransfer.capture(scope: .custom([.gradingGlobal]), snapshot: macState(neutralSource), context: macContext)
        XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(payload: macNeutralGlobal, target: macState(zeroTarget), context: macContext)) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("color.grading.global"))
        }
        let iosNeutralGlobal = try IOSAdjustmentTransfer.capture(scope: .custom([.gradingGlobal]), snapshot: PhotoEditState(settings: neutralSource), context: iosContext)
        XCTAssertThrowsError(try IOSAdjustmentTransfer.prepare(payload: iosNeutralGlobal, target: PhotoEditState(settings: zeroTarget), context: iosContext)) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("color.grading.global"))
        }

        // Strength-only paste to 0 on a target whose only non-neutral scaled edit is the global wheel is also unrepresentable.
        var globalOnlyTarget = Adjustments()
        globalOnlyTarget.resolveWhiteBalance(cameraWB)
        globalOnlyTarget.setTransferRecipe(recipe.id, settingsVersion: 4)
        globalOnlyTarget.tint = 0
        globalOnlyTarget.strength = 0.5
        globalOnlyTarget.gradingSettings.global = ColorGradingWheel(hue: 180, saturation: 40, luminance: 20)
        var zeroStrengthSource = Adjustments()
        zeroStrengthSource.strength = 0.0
        let macZeroStrength = try MacAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: macState(zeroStrengthSource), context: macContext)
        XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(payload: macZeroStrength, target: macState(globalOnlyTarget), context: macContext)) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("color.grading.global"))
        }
        let iosZeroStrength = try IOSAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: PhotoEditState(settings: zeroStrengthSource), context: iosContext)
        XCTAssertThrowsError(try IOSAdjustmentTransfer.prepare(payload: iosZeroStrength, target: PhotoEditState(settings: globalOnlyTarget), context: iosContext)) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("color.grading.global"))
        }

        // Out-of-range inversion (neutral sat 60 onto v4 strength 0.5 requires 120 > 100).
        var highSatSource = Adjustments()
        highSatSource.gradingSettings.global = ColorGradingWheel(hue: 180, saturation: 60, luminance: 0)
        var halfTarget = makeRecipeSettings(recipe, strength: 0.5, version: 4)
        halfTarget.gradingSettings.global = ColorGradingWheel()
        let macHighSat = try MacAdjustmentTransfer.capture(scope: .custom([.gradingGlobal]), snapshot: macState(highSatSource), context: macContext)
        XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(payload: macHighSat, target: macState(halfTarget), context: macContext)) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("color.grading.global"))
        }
        let iosHighSat = try IOSAdjustmentTransfer.capture(scope: .custom([.gradingGlobal]), snapshot: PhotoEditState(settings: highSatSource), context: iosContext)
        XCTAssertThrowsError(try IOSAdjustmentTransfer.prepare(payload: iosHighSat, target: PhotoEditState(settings: halfTarget), context: iosContext)) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("color.grading.global"))
        }
    }

    func testStrengthOnlyPastePreservesCameraWhiteBalanceWithRecipeTintOnMacAndIOS() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))

        var macTarget = makeRecipeSettings(recipe, strength: 0.5)
        macTarget.whiteBalanceMode = .asShot
        macTarget.tint = 10.0

        var iosTarget = Adjustments()
        iosTarget.applyMasterRecipe(recipe)
        iosTarget.strength = 0.5
        iosTarget.whiteBalanceMode = .camera
        iosTarget.temperature = 6500.0
        iosTarget.tint = 10.0

        var strengthOne = Adjustments()
        strengthOne.strength = 1.0
        let macPayload = try MacAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: macState(strengthOne), context: macContext)
        let iosPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: PhotoEditState(settings: strengthOne), context: iosContext)

        let macBeforeWB = AdjustmentTransfer.renderWB(macTarget, context: macContext.withMacCapabilities())
        let macPasted = try MacAdjustmentTransfer.prepare(payload: macPayload, target: macState(macTarget), context: macContext).settings
        let macAfterWB = AdjustmentTransfer.renderWB(macPasted, context: macContext.withMacCapabilities())
        XCTAssertEqual(macPasted.whiteBalanceMode, .asShot)
        XCTAssertTrue(macPasted.usesAsShotWhiteBalance)
        XCTAssertEqual(macPasted.temperature, 5200.0)
        XCTAssertEqual(macPasted.tint, 5.0)
        XCTAssertEqual(macAfterWB, AdjustmentTransfer.ResolvedWB(camera: false, temperature: 5200.0, tint: 13.0))
        XCTAssertEqual(macAfterWB, macBeforeWB)

        let iosBeforeWB = AdjustmentTransfer.renderWB(iosTarget, context: iosContext.withIOSCapabilities())
        let iosPasted = try IOSAdjustmentTransfer.prepare(payload: iosPayload, target: PhotoEditState(settings: iosTarget), context: iosContext).settings
        let iosAfterWB = AdjustmentTransfer.renderWB(iosPasted, context: iosContext.withIOSCapabilities())
        XCTAssertEqual(iosPasted.whiteBalanceMode, .camera)
        XCTAssertEqual(iosPasted.temperature, 6500.0)
        XCTAssertEqual(iosPasted.tint, 5.0)
        XCTAssertEqual(iosAfterWB, AdjustmentTransfer.ResolvedWB(camera: false, temperature: 5200.0, tint: 13.0))
        XCTAssertEqual(iosAfterWB, iosBeforeWB)

        // Round-tripping strength back to 0.5 restores the exact original WB fields.
        var strengthHalf = Adjustments()
        strengthHalf.strength = 0.5
        let macBack = try MacAdjustmentTransfer.prepare(
            payload: try MacAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: macState(strengthHalf), context: macContext),
            target: macState(macPasted),
            context: macContext
        ).settings
        XCTAssertEqual(macBack.whiteBalanceMode, .asShot)
        XCTAssertTrue(macBack.usesAsShotWhiteBalance)
        XCTAssertEqual(macBack.temperature, 5200.0)
        XCTAssertEqual(macBack.tint, 10.0)
        let iosBack = try IOSAdjustmentTransfer.prepare(
            payload: try IOSAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: PhotoEditState(settings: strengthHalf), context: iosContext),
            target: PhotoEditState(settings: iosPasted),
            context: iosContext
        ).settings
        XCTAssertEqual(iosBack.whiteBalanceMode, .camera)
        XCTAssertEqual(iosBack.temperature, 6500.0)
        XCTAssertEqual(iosBack.tint, 10.0)

        // Explicit fixed temperature matching camera temperature stays fixed (does not flip back to camera).
        var macFixedTarget = macTarget
        macFixedTarget.whiteBalanceMode = .custom
        macFixedTarget.temperature = 5200.0
        let macFixedPasted = try MacAdjustmentTransfer.prepare(payload: macPayload, target: macState(macFixedTarget), context: macContext).settings
        XCTAssertEqual(macFixedPasted.whiteBalanceMode, .custom)
        XCTAssertEqual(macFixedPasted.temperature, 5200.0)
        XCTAssertEqual(macFixedPasted.tint, 5.0)

        var iosFixedTarget = iosTarget
        iosFixedTarget.whiteBalanceMode = .custom
        iosFixedTarget.temperature = 5200.0
        let iosFixedPasted = try IOSAdjustmentTransfer.prepare(payload: iosPayload, target: PhotoEditState(settings: iosFixedTarget), context: iosContext).settings
        XCTAssertEqual(iosFixedPasted.whiteBalanceMode, .custom)
        XCTAssertEqual(iosFixedPasted.temperature, 5200.0)
        XCTAssertEqual(iosFixedPasted.tint, 5.0)

        // Removing the recipe via neutral look still converts recipe tint to fixed temperature WB.
        let neutralLookPayload = try MacAdjustmentTransfer.capture(scope: .custom([.look]), snapshot: macState(Adjustments()), context: macContext)
        let macDetached = try MacAdjustmentTransfer.prepare(payload: neutralLookPayload, target: macState(macTarget), context: macContext).settings
        XCTAssertEqual(macDetached.whiteBalanceMode, .custom)
        XCTAssertEqual(macDetached.temperature, 5200.0)
        XCTAssertEqual(macDetached.tint, 13.0)

        let iosNeutralLookPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.look]), snapshot: PhotoEditState(settings: Adjustments()), context: iosContext)
        let iosDetached = try IOSAdjustmentTransfer.prepare(payload: iosNeutralLookPayload, target: PhotoEditState(settings: iosTarget), context: iosContext).settings
        XCTAssertEqual(iosDetached.whiteBalanceMode, .custom)
        XCTAssertEqual(iosDetached.temperature, 5200.0)
        XCTAssertEqual(iosDetached.tint, 13.0)
    }

    func testGradingWheelAndCurveEndpointOvershootOnMacAndIOS() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))

        // 1) Same-strength 0.69 -> 0.69: 69.0 / 0.69 = 100.00000000000001 in Double.
        //    Must clamp candidate to 100 and accept when exact scaled rendering matches 69.
        var source69 = makeRecipeSettings(recipe, strength: 0.69, version: 4)
        source69.gradingSettings.global = ColorGradingWheel(hue: 180, saturation: 100, luminance: 0)
        source69.gradingSettings.shadows = ColorGradingWheel(hue: 180, saturation: 100, luminance: -100)
        var target69 = makeRecipeSettings(recipe, strength: 0.69, version: 4)
        target69.gradingSettings.global = ColorGradingWheel()
        target69.gradingSettings.shadows = ColorGradingWheel()

        for field in [AdjustmentTransferField.gradingGlobal, .gradingShadows] {
            let expectedStored = field == .gradingGlobal
                ? ColorGradingWheel(hue: 180, saturation: 100, luminance: 0)
                : ColorGradingWheel(hue: 180, saturation: 100, luminance: -100)
            let expectedRendered = field == .gradingGlobal
                ? ColorGradingWheel(hue: 180, saturation: 69, luminance: 0)
                : ColorGradingWheel(hue: 180, saturation: 69, luminance: -69)

            let macPayload = try MacAdjustmentTransfer.capture(scope: .custom([field]), snapshot: macState(source69), context: macContext)
            let macPasted = try MacAdjustmentTransfer.prepare(payload: macPayload, target: macState(target69), context: macContext).settings
            let macStored = field == .gradingGlobal ? macPasted.gradingSettings.global : macPasted.gradingSettings.shadows
            let macRendered = field == .gradingGlobal ? macPasted.renderGradingSettings.global : macPasted.renderGradingSettings.shadows
            XCTAssertEqual(macStored, expectedStored, "Mac \(field.rawValue) 0.69->0.69 stored")
            XCTAssertEqual(macRendered, expectedRendered, "Mac \(field.rawValue) 0.69->0.69 rendered")

            let iosPayload = try IOSAdjustmentTransfer.capture(scope: .custom([field]), snapshot: PhotoEditState(settings: source69), context: iosContext)
            let iosPasted = try IOSAdjustmentTransfer.prepare(payload: iosPayload, target: PhotoEditState(settings: target69), context: iosContext).settings
            let iosStored = field == .gradingGlobal ? iosPasted.gradingSettings.global : iosPasted.gradingSettings.shadows
            let iosRendered = field == .gradingGlobal ? iosPasted.renderGradingSettings.global : iosPasted.renderGradingSettings.shadows
            XCTAssertEqual(iosStored, expectedStored, "iOS \(field.rawValue) 0.69->0.69 stored")
            XCTAssertEqual(iosRendered, expectedRendered, "iOS \(field.rawValue) 0.69->0.69 rendered")
        }

        // 2) No-recipe -> 0.69 ({180, 69, 0} onto 0.69) and strength-only 1.0 -> 0.69 preserving unselected global wheel.
        var neutral69 = Adjustments()
        neutral69.gradingSettings.global = ColorGradingWheel(hue: 180, saturation: 69, luminance: 0)
        let macNoRecipe = try MacAdjustmentTransfer.prepare(
            payload: try MacAdjustmentTransfer.capture(scope: .custom([.gradingGlobal]), snapshot: macState(neutral69), context: macContext),
            target: macState(target69),
            context: macContext
        ).settings
        XCTAssertEqual(macNoRecipe.gradingSettings.global, ColorGradingWheel(hue: 180, saturation: 100, luminance: 0))
        XCTAssertEqual(macNoRecipe.renderGradingSettings.global, ColorGradingWheel(hue: 180, saturation: 69, luminance: 0))

        let iosNoRecipe = try IOSAdjustmentTransfer.prepare(
            payload: try IOSAdjustmentTransfer.capture(scope: .custom([.gradingGlobal]), snapshot: PhotoEditState(settings: neutral69), context: iosContext),
            target: PhotoEditState(settings: target69),
            context: iosContext
        ).settings
        XCTAssertEqual(iosNoRecipe.gradingSettings.global, ColorGradingWheel(hue: 180, saturation: 100, luminance: 0))
        XCTAssertEqual(iosNoRecipe.renderGradingSettings.global, ColorGradingWheel(hue: 180, saturation: 69, luminance: 0))

        var target100 = makeRecipeSettings(recipe, strength: 1.0, version: 4)
        target100.gradingSettings.global = ColorGradingWheel(hue: 180, saturation: 69, luminance: 0)
        var strength69 = Adjustments()
        strength69.strength = 0.69
        let macStrengthDrop = try MacAdjustmentTransfer.prepare(
            payload: try MacAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: macState(strength69), context: macContext),
            target: macState(target100),
            context: macContext
        ).settings
        XCTAssertEqual(macStrengthDrop.gradingSettings.global, ColorGradingWheel(hue: 180, saturation: 100, luminance: 0))
        XCTAssertEqual(macStrengthDrop.renderGradingSettings.global, ColorGradingWheel(hue: 180, saturation: 69, luminance: 0))

        let iosStrengthDrop = try IOSAdjustmentTransfer.prepare(
            payload: try IOSAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: PhotoEditState(settings: strength69), context: iosContext),
            target: PhotoEditState(settings: target100),
            context: iosContext
        ).settings
        XCTAssertEqual(iosStrengthDrop.gradingSettings.global, ColorGradingWheel(hue: 180, saturation: 100, luminance: 0))
        XCTAssertEqual(iosStrengthDrop.renderGradingSettings.global.hue, 180)
        assertSameRenderFloat(iosStrengthDrop.renderGradingSettings.global.saturation, 69, "iOS strength drop rendered sat")
        assertSameRenderFloat(iosStrengthDrop.renderGradingSettings.global.luminance, 0, "iOS strength drop rendered lum")

        // 3) Guard: genuinely out-of-range 60 at strength 0.5 (quotient 120) must still be rejected.
        var outOfRangeWheel = Adjustments()
        outOfRangeWheel.gradingSettings.global = ColorGradingWheel(hue: 180, saturation: 60, luminance: 0)
        outOfRangeWheel.gradingSettings.shadows = ColorGradingWheel(hue: 180, saturation: 60, luminance: 0)
        var targetHalf = makeRecipeSettings(recipe, strength: 0.5, version: 4)
        targetHalf.gradingSettings.global = ColorGradingWheel()
        targetHalf.gradingSettings.shadows = ColorGradingWheel()
        for field in [AdjustmentTransferField.gradingGlobal, .gradingShadows] {
            let macBad = try MacAdjustmentTransfer.capture(scope: .custom([field]), snapshot: macState(outOfRangeWheel), context: macContext)
            XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(payload: macBad, target: macState(targetHalf), context: macContext)) { error in
                XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable(field.rawValue))
            }
            let iosBad = try IOSAdjustmentTransfer.capture(scope: .custom([field]), snapshot: PhotoEditState(settings: outOfRangeWheel), context: iosContext)
            XCTAssertThrowsError(try IOSAdjustmentTransfer.prepare(payload: iosBad, target: PhotoEditState(settings: targetHalf), context: iosContext)) { error in
                XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable(field.rawValue))
            }
        }

        // 4) Identical quotient-overshoot pattern in parametric curve (0.69 -> 0.69, highlights = 100, shadows = -100)
        //    and custom tone curve (0.002 -> 0.002, interior point (0.5, 1.0)).
        var paramSource = makeRecipeSettings(recipe, strength: 0.69, version: 4)
        paramSource.curveSettings.parametric = ToneCurveParametric(highlights: 100, lights: 0, darks: 0, shadows: -100)
        var paramTarget = makeRecipeSettings(recipe, strength: 0.69, version: 4)
        paramTarget.curveSettings.parametric = ToneCurveParametric()
        let macParam = try MacAdjustmentTransfer.prepare(
            payload: try MacAdjustmentTransfer.capture(scope: .custom([.curveParametric]), snapshot: macState(paramSource), context: macContext),
            target: macState(paramTarget),
            context: macContext
        ).settings
        XCTAssertEqual(macParam.curveSettings.parametric, ToneCurveParametric(highlights: 100, lights: 0, darks: 0, shadows: -100))
        XCTAssertEqual(macParam.renderCurveSettings.parametric.highlights, 69)
        XCTAssertEqual(macParam.renderCurveSettings.parametric.shadows, -69)
        let iosParam = try IOSAdjustmentTransfer.prepare(
            payload: try IOSAdjustmentTransfer.capture(scope: .custom([.curveParametric]), snapshot: PhotoEditState(settings: paramSource), context: iosContext),
            target: PhotoEditState(settings: paramTarget),
            context: iosContext
        ).settings
        XCTAssertEqual(iosParam.curveSettings.parametric, ToneCurveParametric(highlights: 100, lights: 0, darks: 0, shadows: -100))

        var badParamSource = Adjustments()
        badParamSource.curveSettings.parametric = ToneCurveParametric(highlights: 60)
        XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(
            payload: try MacAdjustmentTransfer.capture(scope: .custom([.curveParametric]), snapshot: macState(badParamSource), context: macContext),
            target: macState(targetHalf),
            context: macContext
        )) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("light.curve.parametric"))
        }

        var curveSource = makeRecipeSettings(recipe, strength: 0.002, version: 4)
        curveSource.curveSettings = ToneCurveSettings(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 1.0), .init(x: 1, y: 1)])
        var curveTarget = makeRecipeSettings(recipe, strength: 0.002, version: 4)
        curveTarget.curveSettings = ToneCurveSettings()
        let macCurve = try MacAdjustmentTransfer.prepare(
            payload: try MacAdjustmentTransfer.capture(scope: .custom([.curve]), snapshot: macState(curveSource), context: macContext),
            target: macState(curveTarget),
            context: macContext
        ).settings
        XCTAssertEqual(macCurve.curveSettings.points, [.init(x: 0, y: 0), .init(x: 0.5, y: 1.0), .init(x: 1, y: 1)])
        let iosCurve = try IOSAdjustmentTransfer.prepare(
            payload: try IOSAdjustmentTransfer.capture(scope: .custom([.curve]), snapshot: PhotoEditState(settings: curveSource), context: iosContext),
            target: PhotoEditState(settings: curveTarget),
            context: iosContext
        ).settings
        XCTAssertEqual(iosCurve.curveSettings.points, [.init(x: 0, y: 0), .init(x: 0.5, y: 1.0), .init(x: 1, y: 1)])

        var badCurveSource = Adjustments()
        badCurveSource.curveSettings = ToneCurveSettings(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.9), .init(x: 1, y: 1)])
        XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(
            payload: try MacAdjustmentTransfer.capture(scope: .custom([.curve]), snapshot: macState(badCurveSource), context: macContext),
            target: macState(targetHalf),
            context: macContext
        )) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable("light.curve"))
        }
    }

    func testScalarHSLAndTintRangeLimitOvershootOnMacAndIOS() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))

        struct LimitCase {
            let field: AdjustmentTransferField
            let strength: Double
            let storedLimit: Double
            let renderedLiteral: Double
            let apply: (inout Adjustments) -> Void
            let reset: (inout Adjustments) -> Void
            let readStored: (Adjustments) -> Double
        }

        let cases: [LimitCase] = [
            .init(field: .hslHueRed, strength: 0.69, storedLimit: 100.0, renderedLiteral: 69.0,
                  apply: { $0.setHSL(.hue, channel: 0, value: 100.0) },
                  reset: { $0.setHSL(.hue, channel: 0, value: 0.0) },
                  readStored: { $0.hslSettings.value(.hue, channel: 0) }),
            .init(field: .blackPoint, strength: 0.69, storedLimit: 100.0, renderedLiteral: 69.0,
                  apply: { $0.blackPoint = 100.0 },
                  reset: { $0.blackPoint = 0.0 },
                  readStored: { $0.blackPoint }),
            .init(field: .clarity, strength: 0.69, storedLimit: 100.0, renderedLiteral: 69.0,
                  apply: { $0.clarity = 100.0 },
                  reset: { $0.clarity = 0.0 },
                  readStored: { $0.clarity }),
            .init(field: .exposure, strength: 0.237, storedLimit: 5.0, renderedLiteral: 1.185,
                  apply: { $0.exposure = 5.0 },
                  reset: { $0.exposure = 0.0 },
                  readStored: { $0.exposure }),
            .init(field: .contrast, strength: 0.001, storedLimit: 0.0, renderedLiteral: 0.999,
                  apply: { $0.contrast = 0.0 },
                  reset: { $0.contrast = 1.0 },
                  readStored: { $0.contrast }),
        ]

        for item in cases {
            var source = makeRecipeSettings(recipe, strength: item.strength, version: 4)
            item.apply(&source)
            var target = makeRecipeSettings(recipe, strength: item.strength, version: 4)
            item.reset(&target)

            let macPayload = try MacAdjustmentTransfer.capture(scope: .custom([item.field]), snapshot: macState(source), context: macContext)
            let macPasted = try MacAdjustmentTransfer.prepare(payload: macPayload, target: macState(target), context: macContext).settings
            XCTAssertEqual(item.readStored(macPasted), item.storedLimit, "Mac stored \(item.field.rawValue) at \(item.strength)")
            let macRendered = AdjustmentTransfer.effectiveNumbers(macPasted, context: macContext.withMacCapabilities())[item.field]!
            assertSameRenderFloat(macRendered, item.renderedLiteral, "Mac rendered \(item.field.rawValue) at \(item.strength)")

            let iosPayload = try IOSAdjustmentTransfer.capture(scope: .custom([item.field]), snapshot: PhotoEditState(settings: source), context: iosContext)
            let iosPasted = try IOSAdjustmentTransfer.prepare(payload: iosPayload, target: PhotoEditState(settings: target), context: iosContext).settings
            XCTAssertEqual(item.readStored(iosPasted), item.storedLimit, "iOS stored \(item.field.rawValue) at \(item.strength)")
            let iosRendered = AdjustmentTransfer.effectiveNumbers(iosPasted, context: iosContext.withIOSCapabilities())[item.field]!
            assertSameRenderFloat(iosRendered, item.renderedLiteral, "iOS rendered \(item.field.rawValue) at \(item.strength)")
        }

        // Relative tint = 150 at 0.001 -> 0.001 with as-shot (5200, 8): rendered tint = 8.15.
        var tintSource = makeRecipeSettings(recipe, strength: 0.001, version: 4)
        tintSource.tint = 150.0
        var tintTarget = makeRecipeSettings(recipe, strength: 0.001, version: 4)
        tintTarget.tint = 0.0

        let macTintPayload = try MacAdjustmentTransfer.capture(scope: .custom([.tint]), snapshot: macState(tintSource), context: macContext)
        let macTintPasted = try MacAdjustmentTransfer.prepare(payload: macTintPayload, target: macState(tintTarget), context: macContext).settings
        XCTAssertEqual(macTintPasted.tint, 150.0, "Mac stored relative tint at 0.001")
        assertSameRenderFloat(AdjustmentTransfer.renderWB(macTintPasted, context: macContext.withMacCapabilities()).tint, 8.15, "Mac rendered relative tint at 0.001")

        let iosTintPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.tint]), snapshot: PhotoEditState(settings: tintSource), context: iosContext)
        let iosTintPasted = try IOSAdjustmentTransfer.prepare(payload: iosTintPayload, target: PhotoEditState(settings: tintTarget), context: iosContext).settings
        XCTAssertEqual(iosTintPasted.tint, 150.0, "iOS stored relative tint at 0.001")
        assertSameRenderFloat(AdjustmentTransfer.renderWB(iosTintPasted, context: iosContext.withIOSCapabilities()).tint, 8.15, "iOS rendered relative tint at 0.001")
    }

    func testOutOfRangeRequestsPreserveExactRejectionDetailStringsOnMacAndIOS() throws {
        let recipe = try XCTUnwrap(MasterRecipe.recipe(for: recipeID))

        // Guards: genuinely out-of-range requests per family stay rejected with today's exact detail string.
        struct GuardCase {
            let field: AdjustmentTransferField
            let detail: String
            let apply: (inout Adjustments) -> Void
            let reset: (inout Adjustments) -> Void
        }
        let guards: [GuardCase] = [
            .init(field: .exposure, detail: "native range", apply: { $0.exposure = 3.0 }, reset: { $0.exposure = 0.0 }),
            .init(field: .contrast, detail: "native range", apply: { $0.contrast = 0.0 }, reset: { $0.contrast = 1.0 }),
            .init(field: .blackPoint, detail: "native range", apply: { $0.blackPoint = 60.0 }, reset: { $0.blackPoint = 0.0 }),
            .init(field: .clarity, detail: "native range", apply: { $0.clarity = 60.0 }, reset: { $0.clarity = 0.0 }),
            .init(field: .hslHueRed, detail: "color.hsl.hue.red", apply: { $0.setHSL(.hue, channel: 0, value: 60.0) }, reset: { $0.setHSL(.hue, channel: 0, value: 0.0) }),
            .init(field: .tint, detail: "native range", apply: { $0.tint = 100.0 }, reset: { $0.tint = 0.0 }),
        ]
        for guardCase in guards {
            var badSource = makeRecipeSettings(recipe, strength: 1.0, version: 4)
            guardCase.apply(&badSource)
            var halfTarget = makeRecipeSettings(recipe, strength: 0.5, version: 4)
            guardCase.reset(&halfTarget)

            let macBad = try MacAdjustmentTransfer.capture(scope: .custom([guardCase.field]), snapshot: macState(badSource), context: macContext)
            XCTAssertThrowsError(try MacAdjustmentTransfer.prepare(payload: macBad, target: macState(halfTarget), context: macContext), "Mac guard \(guardCase.field.rawValue)") { error in
                XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable(guardCase.detail), "Mac guard detail \(guardCase.field.rawValue)")
            }
            let iosBad = try IOSAdjustmentTransfer.capture(scope: .custom([guardCase.field]), snapshot: PhotoEditState(settings: badSource), context: iosContext)
            XCTAssertThrowsError(try IOSAdjustmentTransfer.prepare(payload: iosBad, target: PhotoEditState(settings: halfTarget), context: iosContext), "iOS guard \(guardCase.field.rawValue)") { error in
                XCTAssertEqual(error as? AdjustmentTransferError, .unrepresentable(guardCase.detail), "iOS guard detail \(guardCase.field.rawValue)")
            }
        }
    }
}
