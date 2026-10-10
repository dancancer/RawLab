import SwiftUI
import AppKit

extension Notification.Name {
    static let rawLabAIColorMatch = Notification.Name("RawLab.AIColorMatch")
}

struct AIColorMatchView: View {
    @ObservedObject var model: AIColorMatchModel
    @ObservedObject var settings: AISettings
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var comparison = 0
    @State private var showRegions = false
    @State private var viewport = PhotoViewport()
    @State private var pan = CGSize.zero
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            referenceStrip
            Divider()
            HStack(spacing: 1) {
                photo(comparison == 2 ? (model.fixedPreview ?? model.original) :
                    (comparison == 0 ? model.original : (model.baseline ?? model.original)),
                    title: comparison == 2 ? "固定分区" : (comparison == 0 ? "原编辑" : "中性基线"))
                if let frame = model.preview {
                    photo(frame, title: model.candidate?.recipe.name ?? "AI 候选")
                        .overlay(alignment: .topTrailing) {
                            if model.isPreviewing { ProgressView().controlSize(.small).padding(14) }
                        }
                } else {
                    ZStack {
                        Color(nsColor: NSColor(white: 0.12, alpha: 1))
                        VStack(spacing: 10) {
                            if model.isBusy { ProgressView(); Text(model.phase.title).font(.callout) }
                            else { Image(systemName: "paintpalette").font(.system(size: 28)).foregroundStyle(.secondary); Text("AI 候选").foregroundStyle(.secondary) }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minHeight: 200, maxHeight: .infinity)
                .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
            controls
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 1000, maxWidth: 1200, minHeight: showRegions ? 660 : 560, idealHeight: 700, maxHeight: 900)
        .preferredColorScheme(.dark)
        .task { await model.prepare() }
        .onDisappear { model.close() }
        .interactiveDismissDisabled(model.phase == .applying)
        .sheet(isPresented: $showSettings) { AISettingsView(settings: settings) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label("AI 仿色", systemImage: "paintpalette").font(.headline)
            Picker("对照", selection: $comparison) {
                Text("原编辑").tag(0)
                Text("中性基线").tag(1)
                if model.fixedPreview != nil { Text("固定分区").tag(2) }
            }.pickerStyle(.segmented).frame(width: model.fixedPreview == nil ? 180 : 270)
            Spacer()
            Button { viewport.zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
            Button { viewport.fit(); pan = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("适合画面")
            Button { viewport.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("AI 服务设置").accessibilityLabel("AI 服务设置").disabled(model.isBusy)
        }.buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 48)
    }

    private var referenceStrip: some View {
        HStack(spacing: 12) {
            Button(action: addReferences) { Label("参考图", systemImage: "plus") }
                .disabled(model.references.count >= 6 || model.isBusy)
            Text("\(model.references.count)/6").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.references) { reference in
                        ZStack(alignment: .topTrailing) {
                            Image(decorative: reference.image, scale: 1).resizable().scaledToFit()
                                .frame(width: 88, height: 66).background(.black.opacity(0.15))
                                .help(reference.name)
                            Button { model.removeReference(reference.id) } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7))
                            }.buttonStyle(.plain).help("移除参考图").accessibilityLabel("移除 \(reference.name)")
                                .disabled(model.isBusy).padding(3)
                        }
                    }
                }
            }.scrollIndicators(.visible)
        }.padding(.horizontal, 18).frame(height: 86)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let candidate = model.candidate {
                HStack(spacing: 14) {
                    Text(candidate.recipe.name).font(.subheadline).lineLimit(1)
                    Text("\(candidate.report.gridSize)-grid · sRGB").font(.caption).foregroundStyle(.secondary)
                        .help(String(format: "最大采样通道误差 %.5f，门槛 0.02；不是风格匹配分数。", candidate.report.maxError))
                    Spacer()
                    Text("强度").font(.caption)
                    Slider(value: Binding(get: { model.strength }, set: model.updateStrength), in: 0...2, step: 0.01)
                        .frame(width: 170).disabled(model.isBusy).accessibilityLabel("AI 外观强度")
                    Text("\(Int((model.strength*100).rounded()))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                Text(candidate.recipe.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(candidate.recipe.summary)
                DisclosureGroup(isExpanded: $showRegions) {
                    Grid(horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow {
                            regionSlider("暗部起点", key: \.shadowStart, range: 0...min(model.regions.shadowEnd-0.05, model.regions.highlightStart))
                            regionSlider("亮部起点", key: \.highlightStart, range: model.regions.shadowStart...(model.regions.highlightEnd-0.05))
                        }
                        GridRow {
                            regionSlider("暗部终点", key: \.shadowEnd, range: (model.regions.shadowStart+0.05)...model.regions.highlightEnd)
                            regionSlider("亮部终点", key: \.highlightEnd, range: max(model.regions.highlightStart+0.05, model.regions.shadowEnd)...1)
                        }
                    }.padding(.top, 6)
                } label: {
                    HStack {
                        Text("明暗分区").font(.caption)
                        Text(model.regions == .standard ? "固定" : "手动").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.updateRegions(.standard) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.borderless).help("重置为固定分区").accessibilityLabel("重置为固定分区")
                            .disabled(model.isBusy || model.regions == .standard)
                    }
                }
            }
            HStack(spacing: 12) {
                TextField("风格要求（可选）", text: $model.instruction, axis: .vertical)
                    .lineLimit(1...2).textFieldStyle(.roundedBorder).disabled(model.isBusy)
                if (model.isBusy || model.isPreviewing) && model.phase != .applying {
                    Button("停止", action: model.cancelGeneration)
                } else if model.source == nil {
                    Button("重试预览") { Task { await model.prepare() } }.disabled(model.isBusy)
                } else {
                    Button(model.candidate == nil ? "生成外观" : "继续调整", action: generate)
                        .disabled(!model.canGenerate || model.instruction.count > 2000)
                }
            }
            if let message = localError ?? model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                    ScrollView { Text(message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 52)
                    Button { localError = nil; model.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
                }
            } else if model.isBusy && model.candidate != nil {
                HStack { ProgressView().controlSize(.small); Text(model.phase.title).font(.caption).foregroundStyle(.secondary) }
            }
            Text("将发送当前照片预览和 \(model.references.count) 张参考图至 \(serviceHost)，不发送 RAW 或拍摄信息。")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
          if model.candidate != nil {
              Text("应用将替换胶片并重置明暗/色彩调整；曝光、白平衡与细节设置保留。")
                  .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          HStack(spacing: 12) {
            if let candidate = model.candidate {
                Button { AICubeActions.export(source: candidate.url, name: candidate.recipe.name,
                    protecting: model.protectedSources, owner: candidate.directory, onError: { localError = $0 }) } label: {
                    Label("导出 CUBE…", systemImage: "square.and.arrow.down")
                }.disabled(!model.canExport)
                AIShareButton(source: candidate.url, name: candidate.recipe.name, owner: candidate.directory,
                              enabled: model.canExport, onError: { localError = $0 }).frame(width: 32, height: 26)
                Text("原始外观 · 100%").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("取消") { model.close(); dismiss() }.keyboardShortcut(.cancelAction).disabled(model.phase == .applying)
            Button("应用外观") { Task { if await model.apply() { dismiss() } } }
                .keyboardShortcut(.defaultAction).disabled(!model.canApply)
                .help("替换当前胶片并重置输出明暗/色彩调整，保留曝光、白平衡及细节设置。")
          }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var serviceHost: String { (try? settings.configuration.normalizedURL().host) ?? "已配置的 AI 服务" }
    private func regionSlider(_ title: String, key: WritableKeyPath<AIToneRegions, Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 56, alignment: .leading)
            Slider(value: Binding(get: { model.regions[keyPath: key] }, set: { value in
                var regions = model.regions; regions[keyPath: key] = value
                model.updateRegions(regions)
            }), in: range).accessibilityLabel(title).disabled(model.isBusy)
            Text(model.regions[keyPath: key], format: .number.precision(.fractionLength(2)))
                .font(.caption).monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }
    private func addReferences() {
        let panel = NSOpenPanel(); panel.title = "选择风格参考图"
        panel.allowedContentTypes = AIImage.contentTypes
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { Task { await model.addReferences(panel.urls) } }
    }
    private func generate() {
        do {
            let config = try settings.configuration.validated()
            guard let key = try settings.keychain.read(config) else { showSettings = true; return }
            localError = nil
            model.generate(configuration: config, key: key)
        } catch { localError = error.localizedDescription }
    }
    private func photo(_ frame: RenderedImage, title: String) -> some View {
        PhotoCanvas(frame: frame, viewport: viewport, sourceWidth: frame.image.width, pan: $pan, clipping: false)
            .overlay(alignment: .bottomLeading) {
                Text(title).font(.caption).lineLimit(1).padding(7)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(10)
            }.accessibilityLabel(title)
            .simultaneousGesture(TapGesture(count: 2).onEnded { viewport.toggleActualPixels(); pan = .zero })
    }
}
