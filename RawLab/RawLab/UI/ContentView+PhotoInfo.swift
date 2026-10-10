import ImageIO
import SwiftUI

extension ContentView {
    func photoInfoOverlay(maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.hasImage && !editorBusy {
                Button {
                    photoInfoMode = photoInfoMode.next
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(photoInfoMode == .hidden ? .white : .yellow)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("照片信息")
                .accessibilityValue(photoInfoMode.title)
                .accessibilityIdentifier("editor.photoInfo")
                .help("切换照片信息")
            }

            if photoInfoMode != .hidden, let photoInformation, !editorBusy {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(photoInformation.lines(for: photoInfoMode).enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(index == 0 ? .subheadline.weight(.semibold) : .caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2, y: 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: maxWidth, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("editor.photoInfo.overlay")
            }
        }
        .padding(12)
        .task(id: viewModel.sourceRevision) {
            photoInformation = nil
            photoInfoMode = .hidden
            guard let url = viewModel.sourceURL else { return }
            let revision = viewModel.sourceRevision
            let displayName = viewModel.sourceDisplayName ?? url.lastPathComponent
            let info = await Task.detached(priority: .utility) {
                readPhotoInformation(url: url, displayName: displayName)
            }.value
            guard !Task.isCancelled, viewModel.sourceRevision == revision,
                  viewModel.sourceURL == url else { return }
            photoInformation = info
        }
    }
}

private func readPhotoInformation(url: URL, displayName: String) -> PhotoInformation {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    let source = CGImageSourceCreateWithURL(url as CFURL, options)
    let properties = source.flatMap {
        CGImageSourceCopyPropertiesAtIndex($0, 0, options) as? [CFString: Any]
    } ?? [:]
    return PhotoInformation(fileName: displayName, properties: properties)
}
