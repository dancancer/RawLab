import SwiftUI

struct PhotoLocationButton: View {
    let url: URL
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(L10n.text("照片信息"))
            .accessibilityLabel(L10n.text("照片信息") + " · " + url.lastPathComponent)
            .accessibilityIdentifier("photo.location.\(url.path)")
            .popover(isPresented: $presented) {
                Text(url.path).textSelection(.enabled)
                    .frame(width: 360, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(16)
            }
    }
}
