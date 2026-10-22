import XCTest

extension EditorV4UITests {
    func testRAWNativeHistoryPerspectiveAndBatchEntry() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_RAW_INTEGRATION_UI"] == "1" else {
            throw XCTSkip("Run on a dedicated Photos library seeded with one RAW and explicitly enable RAWLAB_RAW_INTEGRATION_UI.")
        }
        let app = try launchImportedEditor()
        XCTAssertTrue(app.buttons["tool.lens"].isEnabled, "The system picker must import the original RAW")
        try setValue("+0.35", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        try selectTool("geometry", in: app)
        try setValue("12", title: "Horizontal Perspective", control: "geometry.perspectiveHorizontal", in: app)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "An unapplied RAW draft must block export")
        applyDraft(in: app)
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Adjustments Saved'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        app.terminate()
        launchEnglish(app)
        try importFirstVisiblePhoto(in: app)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.35, accuracy: 0.0001)
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(app.buttons["geometry.perspectiveHorizontal.value"]), 12, accuracy: 0.0001)
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled, "Restored RAW geometry starts as an unchanged draft")
        app.buttons["editor.draft.cancel"].tap()
        app.buttons["editor.export"].tap()
        let batch = app.buttons["editor.batchExport"]
        waitUntil(timeout: 90) { batch.isEnabled }
        batch.tap()
        let pick = app.buttons["batch.pick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["batch.export"].isEnabled)
        pick.tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        waitUntil(timeout: 90) { app.buttons["batch.export"].isEnabled }
        XCTAssertTrue(app.staticTexts["DJI_20250602164503_0444_D.DNG"].exists,
                      "The batch must retain the seeded RAW rather than a preview or JPEG")
        capture("v08-integrated-raw-history-perspective-batch", in: app)
    }

    func testParameterInputWorkspaceSessionsAndLayout() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_SOURCE_HARNESS"] == "1" else { throw XCTSkip("Use the workspace UI harness") }
        let german = ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LANGUAGE"] == "de"
        let large = ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LARGE_TEXT"] == "1"
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.geometry-source")
        app.launchArguments = ["-RawLab.language", german ? "de" : "en", "-RawLab.workspaceUIOnly", "-RawLab.parameterInputUI"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let probe = app.staticTexts["geometry.review.probe"]
        func snapshot() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "").utf8)) as? [String: Any])
        }
        func state() throws -> [String: Any] { try XCTUnwrap(try snapshot()["editorState"] as? [String: Any]) }
        func hue() throws -> Double {
            let settings = try XCTUnwrap(try state()["settings"] as? [String: Any])
            let hsl = try XCTUnwrap(settings["hsl"] as? [String: Any])
            return try XCTUnwrap((hsl["hue"] as? [Double])?.first)
        }
        func record(_ name: String) throws {
            let data = try JSONSerialization.data(withJSONObject: snapshot(), options: [.sortedKeys])
            let item = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); item.name = name; item.lifetime = .keepAlways; add(item)
            print("PARAMETER_WORKSPACE \(name) \(String(decoding: data, as: UTF8.self))")
        }
        func noEdit(since before: [String: Any], _ label: String) throws {
            let after = try snapshot()
            let savesBefore = before["saveAttemptCount"] as? Int, savesAfter = after["saveAttemptCount"] as? Int
            let previewsBefore = (before["previewReceipts"] as? [Any])?.count, previewsAfter = (after["previewReceipts"] as? [Any])?.count
            print("PARAMETER_NO_EDIT \(label) saves=\(String(describing: savesBefore))->\(String(describing: savesAfter)) previews=\(String(describing: previewsBefore))->\(String(describing: previewsAfter))")
            XCTAssertEqual(savesBefore, savesAfter, label); XCTAssertEqual(previewsBefore, previewsAfter, label)
        }
        var verifiedFineHit = false
        func fine(_ on: Bool) throws {
            let before = try snapshot()
            let toggle = app.switches["editor.fine"]
            try revealInPanel(toggle, in: app, fully: true)
            try revealHorizontally(toggle, in: app.scrollViews["editor.parameterHeader"], app: app)
            XCTAssertTrue(toggle.isHittable)
            let measured = try XCTUnwrap((try snapshot()["layoutFrames"] as? [String: [Double]])?["fine"])
            let frame = CGRect(x: measured[0], y: measured[1], width: measured[2], height: measured[3])
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            if !verifiedFineHit {
                let before = try state()["fine"] as? Bool
                let native = try XCTUnwrap(try snapshot()["nativeSwitches"] as? [[Double]])
                    .map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
                    .filter { frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.midX, y: $0.midY)) }
                XCTAssertEqual(native.count, 1)
                let control = try XCTUnwrap(native.first)
                let target = CGRect(x: control.midX - 22, y: control.midY - 22, width: 44, height: 44)
                let point = CGPoint(x: control.midX, y: control.midY - 21.5)
                print("PARAMETER_FINE_HIT layout=\(frame) ax=\(toggle.frame) native=\(control) target=\(target) point=\(point)")
                // 44pt 目标围绕真实UISwitch中心，不把放大label的整块边缘当作开关触点。
                XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(target))
                XCTAssertTrue(target.contains(point)); XCTAssertFalse(control.contains(point))
                capture("parameter-fine-before-outside-glyph-tap", in: app)
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
                waitUntil { (try? state()["fine"] as? Bool) != before }
                XCTAssertNotEqual(try state()["fine"] as? Bool, before, "The native Toggle accepts touches within its complete44pt layout")
                capture("parameter-fine-after-outside-glyph-tap", in: app)
                verifiedFineHit = true
            }
            if (toggle.value as? String == "1") != on { toggle.tap() }
            waitUntil { (try? state()["fine"] as? Bool) == on }
            XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
            try noEdit(since: before, "fine mode only")
        }
        waitUntil(timeout: 30) { (try? snapshot()["done"] as? Bool) == true }
        try selectTool("hsl", in: app)
        let originalPanel = (try snapshot()["layoutFrames"] as? [String: [Double]])?["panel"]
        for axis in ["hue", "saturation", "lightness"] {
            let value = app.buttons["hsl.\(axis).value"]
            if large { try revealInPanel(value, in: app, fully: true) }
            XCTAssertTrue(value.isHittable)
            XCTAssertTrue(app.scrollViews["editor.panel"].frame.contains(value.frame))
            XCTAssertFalse((value.value as? String ?? "").contains("%")); XCTAssertFalse((value.value as? String ?? "").contains("°"))
            XCTAssertFalse(app.buttons["hsl.\(axis).fine"].exists); XCTAssertFalse(app.buttons["hsl.\(axis).reset"].exists)
            if !large {
                XCTAssertEqual(value.frame.midY, app.descendants(matching: .any)["hsl.\(axis).ruler"].frame.midY, accuracy: 2)
            }
        }
        capture("parameter-workspace-three-axes", in: app)
        try revealInPanel(app.buttons["hsl.hue.value"], in: app, fully: true)
        XCTAssertEqual(app.buttons["hsl.hue.value"].value as? String, german ? "+0,5" : "+0.5")
        let before = try snapshot()
        try openWheel("hsl.hue.value", in: app)
        app.buttons["adjustment.wheel.apply"].tap()
        waitUntil { !app.buttons["adjustment.wheel.apply"].exists }
        XCTAssertEqual(try hue(), 0.5)
        try noEdit(since: before, "unchanged half-value Apply")
        try fine(true)
        // 真实同值换照片：夹具只提供外部导入事件，旧输入仍由生产 scope 关闭。
        let source = try state()["sourceRevision"] as? String
        let beforeSource = try snapshot()
        let beforeSettings = try JSONSerialization.data(withJSONObject: try XCTUnwrap(try state()["settings"]), options: [.sortedKeys])
        try openWheel("hsl.hue.value", in: app)
        try selectWheelValue("+1", title: "Hue", in: app)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.tests.parameter-inputs.next-source" as CFString), nil, nil, true)
        waitUntil(timeout: 35) { (try? state()["sourceRevision"] as? String) != source && ((try? snapshot()["details"] as? [String: String])?["sourceSwitch"] == "completed") }
        XCTAssertFalse(app.buttons["adjustment.wheel.apply"].exists)
        XCTAssertEqual(try hue(), 0.5)
        XCTAssertEqual(try state()["fine"] as? Bool, false)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: try XCTUnwrap(try state()["settings"]), options: [.sortedKeys]), beforeSettings)
        let imported = try snapshot()
        let previews = try XCTUnwrap(imported["previewReceipts"] as? [[String: Any]])
        let saves = try XCTUnwrap(imported["saveReceipts"] as? [[String: Any]])
        let previewStart = (beforeSource["previewReceipts"] as? [Any])?.count ?? 0
        let saveStart = (beforeSource["saveReceipts"] as? [Any])?.count ?? 0
        for receipt in previews.dropFirst(previewStart) {
            let settings = try XCTUnwrap(receipt["settings"] as? [String: Any])
            let hsl = try XCTUnwrap(settings["hsl"] as? [String: Any])
            XCTAssertNotEqual((hsl["hue"] as? [Double])?.first, 1, "The old wheel candidate never enters a source-lifecycle preview")
        }
        for receipt in saves.dropFirst(saveStart) {
            let saved = try XCTUnwrap(receipt["state"] as? [String: Any])
            let settings = try XCTUnwrap(saved["settings"] as? [String: Any])
            let hsl = try XCTUnwrap(settings["hsl"] as? [String: Any])
            XCTAssertNotEqual((hsl["hue"] as? [Double])?.first, 1, "The old wheel candidate never reaches persistence")
        }
        print("PARAMETER_SOURCE_LIFECYCLE source=\(String(describing: source))->\(String(describing: try state()["sourceRevision"])) saves=\(saveStart)->\(saves.count) previews=\(previewStart)->\(previews.count)")
        try record("parameter-same-value-source-invalidated")
        try fine(true)
        let beforeChannel = try snapshot()
        try revealInPanel(app.buttons["hsl.channel.1"], in: app, fully: true); app.buttons["hsl.channel.1"].tap()
        XCTAssertEqual(try state()["fine"] as? Bool, true, "Channel selection shares the panel mode")
        try noEdit(since: beforeChannel, "channel selection")
        let beforeGroup = try snapshot()
        try selectTool("exposure", in: app)
        XCTAssertEqual(try state()["fine"] as? Bool, false, "A real group/tool change clears fine")
        try noEdit(since: beforeGroup, "actual group change")
        try fine(true)
        let beforeTool = try snapshot()
        try selectTool("highlights", in: app)
        XCTAssertEqual(try state()["fine"] as? Bool, false, "A tool change within one group clears fine")
        try noEdit(since: beforeTool, "actual tool change")
        XCTAssertEqual((try snapshot()["layoutFrames"] as? [String: [Double]])?["panel"], originalPanel)
        try selectTool("geometry", in: app); try fine(true)
        let rotate = app.buttons["geometry.rotateRight"]; try revealInPanel(rotate, in: app); rotate.tap()
        waitUntil(timeout: 20) { app.buttons["editor.draft.apply"].isEnabled }
        let beforeStay = try snapshot()
        let effects = app.buttons["editor.group.effects"]
        try revealHorizontally(effects, in: app.scrollViews["editor.groups"], app: app); effects.tap()
        let stay = app.alerts.buttons[german ? "Weiter bearbeiten" : "Keep Editing"]
        XCTAssertTrue(stay.waitForExistence(timeout: 5)); stay.tap()
        XCTAssertEqual(try state()["fine"] as? Bool, true, "Stay does not change tools or clear the panel mode")
        XCTAssertEqual(try state()["draftChanged"] as? Bool, true)
        try noEdit(since: beforeStay, "Stay keeps the draft and mode")
        try record("parameter-draft-stay-keeps-fine")
        app.buttons["editor.draft.cancel"].tap()
        try selectTool("hsl", in: app)
        try revealInPanel(app.buttons["hsl.channel.0"], in: app, fully: true); app.buttons["hsl.channel.0"].tap()
        let title = app.staticTexts["hsl.hue.title"]; try revealInPanel(title, in: app, fully: true); title.doubleTap()
        waitUntil { (try? hue()) == 0 }
        XCTAssertEqual(try hue(), 0)
        capture("parameter-workspace-single-reset", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        let last = app.buttons["hsl.lightness.value"]; try revealInPanel(last, in: app, fully: true)
        XCTAssertTrue(app.scrollViews["editor.panel"].frame.contains(last.frame)); XCTAssertTrue(last.isHittable)
        print("PARAMETER_SHORT panel=\(app.scrollViews["editor.panel"].frame) last=\(last.frame) photo=\(app.images["editor.photo"].frame)")
        capture("parameter-workspace-landscape-last", in: app)
        try record("parameter-workspace-complete")
    }

    func testGeometrySourceRestorationUsesUncroppedPreview() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_SOURCE_HARNESS"] == "1" else {
            throw XCTSkip("Run RawLab/tests/geometry-source-ui.sh to enable the separate source-restoration harness.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.geometry-source")
        app.launchArguments = ["-RawLab.language", ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LANGUAGE"] ?? "en"]
        if ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LARGE_TEXT"] == "1" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let probe = app.staticTexts["geometry.review.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = probe.value as? String, let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["done"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 240), .completed)
        let text = try XCTUnwrap(probe.value as? String)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let checks = try XCTUnwrap(json["checks"] as? [String: Bool])
        print("Geometry source harness result: \(text)")
        XCTAssertGreaterThanOrEqual(checks.count, 35)
        let failures = checks.filter { !$0.value }.map(\.key).sorted()
        XCTAssertFalse((app.buttons["tool.film"].value as? String ?? "").isEmpty,
                       "Film accessibility value must retain the selected film name")
        XCTAssertTrue(failures.isEmpty, "Failed checks: \(failures)\n\(text)")
        let nativeAttachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.json")
        nativeAttachment.name = "workspace-native-results"; nativeAttachment.lifetime = .keepAlways; add(nativeAttachment)
        // direct-call harness 边界可能残留 system presentation；真实 UI 在新进程单独验证。
        app.terminate()
        app.launchArguments.append("-RawLab.workspaceUIOnly")
        app.launch()
        waitUntil(timeout: 30) {
            guard let value = probe.value as? String, let data = value.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["done"] as? Bool == true
        }
        XCTAssertFalse(app.alerts.firstMatch.exists, "The UI-only process never drives reset state directly")
        func snapshot() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "").utf8)) as? [String: Any])
        }
        func editorState() throws -> [String: Any] { try XCTUnwrap(try snapshot()["editorState"] as? [String: Any]) }
        func recordState(_ name: String) throws -> [String: Any] {
            var value = try editorState()
            value["saveAttemptCount"] = try snapshot()["saveAttemptCount"]
            value["previewCount"] = (try snapshot()["previewReceipts"] as? [Any])?.count
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            print("WORKSPACE_UI_STATE \(name): \(String(decoding: data, as: UTF8.self))")
            return value
        }
        let groups = ["looks", "light", "color", "effects", "detail", "geometry"]
        let expectedTools = ["film", "exposure", "temperature", "vignette", "noiseReduction", "geometry"]
        let navigation = app.scrollViews["editor.groups"]
        XCTAssertTrue(navigation.exists)
        func selectGroup(_ id: String) throws {
            let group = app.buttons["editor.group." + id]
            try revealHorizontally(group, in: navigation, app: app)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "").utf8)) as? [String: Any])
            let groups = try XCTUnwrap(json["groupRects"] as? [String: [Double]])
            let texts = try XCTUnwrap(json["groupTextRects"] as? [String: [Double]])
            let g = try XCTUnwrap(groups[id]); let t = try XCTUnwrap(texts[id])
            let frame = CGRect(x: g[0], y: g[1], width: g[2], height: g[3])
            let text = CGRect(x: t[0], y: t[1], width: t[2], height: t[3])
            let edges = [CGPoint(x: frame.minX + 2, y: frame.midY), CGPoint(x: frame.maxX - 2, y: frame.midY)]
            let point = try XCTUnwrap(edges.first { frame.contains($0) && !text.contains($0) && navigation.frame.contains($0) }, "The full group target must include a reachable point outside its text")
            XCTAssertGreaterThanOrEqual(frame.width, 44); XCTAssertGreaterThanOrEqual(frame.height, 44)
            print("WORKSPACE_HIT \(id): layout=\(frame) text=\(text) point=\(point)")
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
        func panelFrame() throws -> CGRect {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "").utf8)) as? [String: Any])
            let layouts = try XCTUnwrap(json["layoutFrames"] as? [String: [Double]])
            let frame = try XCTUnwrap(layouts["panel"])
            return CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
        }
        func layoutReceipt(_ name: String) throws -> [String: Any] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "").utf8)) as? [String: Any])
            var policy = try XCTUnwrap(json["layoutPolicy"] as? [String: Any])
            policy["groupFrames"] = groups.map { id -> [String: Any] in
                let frame = app.buttons["editor.group." + id].frame
                XCTAssertGreaterThanOrEqual(frame.width, 44)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
                return ["id": id, "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            }
            let width = try XCTUnwrap(policy["width"] as? Double)
            let height = try XCTUnwrap(policy["height"] as? Double)
            let accessibility = try XCTUnwrap(policy["accessibility"] as? Bool)
            let required = try XCTUnwrap(policy["requiredWidth"] as? Double)
            let sideWidth = try XCTUnwrap(policy["sideWidth"] as? Double)
            if ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LANGUAGE"] == "zh-Hans" && !accessibility {
                XCTAssertEqual(policy["buttonWidth"] as? Double, 44, "CJK fallback glyphs fit two actual lines at the 44pt target")
            }
            let rects = try XCTUnwrap(json["groupRects"] as? [String: [Double]])
            let texts = try XCTUnwrap(json["groupTextRects"] as? [String: [Double]])
            let buttonHeight = try XCTUnwrap(policy["buttonHeight"] as? Double)
            for id in groups {
                let g = try XCTUnwrap(rects[id]); let t = try XCTUnwrap(texts[id])
                XCTAssertEqual(g[3], buttonHeight, accuracy: 1)
                XCTAssertGreaterThanOrEqual(t[1], g[1] - 1, "Complete group text stays inside its target")
                XCTAssertLessThanOrEqual(t[1] + t[3], g[1] + g[3] + 1)
            }
            let expectedSide = width >= 600 && width > height && !accessibility && required <= sideWidth
            XCTAssertEqual(policy["side"] as? Bool, expectedSide)
            let frame = try panelFrame()
            if expectedSide {
                XCTAssertEqual(frame.width, sideWidth, accuracy: 1)
                XCTAssertGreaterThan(frame.minX, app.frame.midX, "A fitting wide-window panel must be beside the photo")
            } else {
                XCTAssertEqual(frame.width, width, accuracy: 1, "Narrow, accessibility or non-fitting text uses the bottom layout")
            }
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: policy, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            print("WORKSPACE_LAYOUT \(name): \(policy)")
            return policy
        }
        var regionFrame: CGRect?
        _ = try layoutReceipt("workspace-portrait-layout")
        for (group, tool) in zip(groups, expectedTools) {
            if group != "looks" { try selectGroup(group) }
            let target = app.buttons["tool." + tool]
            XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(target.isSelected)
            if tool == "exposure" {
                XCTAssertTrue((target.value as? String ?? "").contains("EV"), "Exposure accessibility value retains its number and EV unit")
            }
            XCTAssertGreaterThanOrEqual(target.frame.height, 44)
            XCTAssertTrue(app.scrollViews["editor.panel"].exists)
            if let frame = regionFrame {
                XCTAssertEqual(try panelFrame(), frame, "Tool content must keep the same measured outer panel frame")
            } else { regionFrame = try panelFrame() }
            capture("workspace-group-" + group, in: app)
        }
        try selectGroup("geometry")
        XCTAssertFalse(app.scrollViews["editor.panel"].exists, "Repeated group tap collapses parameters")
        XCTAssertTrue(navigation.exists, "Group navigation stays present when collapsed")
        try selectGroup("color")
        try selectTool("hsl", in: app)
        let swatch = app.buttons["hsl.channel.6"]
        let colors = app.scrollViews.containing(.button, identifier: "hsl.channel.6").firstMatch
        try revealHorizontally(swatch, in: colors, app: app)
        swatch.tap()
        try selectGroup("light")
        try selectGroup("color")
        try selectTool("hsl", in: app)
        XCTAssertTrue(app.buttons["hsl.channel.6"].isSelected, "HSL channel belongs to the editing session")
        try revealInPanel(app.buttons["hsl.lightness.value"], in: app)
        XCTAssertTrue(app.buttons["hsl.lightness.value"].isHittable)
        capture("workspace-hsl-session", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        XCTAssertTrue(app.scrollViews["editor.groups"].isHittable)
        capture("workspace-landscape", in: app)
        let policy = try layoutReceipt("workspace-landscape-layout")
        let landscapePanelFrame = try panelFrame()
        if ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LARGE_TEXT"] == "1" {
            if policy["scrollTools"] as? Bool == true {
                XCTAssertGreaterThan(app.images["editor.photo"].frame.height, 0)
                XCTAssertGreaterThan(app.images["editor.photo"].frame.width, 0)
            } else { assertLargeTextPhotoVisible(in: app) }
        }
        try selectGroup("color")
        XCTAssertFalse(app.scrollViews["editor.panel"].exists)
        let width = try XCTUnwrap(policy["width"] as? Double)
        let height = try XCTUnwrap(policy["height"] as? Double)
        let accessibility = try XCTUnwrap(policy["accessibility"] as? Bool)
        let buttonWidth = try XCTUnwrap(policy["buttonWidth"] as? Double)
        let sideWidth = try XCTUnwrap(policy["sideWidth"] as? Double)
        let expectedCollapsedSide = width >= 600 && width > height && !accessibility && buttonWidth * 3 + 16 <= sideWidth
        let first = app.buttons["editor.group.looks"].frame
        let fourth = app.buttons["editor.group.effects"].frame
        XCTAssertEqual(abs(first.minY - fourth.minY) > 1, expectedCollapsedSide, "A fitting collapsed sidebar exposes the six groups in two rows")
        capture("workspace-landscape-collapsed", in: app)
        try selectGroup("color")
        XCTAssertTrue(app.buttons["tool.hsl"].isSelected)

        XCUIDevice.shared.orientation = .portrait
        waitUntil { app.frame.height > app.frame.width }
        try selectGroup("light")
        let isGerman = ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LANGUAGE"] == "de"
        let allLabel = isGerman ? "Alle Anpassungen zurücksetzen…" : "重置全部调整…"
        let cancelLabel = isGerman ? "Abbrechen" : "取消"
        func openAllReset() throws {
            try revealInPanel(app.buttons["editor.reset"], in: app, fully: true)
            app.buttons["editor.reset"].tap()
            let all = app.buttons[allLabel]
            XCTAssertTrue(all.waitForExistence(timeout: 5)); XCTAssertTrue(all.isEnabled); all.tap()
        }
        let beforeCancel = try recordState("workspace-real-all-before")
        try openAllReset()
        waitUntil { (try? editorState()["prepared"] as? Bool) == true && (try? editorState()["presented"] as? Bool) == true }
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        _ = try recordState("workspace-real-all-confirmation")
        capture("workspace-real-all-confirmation", in: app)
        app.alerts.buttons[cancelLabel].tap()
        waitUntil { !app.alerts.firstMatch.exists && (try? editorState()["prepared"] as? Bool) == false && (try? editorState()["presented"] as? Bool) == false }
        let afterCancel = try recordState("workspace-real-all-cancelled")
        XCTAssertEqual(beforeCancel["saveAttemptCount"] as? Int, afterCancel["saveAttemptCount"] as? Int)
        XCTAssertEqual(beforeCancel["previewCount"] as? Int, afterCancel["previewCount"] as? Int)
        try selectGroup("effects")
        XCTAssertTrue(app.buttons["tool.vignette"].isSelected, "Real Cancel leaves group navigation clickable")
        try selectGroup("geometry")
        let rotate = app.buttons["geometry.rotateRight"]
        try revealInPanel(rotate, in: app); rotate.tap()
        waitUntil(timeout: 30) { app.buttons["editor.draft.apply"].isEnabled }
        let dirty = try recordState("workspace-real-dirty-draft")
        XCTAssertEqual(dirty["draftChanged"] as? Bool, true)
        try openAllReset()
        let discard = app.alerts.buttons[isGerman ? "Änderungen verwerfen" : "放弃修改"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10)); discard.tap()
        waitUntil(timeout: 30) { (try? editorState()["prepared"] as? Bool) == true && (try? editorState()["presented"] as? Bool) == true }
        XCTAssertTrue(app.alerts.buttons[cancelLabel].waitForExistence(timeout: 10))
        _ = try recordState("workspace-real-discard-all-confirmation")
        capture("workspace-real-discard-all-confirmation", in: app)
        app.alerts.buttons[cancelLabel].tap()
        waitUntil { !app.alerts.firstMatch.exists && (try? editorState()["prepared"] as? Bool) == false && (try? editorState()["presented"] as? Bool) == false }
        let fresh = try recordState("workspace-real-discard-all-cancelled")
        XCTAssertEqual(fresh["geometrySelected"] as? Bool, true)
        XCTAssertEqual(fresh["draftActive"] as? Bool, true)
        XCTAssertEqual(fresh["draftChanged"] as? Bool, false)
        XCTAssertEqual(fresh["freshGeometry"] as? Bool, true)
        XCTAssertEqual(dirty["saveAttemptCount"] as? Int, fresh["saveAttemptCount"] as? Int)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        XCTAssertEqual(try panelFrame(), landscapePanelFrame, "Draft actions do not change the outer panel budget")
        let last = app.buttons["geometry.cropHeight.value"]
        try revealInPanel(last, in: app, fully: true)
        let scroll = app.scrollViews["editor.panel"]
        let apply = app.buttons["editor.draft.apply"]
        let cancel = app.buttons["editor.draft.cancel"]
        capture("workspace-draft-landscape-last-control", in: app)
        print("WORKSPACE_DRAFT_RECTS scroll=\(scroll.frame) last=\(last.frame) apply=\(apply.frame) cancel=\(cancel.frame) photo=\(app.images["editor.photo"].frame)")
        XCTAssertTrue(app.frame.contains(apply.frame)); XCTAssertTrue(app.frame.contains(cancel.frame))
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(scroll.frame.contains(last.frame), "A complete final parameter must fit above the fixed draft actions")
        XCTAssertTrue(last.isHittable)
    }

    func testWorkspaceResetHeaderGlyphsAndCancel() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_SOURCE_HARNESS"] == "1" else { throw XCTSkip("Use the dedicated workspace harness") }
        let german = ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LANGUAGE"] == "de"
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.geometry-source")
        app.launchArguments = ["-RawLab.language", german ? "de" : "zh-Hans", "-RawLab.workspaceUIOnly"]
        if ProcessInfo.processInfo.environment["RAWLAB_WORKSPACE_LARGE_TEXT"] == "1" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let probe = app.staticTexts["geometry.review.probe"]
        func snapshot() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "").utf8)) as? [String: Any])
        }
        waitUntil(timeout: 30) { (try? snapshot()["done"] as? Bool) == true }
        try selectTool("exposure", in: app)
        let reset = app.buttons["editor.reset"]
        try revealInPanel(reset, in: app, fully: true)
        let glyphs = reset.images.allElementsBoundByIndex
        print("WORKSPACE_RESET_GLYPHS window=\(app.frame) button=\(reset.frame) glyphs=\(glyphs.map { "\($0.label):\($0.frame)" })")
        capture("workspace-reset-header-glyphs", in: app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "workspace-reset-header-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertEqual(glyphs.count, 2)
        XCTAssertGreaterThanOrEqual(reset.frame.width, 44); XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
        for glyph in glyphs {
            XCTAssertTrue(app.frame.contains(glyph.frame), "The complete \(glyph.label) glyph stays inside the window")
            XCTAssertTrue(reset.frame.insetBy(dx: -1, dy: -1).contains(glyph.frame), "The menu label contains the complete \(glyph.label) glyph")
        }
        let before = try snapshot()
        let frames = try XCTUnwrap(before["layoutFrames"] as? [String: [Double]])
        print("WORKSPACE_RESET_OUTER_FRAMES ordinary=\(frames)")
        reset.tap()
        let all = app.buttons[german ? "Alle Anpassungen zurücksetzen…" : "重置全部调整…"]
        XCTAssertTrue(all.waitForExistence(timeout: 5)); XCTAssertTrue(all.isEnabled); all.tap()
        waitUntil {
            guard let state = try? snapshot()["editorState"] as? [String: Any] else { return false }
            return state["prepared"] as? Bool == true && state["presented"] as? Bool == true
        }
        let confirmation = try snapshot()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        capture("workspace-reset-header-all-confirmation", in: app)
        app.alerts.buttons[german ? "Abbrechen" : "取消"].tap()
        waitUntil {
            guard let state = try? snapshot()["editorState"] as? [String: Any] else { return false }
            return !app.alerts.firstMatch.exists && state["prepared"] as? Bool == false && state["presented"] as? Bool == false
        }
        let after = try snapshot()
        XCTAssertEqual(before["saveAttemptCount"] as? Int, after["saveAttemptCount"] as? Int)
        XCTAssertEqual((before["previewReceipts"] as? [Any])?.count, (after["previewReceipts"] as? [Any])?.count)
        for (name, state) in [("before", before), ("confirmation", confirmation), ("cancelled", after)] {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "workspace-reset-header-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let effects = app.buttons["editor.group.effects"]
        try revealHorizontally(effects, in: app.scrollViews["editor.groups"], app: app); effects.tap()
        XCTAssertTrue(app.buttons["tool.vignette"].isSelected)
        capture("workspace-reset-header-after-cancel", in: app)
        // 仅测试夹具替换标题文字，沿用相同 Text 字体、两行上限及布局优先级。
        app.terminate()
        app.launchArguments.append("-RawLab.workspaceLongHeader")
        app.launch()
        waitUntil(timeout: 30) { (try? snapshot()["done"] as? Bool) == true }
        try selectTool("exposure", in: app)
        try revealInPanel(reset, in: app, fully: true)
        let title = app.staticTexts["Hideaki Hamada – Ausführliche Filmrezept-Anpassungen für natürliches Tageslicht"]
        XCTAssertTrue(title.exists)
        let longFrames = try XCTUnwrap(try snapshot()["layoutFrames"] as? [String: [Double]])
        print("WORKSPACE_RESET_OUTER_FRAMES longTitle=\(longFrames)")
        XCTAssertEqual(frames, longFrames, "The menu and title retain the same header and parameter budget")
        print("WORKSPACE_RESET_LONG_TITLE window=\(app.frame) button=\(reset.frame) title=\(title.frame) glyphs=\(reset.images.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" })")
        capture("workspace-reset-header-long-title", in: app)
        for glyph in reset.images.allElementsBoundByIndex {
            XCTAssertTrue(app.frame.contains(glyph.frame)); XCTAssertTrue(reset.frame.insetBy(dx: -1, dy: -1).contains(glyph.frame))
            XCTAssertLessThanOrEqual(title.frame.maxX, reset.frame.minX)
        }
    }

    func testWorkspaceShortAccessibilityDraftLayout() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_SOURCE_HARNESS"] == "1" else { throw XCTSkip("Use the dedicated workspace harness") }
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.geometry-source")
        app.launchArguments = ["-RawLab.language", "de", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-RawLab.workspaceUIOnly"]
        app.launch()
        let probe = app.staticTexts["geometry.review.probe"]
        waitUntil(timeout: 30) {
            guard let value = probe.value as? String, let data = value.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["done"] as? Bool == true
        }
        try selectTool("geometry", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        let scroll = app.scrollViews["editor.panel"]
        let last = app.buttons["geometry.cropHeight.value"]
        let apply = app.buttons["editor.draft.apply"]
        let cancel = app.buttons["editor.draft.cancel"]
        capture("workspace-short-draft-before-scroll", in: app)
        print("WORKSPACE_SHORT_DRAFT scroll=\(scroll.frame) last=\(last.frame) apply=\(apply.frame) cancel=\(cancel.frame) photo=\(app.images["editor.photo"].frame)")
        XCTAssertGreaterThanOrEqual(scroll.frame.height, last.frame.height, "The scrolling parameters must fit a complete operable value")
        try revealInPanel(last, in: app, fully: true)
        XCTAssertTrue(scroll.frame.contains(last.frame)); XCTAssertTrue(last.isHittable)
        XCTAssertTrue(app.frame.contains(apply.frame)); XCTAssertTrue(app.frame.contains(cancel.frame)); XCTAssertTrue(cancel.isHittable)
        capture("workspace-short-draft-last-control", in: app)
        let expandedPhoto = app.images["editor.photo"].frame
        let geometryTool = app.buttons["tool.geometry"]
        try revealInPanel(geometryTool, in: app, fully: true)
        XCTAssertTrue(scroll.frame.contains(geometryTool.frame)); XCTAssertTrue(geometryTool.isHittable)
        geometryTool.tap(); XCTAssertTrue(geometryTool.isSelected)
        print("WORKSPACE_SHORT_TOOL scroll=\(scroll.frame) tool=\(geometryTool.frame) photo=\(expandedPhoto)")
        let group = app.buttons["editor.group.geometry"]
        try revealHorizontally(group, in: app.scrollViews["editor.groups"], app: app); group.tap()
        waitUntil { !app.scrollViews["editor.panel"].exists }
        let collapsedPhoto = app.images["editor.photo"].frame
        XCTAssertGreaterThan(collapsedPhoto.height, expandedPhoto.height + 80)
        print("WORKSPACE_SHORT_PHOTO expanded=\(expandedPhoto) collapsed=\(collapsedPhoto)")
        capture("workspace-short-photo-collapsed", in: app)
        group.tap()
        XCTAssertTrue(app.buttons["tool.geometry"].isSelected)
        // 从末项滚回组内工具，再跨工具验证选择与 HSL 会话仍可用。
        try selectTool("hsl", in: app)
        let swatch = app.buttons["hsl.channel.6"]
        try revealInPanel(swatch, in: app)
        let colors = app.scrollViews.containing(.button, identifier: "hsl.channel.6").allElementsBoundByIndex.min { $0.frame.height < $1.frame.height }!
        try revealHorizontally(swatch, in: colors, app: app); swatch.tap()
        try revealInPanel(app.buttons["hsl.lightness.value"], in: app, fully: true)
        try revealInPanel(app.buttons["tool.saturation"], in: app, fully: true)
        try selectTool("saturation", in: app)
        XCTAssertTrue(app.buttons["tool.saturation"].isSelected)
        try selectTool("hsl", in: app)
        XCTAssertTrue(app.buttons["hsl.channel.6"].isSelected)
        capture("workspace-short-tools-reachable", in: app)
    }

    func testExposureNativeWheelCancelApplySignAndDefault() throws {
        let app = try launchImportedEditor()
        try selectTool("exposure", in: app)
        try resetParameterDefault("adjustment", in: app)
        let value = app.buttons["adjustment.value"]
        XCTAssertEqual(try number(value), 0, accuracy: 0.0001)
        capture("v4-loaded-exposure", in: app)

        try openWheel("adjustment.value", in: app)
        try selectWheelValue("+0.50", title: "Exposure", unit: "EV", in: app)
        capture("v4-native-exposure-wheel", in: app)
        app.buttons["adjustment.wheel.cancel"].tap()
        waitUntil { !app.descendants(matching: .any)["adjustment.wheel"].exists }
        XCTAssertEqual(try number(value), 0, accuracy: 0.0001, "Cancel must leave the editor value unchanged")

        try setValue("+0.50", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        XCTAssertEqual(try number(value), 0.5, accuracy: 0.0001)
        XCTAssertTrue((value.value as? String)?.hasPrefix("+") == true, value.debugDescription)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, "+0.50 EV")

        try setValue("-0.25", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        XCTAssertEqual(try number(value), -0.25, accuracy: 0.0001)
        XCTAssertTrue((value.value as? String)?.hasPrefix("-") == true, value.debugDescription)

        try openWheel("adjustment.value", in: app)
        app.buttons["adjustment.wheel.default"].tap()
        XCTAssertTrue(app.staticTexts["adjustment.wheel.draft"].label.contains("0.00"))
        app.buttons["adjustment.wheel.cancel"].tap()
        waitUntil { !app.descendants(matching: .any)["adjustment.wheel"].exists }
        XCTAssertEqual(try number(value), -0.25, accuracy: 0.0001, "Canceling the default choice must preserve the committed value")
        try openWheel("adjustment.value", in: app)
        app.buttons["adjustment.wheel.default"].tap()
        app.buttons["adjustment.wheel.apply"].tap()
        waitUntil { app.buttons["adjustment.value"].isHittable }
        XCTAssertEqual(try number(value), 0, accuracy: 0.0001)
        XCTAssertFalse(app.buttons["adjustment.reset"].exists, "Single-value reset is available through default/semantic actions")
    }

    func testRulerAndFineAdjustmentKeepExposureGridAndLimits() throws {
        let app = try launchImportedEditor()
        try selectTool("exposure", in: app)
        try resetParameterDefault("adjustment", in: app)
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        try revealInPanel(ruler, in: app)
        XCTAssertTrue(ruler.isHittable)
        XCTAssertGreaterThan(ruler.frame.width, ruler.frame.height, "The adjustment ruler must run horizontally")
        dragRuler(ruler, from: 0.75, to: 0.25)
        capture("v4-ruler-after-standard-drag", in: app)
        waitUntil { (try? self.number(app.buttons["adjustment.value"])) != 0 }
        let standard = try number(app.buttons["adjustment.value"])
        assertExposureGrid(standard)
        XCTAssertGreaterThan(standard, 0)
        XCTAssertEqual(try number(ruler), standard, accuracy: 0.0001)

        try resetParameterDefault("adjustment", in: app)
        let fine = app.switches["editor.fine"]
        try revealInPanel(fine, in: app, fully: true)
        try revealHorizontally(fine, in: app.scrollViews["editor.parameterHeader"], app: app)
        let standardSensitivity = fine.value as? String
        fine.tap()
        XCTAssertEqual(fine.value as? String, "1", fine.debugDescription)
        XCTAssertNotEqual(fine.value as? String, standardSensitivity)
        try revealInPanel(ruler, in: app)
        dragRuler(ruler, from: 0.75, to: 0.25)
        waitUntil { (try? self.number(app.buttons["adjustment.value"])) != 0 }
        let precise = try number(app.buttons["adjustment.value"])
        assertExposureGrid(precise)
        XCTAssertGreaterThan(precise, 0)
        XCTAssertLessThan(precise, standard, "The same gesture in fine mode must move fewer legal steps")
        XCTAssertEqual(try number(ruler), precise, accuracy: 0.0001)
        fine.tap()
        XCTAssertEqual(fine.value as? String, "0")
        XCTAssertEqual(fine.value as? String, standardSensitivity)

        try setValue("+4.00", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        try revealInPanel(ruler, in: app)
        dragRuler(ruler, from: 0.75, to: 0.25)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 4, accuracy: 0.0001)
        try setValue("-4.00", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        try revealInPanel(ruler, in: app)
        dragRuler(ruler, from: 0.25, to: 0.75)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), -4, accuracy: 0.0001)
        try resetParameterDefault("adjustment", in: app)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0, accuracy: 0.0001)
        capture("v4-exposure-ruler", in: app)
    }

    func testGeometryDraftCancelApplyAndToolExitPreserveCommittedValue() throws {
        let app = try launchImportedEditor()
        try selectTool("geometry", in: app)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "Entering an unchanged geometry draft must block export")
        if app.buttons["geometry.reset"].isEnabled {
            resetIfEnabled("geometry.reset", in: app)
            applyDraft(in: app)
            try selectTool("geometry", in: app)
        }
        let straighten = app.buttons["geometry.straighten.value"]
        XCTAssertEqual(try number(straighten), 0, accuracy: 0.0001)
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled)

        try setValue("2.3", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        waitUntil(timeout: 60) { app.buttons["editor.draft.apply"].isEnabled }
        app.buttons["editor.draft.cancel"].tap()
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5), "Cancel returns to ordinary editing")
        XCTAssertFalse(app.buttons["editor.draft.apply"].exists)
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(straighten), 0, accuracy: 0.0001)
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled)

        try setValue("3.4", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        applyDraft(in: app)
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5), "Apply returns to ordinary editing")
        XCTAssertFalse(app.buttons["editor.draft.apply"].exists)
        try selectTool("geometry", in: app)
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled)
        XCTAssertEqual(try number(straighten), 3.4, accuracy: 0.0001)

        try setValue("51", title: "Horizontal Perspective", control: "geometry.perspectiveHorizontal", in: app)
        applyDraft(in: app)
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5))
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(app.buttons["geometry.perspectiveHorizontal.value"]), 51, accuracy: 0.0001,
                       "Perspective must retain the legal integer value across draft application")

        try setValue("4.5", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        app.buttons["editor.group.light"].tap()
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        let continueEditing = app.alerts.buttons["Keep Editing"]
        XCTAssertTrue(continueEditing.waitForExistence(timeout: 5), app.debugDescription)
        continueEditing.tap()
        XCTAssertEqual(try number(straighten), 4.5, accuracy: 0.0001, "Continuing editing keeps the active draft")
        app.buttons["editor.group.light"].tap()
        discard.tap()
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5))
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(straighten), 3.4, accuracy: 0.0001, "Discarding the draft restores the committed geometry")
        XCTAssertEqual(try number(app.buttons["geometry.perspectiveHorizontal.value"]), 51, accuracy: 0.0001)
        capture("v4-geometry-committed", in: app)
    }

    func testCropWidthWheelUnlocksAspectForCornerDragAndRotationPreservesDraft() throws {
        let app = try launchImportedEditor()
        try selectTool("geometry", in: app)
        if app.buttons["geometry.reset"].isEnabled {
            resetIfEnabled("geometry.reset", in: app)
            applyDraft(in: app)
            try selectTool("geometry", in: app)
        }
        let aspect = app.buttons["geometry.aspectRatio"]
        try revealInPanel(aspect, in: app)
        aspect.tap()
        let square = app.buttons["1:1"]
        XCTAssertTrue(square.waitForExistence(timeout: 5), app.debugDescription)
        square.tap()
        XCTAssertTrue(aspect.label.contains("1:1"), aspect.debugDescription)
        let width = app.buttons["geometry.cropWidth.value"]
        let height = app.buttons["geometry.cropHeight.value"]
        let squareWidth = try number(width)
        let squareHeight = try number(height)
        let squareRatio = squareWidth / squareHeight
        let narrowedWidth = max(1, (squareWidth * 0.75 * 10).rounded() / 10)
        try setValue(String(format: "%.1f", narrowedWidth), title: "Crop Width", unit: "%", control: "geometry.cropWidth", in: app)
        XCTAssertEqual(try number(width), narrowedWidth, accuracy: 0.1)
        XCTAssertEqual(try number(height), squareHeight, accuracy: 0.1)
        XCTAssertFalse(aspect.label.contains("1:1"), "A numeric crop edit must release the selected aspect ratio")

        let corner = app.descendants(matching: .any)["geometry.crop.bottomRight"]
        XCTAssertTrue(corner.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(corner.isHittable, corner.debugDescription)
        let start = corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -40, dy: 0)))
        waitUntil {
            guard let current = try? self.number(width) else { return false }
            return current < narrowedWidth
        }
        let draggedWidth = try number(width)
        let draggedHeight = try number(height)
        XCTAssertLessThan(draggedWidth, narrowedWidth)
        XCTAssertEqual(draggedHeight, squareHeight, accuracy: 0.1, "A free horizontal corner drag must not resize crop height")
        XCTAssertGreaterThan(abs(draggedWidth / draggedHeight - squareRatio), squareRatio * 0.05,
                             "The corner must not snap the crop back to the previous 1:1 ratio")
        let cropIDs = ["cropX", "cropY", "cropWidth", "cropHeight"]
        let portraitValues = try cropIDs.map { try number(app.buttons["geometry.\($0).value"]) }
        capture("v4-free-crop-draft-portrait", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        waitForLandscapeSidePanel(in: app)
        XCTAssertTrue(app.buttons["editor.draft.cancel"].waitForExistence(timeout: 5))
        for (index, id) in cropIDs.enumerated() {
            XCTAssertEqual(try number(app.buttons["geometry.\(id).value"]), portraitValues[index], accuracy: 0.1,
                           "Rotation must preserve the active crop draft")
        }
        XCTAssertFalse(aspect.label.contains("1:1"))
        XCTAssertTrue(corner.waitForExistence(timeout: 5))
        capture("v4-free-crop-draft-landscape", in: app)
        XCUIDevice.shared.orientation = .portrait
        waitUntil { app.frame.height > app.frame.width }
        for (index, id) in cropIDs.enumerated() {
            XCTAssertEqual(try number(app.buttons["geometry.\(id).value"]), portraitValues[index], accuracy: 0.1)
        }
        app.buttons["editor.draft.cancel"].tap()
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5))
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(width), 100, accuracy: 0.1)
        XCTAssertEqual(try number(height), 100, accuracy: 0.1)
    }

    func testMasterRecipeNamesAndTilesRemainReachable() throws {
        let app = try launchImportedEditor()
        try selectTool("masterRecipe", in: app)
        let choices = app.scrollViews["masterRecipe.choices"]
        XCTAssertTrue(choices.waitForExistence(timeout: 5))
        let recipes = [
            ("neutral", "No Recipe"),
            ("hamada_daylight_v2", "Hideaki Hamada"),
            ("takashi_yasui_zen", "Takashi Yasui"),
            ("takahiro_sakai_blue", "Takahiro Sakai"),
            ("withluke_epic", "withluke"),
            ("daniel_casson_autumn", "Daniel Casson"),
            ("billy_dinh_cinema", "Billy Dinh"),
            ("rkrkrk_cyberpunk", "rkrkrk"),
            ("samalive_vintage", "Samalive"),
            ("iwona_fairy_tale", "Iwona"),
            ("cinestill_800t", "CineStill 800T"),
            ("wilson_lee_golden", "Wilson Lee"),
            ("luizclas_portrait", "Luiz Clas"),
            ("ivan_ivanchenko_twilight", "Ivan Ivanchenko"),
            ("jungraphy_neon", "Jungraphy")
        ]
        for (id, name) in recipes {
            let tile = app.buttons["recipe." + id]
            try revealHorizontally(tile, in: choices, app: app)
            XCTAssertEqual(tile.label, name)
            XCTAssertTrue(tile.isHittable, tile.debugDescription)
            XCTAssertGreaterThanOrEqual(tile.frame.height, 88, "Each tile needs room for its icon and full recipe name")
            if id == "hamada_daylight_v2" || id == "jungraphy_neon" {
                capture("v4-recipe-tile-" + id, screenshot: tile.screenshot())
            }
        }
        let selected = app.buttons["recipe.hamada_daylight_v2"]
        try revealHorizontally(selected, in: choices, app: app)
        tapVisible(selected, in: app)
        XCTAssertTrue(selected.isSelected)
        XCTAssertEqual(app.buttons["tool.masterRecipe"].value as? String, "Hideaki Hamada")
        XCTAssertTrue(app.buttons["masterRecipe.strength.value"].waitForExistence(timeout: 5))
        capture("v4-master-recipe-selected", in: app)
    }

    func testVignetteHighlightAvailabilityAndHSLChannelValues() throws {
        let app = try launchImportedEditor()
        try selectTool("vignette", in: app)
        XCTAssertFalse(app.buttons["effects.vignette.reset"].exists,
                       "Collapsed vignette keeps the group reset out of the compact surface")
        XCTAssertFalse(app.buttons["effects.vignette.vignetteAmount.reset"].exists,
                       "Collapsed vignette keeps the intensity reset out of the compact surface")
        let advanced = app.buttons["effects.vignette.advanced"].firstMatch
        try revealInPanel(advanced, in: app)
        advanced.tap()
        XCTAssertTrue(app.buttons["effects.vignette.reset"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["effects.vignette.vignetteAmount.reset"].exists)
        resetIfEnabled("effects.vignette.reset", in: app)
        capture("v4-vignette-after-expand", in: app)
        let highlights = app.buttons["effects.vignette.vignetteHighlights.value"]
        XCTAssertTrue(highlights.waitForExistence(timeout: 5))
        XCTAssertFalse(highlights.isEnabled)
        XCTAssertTrue(app.staticTexts["effects.vignette.highlightsUnavailable"].exists)
        try setValue("-20", title: "Intensity", control: "effects.vignette.vignetteAmount", in: app)
        XCTAssertTrue(highlights.isEnabled)
        XCTAssertFalse(app.staticTexts["effects.vignette.highlightsUnavailable"].exists)
        try setValue("25", title: "Highlight Protection", control: "effects.vignette.vignetteHighlights", in: app)
        XCTAssertEqual(try number(highlights), 25, accuracy: 0.0001)
        try setValue("+20", title: "Intensity", control: "effects.vignette.vignetteAmount", in: app)
        XCTAssertFalse(highlights.isEnabled)
        XCTAssertEqual(try number(highlights), 25, accuracy: 0.0001, "Unavailable controls must retain their stored value")

        try selectTool("hsl", in: app)
        let red = app.buttons["hsl.channel.0"]
        red.tap()
        try setValue("+12", title: "Hue", control: "hsl.hue", in: app)
        app.buttons["hsl.channel.1"].tap()
        let otherChannelValue = try number(app.buttons["hsl.hue.value"])
        XCTAssertNotEqual(otherChannelValue, 12)
        red.tap()
        XCTAssertEqual(try number(app.buttons["hsl.hue.value"]), 12, accuracy: 0.0001)
        try revealInPanel(app.staticTexts["hsl.hue.title"], in: app, fully: true)
        app.staticTexts["hsl.hue.title"].doubleTap()
        XCTAssertEqual(try number(app.buttons["hsl.hue.value"]), 0, accuracy: 0.0001)
        capture("v4-hsl-native-controls", in: app)
    }

}
