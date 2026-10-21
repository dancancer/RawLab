// Design metadata is maintained here; the viewer reads this file without a build step.
window.RawLabDesignManifest = {
  schemaVersion: 1,
  id: "rawlab-editor-workspace",
  title: "RawLab 四端应用设计",
  designVersion: "r4",
  status: "in_review",
  updatedAt: "2026-10-21",
  approval: null,
  implementation: "not_started",
  scopes: [
    "四端现有完整功能界面",
    "调整分组与 HSL 基础交互",
    "前后对比与按住查看调整前",
    "重置菜单、滑杆填充与裁切框直接操作",
    "第二阶段入口占位（规划中）",
    "单行参数、开关组件与固定高度调整区",
    "照片信息层、照片顶满与移动端纯预览",
    "桌面自动下载与安装更新",
  ],
  platforms: {
    ios: {
      entry: "ios/index.html",
      layout: "手机底部面板；横向宽窗旁置；原生值轮",
    },
    android: {
      entry: "android/index.html",
      layout: "手机底部面板；平板旁置；Material 数值输入",
    },
    macos: {
      entry: "macos/index.html",
      layout: "文件树、照片、底部调整；AppKit 数值输入",
    },
    windows: {
      entry: "windows/index.html",
      layout: "WPF 窗口、文件树、照片、底部调整；键盘数值输入",
    },
  },
  sources: [
    "../../../PRODUCT.md",
    "../../../DESIGN.md",
    "../../architecture/roadmap.md",
    "../2026-10-09-edit-memory-batch-export/README.md",
  ],
  capturePolicy: "generated_local_only",
  media: {
    photo: {
      source:
        "../2026-10-09-edit-memory-batch-export/images/ios-white-balance.png",
      sourceKind: "existing_design_illustration",
      sourceSize: [841, 1870],
      viewBox: [0, 220, 841, 650],
      note: "只裁切既有设计稿的照片区域，未生成新照片；不代表滑杆渲染结果",
    },
    filmArtwork: "../../../RawLabMac/Resources/FilmIcons/",
    recipeArtwork: "../../../RawLabMac/Resources/MasterRecipeIcons/",
    recipeCatalog: "../../../Shared/master-recipes.json",
  },
};
