import SwiftUI
import UIKit

struct GeometryDraftProjection {
    let source: CGSize
    let settings: GeometrySettings
    let safeSize: CGSize
    private let affine: CGAffineTransform
    private let perspective: CGPoint

    init?(source: CGSize, settings: GeometrySettings) {
        let uncropped = CropInteraction.applying(rect: CGRect(x: 0, y: 0, width: 1, height: 1), to: settings)
        guard let safeSize = try? hdrNativeGeometrySize(source, geometry: uncropped) else { return nil }
        self.source = source
        self.settings = settings
        self.safeSize = safeSize

        let turn: CGAffineTransform
        switch settings.quarterTurns {
        case 1: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 2: turn = CGAffineTransform(scaleX: -1, y: -1)
        case 3: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: turn = .identity
        }
        let oriented = turn.concatenating(CGAffineTransform(
            scaleX: settings.flipHorizontal ? -1 : 1, y: settings.flipVertical ? -1 : 1))
        let rotated = settings.quarterTurns.isMultiple(of: 2)
            ? source : CGSize(width: source.height, height: source.width)
        let angle = CGFloat(Float(settings.straightenDegrees)) * .pi / 180
        affine = oriented.concatenating(CGAffineTransform(rotationAngle: angle))
        // Core 在翻转后的坐标轴做透视，再拉直。合成器使用这条逆采样映射的正向投影。
        let h = -0.5 * CGFloat(Float(settings.perspectiveHorizontal)) / rotated.width
        let v = -0.5 * CGFloat(Float(settings.perspectiveVertical)) / rotated.height
        perspective = CGPoint(x: h * oriented.a + v * oriented.b, y: h * oriented.c + v * oriented.d)
    }

    func project(_ point: CGPoint) -> CGPoint {
        let denominator = 1 + perspective.x * point.x + perspective.y * point.y
        let rotated = point.applying(affine)
        return CGPoint(x: rotated.x / denominator, y: rotated.y / denominator)
    }

    struct Layout {
        let imageSize: CGSize
        let center: CGPoint
        let transform: ProjectionTransform
        let safeBounds: CGRect
        let outline: Path
        let cropBounds: CGRect
    }

    func layout(in viewport: CGSize, margin: CGFloat, editing: Bool) -> Layout {
        let halfWidth = source.width / 2, halfHeight = source.height / 2
        let corners = [CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: -halfHeight),
                       CGPoint(x: halfWidth, y: halfHeight), CGPoint(x: -halfWidth, y: halfHeight)]
        let outline = Path { path in
            path.addLines(corners.map(project))
            path.closeSubpath()
        }
        let safe = CGRect(x: -safeSize.width / 2, y: -safeSize.height / 2, width: safeSize.width, height: safeSize.height)
        let crop = CropInteraction.rect(from: settings)
        let selection = CGRect(x: safe.minX + crop.minX * safe.width, y: safe.minY + crop.minY * safe.height,
                               width: crop.width * safe.width, height: crop.height * safe.height)
        let fitted = editing ? outline.boundingRect : selection
        let available = CGSize(width: max(1, viewport.width - 2 * margin), height: max(1, viewport.height - 2 * margin))
        let scale = min(available.width / fitted.width, available.height / fitted.height)
        let center = CGPoint(x: viewport.width / 2 - fitted.midX * scale, y: viewport.height / 2 - fitted.midY * scale)
        let placement = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: center.x, ty: center.y)

        // 底图的图层尺寸固定。拖动时只更新图层变换，让 HDR 纹理也能继续使用。
        let baseScale = min(available.width / source.width, available.height / source.height)
        let imageSize = CGSize(width: source.width * baseScale, height: source.height * baseScale)
        let zoom = scale / baseScale
        var transform = CATransform3DIdentity
        transform.m11 = affine.a * zoom; transform.m12 = affine.b * zoom
        transform.m21 = affine.c * zoom; transform.m22 = affine.d * zoom
        transform.m14 = perspective.x / baseScale; transform.m24 = perspective.y / baseScale
        let anchor = CATransform3DMakeTranslation(imageSize.width / 2, imageSize.height / 2, 0)
        let centered = CATransform3DConcat(CATransform3DConcat(CATransform3DInvert(anchor), transform), anchor)
        return Layout(imageSize: imageSize, center: center, transform: ProjectionTransform(centered),
                      safeBounds: safe.applying(placement), outline: outline.applying(placement),
                      cropBounds: selection.applying(placement))
    }
}

struct GeometryDraftImage: View {
    let image: UIImage
    let hdr: HDRPresentation?
    let hdrDisplay: HDRDisplayState
    let layout: GeometryDraftProjection.Layout

    var body: some View {
        Group {
            if let hdr { HDRCanvas(presentation: hdr, state: hdrDisplay) }
            else { Image(uiImage: image).resizable().interpolation(.high) }
        }
        .frame(width: layout.imageSize.width, height: layout.imageSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("调整后"))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("editor.photo")
        .projectionEffect(layout.transform)
        .position(layout.center)
        .allowsHitTesting(false)
    }
}
