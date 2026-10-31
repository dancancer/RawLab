import Foundation

@main struct WorkspaceLayoutTests {
    static func main() {
        var panel = AdjustmentPanelLayout()
        precondition(panel.height(available: 620) == 220, "Single-value automatic panel must leave room for the photo")
        precondition(panel.height(available: 800, automatic: 320) == 320)
        panel.resize(to: 340, available: 800)
        precondition(!panel.isAutomatic && panel.height(available: 800, automatic: 220) == 340)
        panel.collapsed = true
        precondition(panel.height(available: 800) == 0)
        panel.collapsed = false
        precondition(panel.height(available: 800, automatic: 320) == 340)
        panel.restoreAutomaticHeight()
        precondition(panel.isAutomatic && panel.height(available: 800) == 220)
        var workspace = MacWorkspaceLayout()
        precondition(!workspace.showsFiles(width: 950, hasFolders: false))
        precondition(workspace.showsFiles(width: 1320, hasFolders: false))
        precondition(workspace.showsFiles(width: 950, hasFolders: true))
        workspace.toggleFiles(width: 950, hasFolders: true)
        precondition(!workspace.showsFiles(width: 1320, hasFolders: true))
        workspace.toggleFiles(width: 950, hasFolders: false)
        precondition(workspace.showsFiles(width: 950, hasFolders: false))
        precondition(MacWorkspaceLayout.compactHistogram(canvas: CGSize(width: 950, height: 370)))
        precondition(MacWorkspaceLayout.compactHistogram(canvas: CGSize(width: 700, height: 500)))
        precondition(!MacWorkspaceLayout.compactHistogram(canvas: CGSize(width: 950, height: 500)))
        print("PASS automatic/manual panel, folder preference and compact histogram boundaries")
    }
}
