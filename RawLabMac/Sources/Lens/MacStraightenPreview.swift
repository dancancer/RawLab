import SwiftUI

// 编辑时保留未拉直的底图；裁切坐标仍以 Core 的内接安全画布为准。
struct MacStraightenPreview {
    let source: CGSize
    let degrees: Double

    var angle: Double { Double(Float(degrees)) }
    private var radians: Double { angle * .pi / 180 }

    var safeCanvas: CGSize {
        let c = cos(radians), s = abs(sin(radians))
        let w = max(1, source.width), h = max(1, source.height)
        let scale = min(w / (w * c + h * s), h / (w * s + h * c))
        return CGSize(width: max(1, floor(w * scale)), height: max(1, floor(h * scale)))
    }

    func safeRenderedSize(_ rendered: CGSize) -> CGSize {
        CGSize(width: rendered.width * safeCanvas.width / max(1, source.width),
               height: rendered.height * safeCanvas.height / max(1, source.height))
    }

    func rotatedSize(_ rendered: CGSize) -> CGSize {
        let c = abs(cos(radians)), s = abs(sin(radians))
        return CGSize(width: rendered.width * c + rendered.height * s,
                      height: rendered.width * s + rendered.height * c)
    }

    func outline(in bounds: CGRect) -> Path {
        let c = cos(radians), s = sin(radians)
        let points = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                      CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
            .map { point -> CGPoint in
                let x = point.x - bounds.midX, y = point.y - bounds.midY
                return CGPoint(x: bounds.midX + c * x - s * y, y: bounds.midY + s * x + c * y)
            }
        return Path { path in
            path.addLines(points)
            path.closeSubpath()
        }
    }
}
