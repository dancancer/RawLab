import SwiftUI

struct HDRMonitoringControls: View {
    @ObservedObject var state: HDRDisplayState
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Picker(L10n.text("预览方式"),selection:$state.mode) {
                Text(L10n.text("自动 HDR")).tag(HDRPreviewMode.automatic)
                Text(L10n.text("SDR 兼容预览")).tag(HDRPreviewMode.sdr)
            }.pickerStyle(.segmented).accessibilityIdentifier("hdr.previewMode")
            Toggle(L10n.text("HDR 假色"),isOn:$state.falseColor).accessibilityIdentifier("hdr.falseColor")
            Text(state.displayFailed ? L10n.text("HDR 显示不可用，当前显示 SDR。") :
                L10n.format("屏幕容量 %@ EV",String(format:"%.2f",log2(max(1,state.headroom)))))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hdr.displayStatus")
            if state.displayFailed {
                Button(L10n.text("重试")) { state.retry &+= 1 }.accessibilityIdentifier("hdr.retry")
            }
            if !state.displayFailed && (state.mode == .sdr || state.headroom <= 1) {
                Text(L10n.text("当前显示 SDR 兼容预览。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.falseColor {
                Text(L10n.text("假色：蓝色为暗部，琥珀色高于参考白，粉色超出屏幕容量。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Text(L10n.text("预览方式不会改变编辑或导出。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
}

struct HDRLuminanceHistogram: View {
    let statistics: HDRStatistics
    let headroom: Double
    var body: some View {
        Canvas { context,size in
            let maximum=statistics.bins.max() ?? 1
            let width=size.width/256
            for (index,value) in statistics.bins.enumerated() {
                let height=maximum>0 ? size.height*log1p(value)/log1p(maximum) : 0
                context.fill(Path(CGRect(x:Double(index)*width,y:size.height-height,width:width+0.5,height:height)),
                    with:.color(.white.opacity(0.8)))
            }
            for (position,color,dash) in [(0.5,Color.white,[CGFloat]()),
                (HDRStatistics.position(headroom:headroom),Color.yellow,[CGFloat(3),2])] {
                var line=Path(); line.move(to:CGPoint(x:position*size.width,y:0))
                line.addLine(to:CGPoint(x:position*size.width,y:size.height))
                context.stroke(line,with:.color(.black.opacity(0.9)),style:StrokeStyle(lineWidth:3,dash:dash))
                context.stroke(line,with:.color(color),style:StrokeStyle(lineWidth:1,dash:dash))
            }
        }.accessibilityLabel(L10n.text("HDR 亮度直方图"))
    }
}
