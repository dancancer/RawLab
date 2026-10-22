import AppKit

extension MacGeometryDraftTests {
    static func workspaceResetChecks(_ model: EditorModel, raw: URL, edits: URL) throws {
        let baseline = model.settings
        model.selectAdjustmentTool(.lens)
        try wait(model, draft: true, "unchanged lens navigation draft")
        model.selectAdjustmentGeometryTab(.perspective)
        try wait(model, draft: true, "unchanged lens to perspective")
        try check(model.geometryDraftTab == .perspective && model.adjustmentNavigation.tool == .geometry,
                  "unchanged lens-to-perspective navigation retains the exact destination tab")
        model.cancelGeometryDraft()
        try wait(model, "unchanged perspective navigation cleanup")
        for choice in [MacGeometryDeparture.stay, .discard, .apply] {
            model.selectAdjustmentTool(.lens)
            try wait(model, draft: true, "dirty lens navigation entry")
            model.updateLensDraft { $0.autoCrop = false }
            try wait(model, draft: true, "dirty lens navigation preview")
            model.selectAdjustmentGeometryTab(.perspective)
            try check(model.geometryDraftDeparturePending && model.geometryDraftTab == .lens,
                      "dirty lens-to-perspective navigation uses the existing departure guard")
            model.resolveGeometryDraftDeparture(choice)
            if choice == .stay {
                try check(model.geometryDraftTab == .lens && model.adjustmentNavigation.tool == .lens && model.geometryDraftHasChanges,
                          "Stay preserves the original lens tool, tab and dirty draft")
            } else {
                try wait(model, draft: true, "resolved lens to perspective")
                try check(model.geometryDraftTab == .perspective && model.adjustmentNavigation.tool == .geometry && !model.geometryDraftHasChanges,
                          "Apply and Discard continue exactly once to the requested perspective tab")
            }
            model.cancelGeometryDraft()
            try wait(model, "lens destination check cleanup")
            model.settings = baseline
            try check(model.saveEdits(), "lens navigation checks restore their committed baseline")
            try wait(model, "lens navigation baseline restored")
        }
        for identity in [ProcessingIdentity.legacy, .current] {
            model.settings.processing = identity
            model.settings.exposure = 0.75
            try wait(model, "workspace reset baseline")
            try check(model.saveEdits(), "workspace baseline saves")
            let request = model.scheduler.latest?.id, revision = model.editRevision
            model.selectAdjustmentGroup(.color)
            model.adjustmentNavigation.selectedHSLChannel = 5
            model.selectAdjustmentTool(.hsl)
            model.selectAdjustmentGroup(.light)
            model.selectAdjustmentGroup(.color)
            model.selectAdjustmentTool(.hsl)
            try check(model.adjustmentNavigation.selectedHSLChannel == 5 && model.editRevision == revision &&
                      model.scheduler.latest?.id == request && !model.dirty, "group and HSL navigation create zero edits or preview requests")
            model.selectAdjustmentGroup(.geometry)
            try wait(model, draft: true, "workspace geometry draft")
            try check(!model.geometryDraftCanApply && !model.geometryDraftHasChanges, "fresh unchanged draft cannot Apply")
            model.updateGeometryDraft { $0.cropWidth = 0.62 }
            var lens = model.lensDraftSettings; lens.mode = .manual; lens.profileID = "disabled-profile"
            model.updateLensDraft { $0 = lens }
            try wait(model, draft: true, "workspace draft changes")
            let committed = model.settings
            guard case .prepared(let geometryReset) = model.prepareReset(scope: .tool(.geometry)) else { throw Failure(description: "geometry tool reset must prepare") }
            try check(model.commitReset(geometryReset) && model.geometryDraftSettings.isIdentity && model.lensDraftSettings == lens && model.settings == committed,
                      "geometry tool reset preserves complete lens metadata and committed settings")
            try check(model.prepareReset(scope: .tool(.lens)) == .blocked(.geometryDraftRequired), "tool reset requires the matching active draft kind")
            model.updateGeometryDraft { $0.cropWidth = 0.62 }
            try wait(model, draft: true, "workspace dirty draft restored")
            model.requestAdjustmentReset(.all)
            try check(model.geometryDraftDeparturePending && model.resetConfirmation == nil, "All first asks how to resolve the dirty draft")
            model.resolveGeometryDraftDeparture(.stay)
            try check(model.geometryDraft != nil && model.resetReturnTool == nil && model.resetConfirmation == nil, "Stay cancels All and keeps the exact old draft")
            model.requestAdjustmentReset(.all)
            model.resolveGeometryDraftDeparture(.discard)
            try check(model.geometryDraft == nil && model.resetConfirmation != nil && model.settings == committed, "Discard prepares All from committed state for a separate confirmation")
            model.finishAdjustmentReset(confirm: false)
            try wait(model, draft: true, "workspace canceled All fresh draft")
            try check(!model.geometryDraftHasChanges && model.geometryDraft!.originalGeometry == committed.geometrySettings &&
                      model.settings.processing == identity && model.adjustmentNavigation.tool == .geometry,
                      "canceling All keeps Discard and recreates an unchanged draft from committed settings")
            model.updateGeometryDraft { $0.cropWidth = 0.7 }
            model.requestAdjustmentReset(.all)
            model.resolveGeometryDraftDeparture(.apply)
            let applied = model.settings
            try check(applied.geometrySettings.cropWidth == 0.7 && model.resetConfirmation != nil && model.geometryDraft == nil &&
                      saved(raw, directory: edits) == applied, "Apply persists before All candidate confirmation")
            model.finishAdjustmentReset(confirm: false)
            try wait(model, draft: true, "workspace applied then canceled All")
            try check(model.settings == applied && !model.geometryDraftHasChanges && model.settings.processing == identity,
                      "canceling All preserves the preceding successful Apply and processing identity")
            model.requestAdjustmentReset(.all)
            try check(model.resetConfirmation != nil && model.geometryDraft == nil, "unchanged draft exits directly to All confirmation")
            model.finishAdjustmentReset(confirm: true)
            try wait(model, draft: true, "workspace confirmed All")
            try check(!model.isAdjustmentModified(.all) && !model.geometryDraftHasChanges && model.settings.processing == identity &&
                      model.adjustmentNavigation.tool == .geometry, "confirmed All restores complete defaults and a fresh unchanged draft with the same processing identity")
            let neutralRequest = model.scheduler.latest?.id, neutralRevision = model.editRevision
            model.requestAdjustmentReset(.all)
            try check(model.resetConfirmation == nil && model.geometryDraft != nil && model.scheduler.latest?.id == neutralRequest &&
                      model.editRevision == neutralRevision && !model.dirty,
                      "neutral All with an unchanged draft creates no save or preview request")
            model.cancelGeometryDraft()
            try wait(model, "workspace reset cleanup")
        }
        model.settings = baseline
        try check(model.saveEdits(), "workspace checks restore original committed fixture")
        try wait(model, "workspace fixture restored")
    }

}
