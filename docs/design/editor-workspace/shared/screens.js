// Stable screen IDs are the review/deep-link contract, not application routing.
window.RawLabDesignScreens = [
  {
    id: "import",
    title: "导入照片",
    area: "导入与浏览",
    platforms: ["ios", "android", "macos", "windows"],
    states: ["import", "import-error", "permission", "permission-limited"],
    statePlatforms: { "permission-limited": ["android"] },
    scope: "existing",
    source: "原生照片/文件选择入口",
  },
  {
    id: "library",
    title: "照片与文件浏览",
    area: "导入与浏览",
    platforms: ["android", "macos", "windows"],
    states: [
      "library",
      "file-actions",
      "apply-settings",
      "folder-error",
      "folder-remove",
    ],
    statePlatforms: {
      "file-actions": ["macos", "windows"],
      "apply-settings": ["macos", "windows"],
      "folder-error": ["macos", "windows"],
      "folder-remove": ["macos", "windows"],
    },
    scope: "existing",
    source: "现有相册/桌面文件树",
  },
  {
    id: "workspace",
    title: "编辑工作区",
    area: "编辑",
    platforms: ["ios", "android", "macos", "windows"],
    states: [
      "empty",
      "groups",
      "hsl",
      "light",
      "compare",
      "compare-wipe",
      "zoom",
      "photo-info",
      "histogram",
      "processing",
      "saving-error",
      "raster",
      "preview-error",
      "wb-unavailable",
      "more",
    ],
    scope: "existing_and_proposed",
    source: "原生编辑器与本轮分组提案",
  },
  ...Object.entries(RawLabDesign.tools).flatMap(([group, tools]) =>
    tools.map(([id, title]) => ({
      id: "tool-" + id,
      title,
      area: "编辑工具",
      platforms: ["ios", "android", "macos", "windows"],
      states: ["tool-" + id],
      scope: "existing",
      group,
      source: "各端现有调整面板",
    })),
  ),
  {
    id: "draft",
    title: "几何与镜头草稿",
    area: "编辑工具",
    platforms: ["ios", "android", "macos", "windows"],
    states: ["draft", "draft-confirm", "lens-profile"],
    scope: "existing",
    source: "现有草稿与镜头配置",
  },
  {
    id: "looks",
    title: "外观资源管理",
    area: "外观管理",
    platforms: ["ios", "android", "macos", "windows"],
    states: [
      "looks",
      "look-import",
      "look-error",
      "look-delete",
      "look-rename",
      "look-missing",
    ],
    statePlatforms: {
      "look-delete": ["android", "macos"],
      "look-rename": ["android", "macos"],
    },
    scope: "existing",
    source: "现有自定义 LUT/相机外观导入管理",
  },
  {
    id: "export",
    title: "单张导出",
    area: "导出",
    platforms: ["ios", "android", "macos", "windows"],
    states: [
      "export",
      "export-options",
      "export-running",
      "export-done",
      "export-error",
    ],
    scope: "existing",
    source: "各端现有单张导出",
  },
  {
    id: "batch",
    title: "批量导出",
    area: "批量任务",
    platforms: ["ios", "android", "macos", "windows"],
    states: [
      "batch-select",
      "batch-confirm",
      "batch-inspect",
      "batch-running",
      "batch-stopping",
      "batch-done",
      "batch-partial",
      "batch-cancelled",
      "batch-interrupted",
      "batch-permission",
      "batch-uncertain",
      "batch-save-files",
      "discard-confirm",
    ],
    statePlatforms: {
      "batch-uncertain": ["ios", "android"],
      "batch-save-files": ["ios"],
    },
    scope: "existing",
    source: "各端现有批量快照/任务恢复",
  },
  {
    id: "settings",
    title: "设置与关于",
    area: "设置",
    platforms: ["ios", "android", "macos", "windows"],
    states: [
      "settings",
      "language",
      "haptics",
      "privacy",
      "about",
      "licenses",
      "mobile-update",
    ],
    statePlatforms: {
      about: ["android", "macos", "windows"],
      licenses: ["android"],
      "mobile-update": ["android"],
      haptics: ["ios", "android"],
    },
    scope: "existing",
    source: "各端设置/关于/统计同意",
  },
  {
    id: "update",
    title: "桌面更新",
    area: "桌面更新",
    platforms: ["macos", "windows"],
    states: ["update", "updating-wait", "update-error", "update-ready"],
    scope: "proposed",
    source: "现有检查更新 + 本轮自动安装提案",
  },
  {
    id: "components",
    title: "组件与图标",
    area: "组件规范",
    platforms: ["ios", "android", "macos", "windows"],
    states: ["components"],
    scope: "design_system",
    source: "共用 SVG 语义图标与 Web 原型组件",
  },
];
window.RawLabDesign.flowTitles = {
  more: "更多",
  import: "导入照片",
  "import-error": "导入失败",
  permission: "照片访问权限",
  "permission-limited": "照片访问受限",
  library: "照片浏览",
  "file-actions": "照片操作",
  compare: "并排对比",
  "compare-wipe": "拖动分割线",
  zoom: "缩放与显示",
  "photo-info": "照片信息",
  histogram: "直方图",
  "preview-error": "预览失败",
  looks: "外观资源",
  "look-import": "导入外观",
  "look-error": "外观导入失败",
  "look-delete": "删除外观",
  "look-missing": "外观引用缺失",
  export: "导出",
  "export-options": "单张导出设置",
  "export-running": "正在导出",
  "export-done": "导出完成",
  "export-error": "导出失败",
  "batch-select": "选择批量照片",
  "batch-confirm": "确认批量导出",
  "batch-inspect": "目标效果检查",
  "batch-running": "批量导出中",
  "batch-stopping": "正在停止",
  "batch-done": "批量全部完成",
  "batch-partial": "批量部分失败",
  "batch-cancelled": "批量已取消",
  "batch-interrupted": "批量任务恢复",
  "batch-permission": "批量输出权限",
  "batch-uncertain": "核对不确定的保存结果",
  "batch-save-files": "保存 DNG 文件",
  "discard-confirm": "放弃未完成任务",
  "look-rename": "重命名外观",
  "apply-settings": "应用完整设置",
  "folder-error": "目录读取失败",
  "folder-remove": "移除目录",
  settings: "设置",
  language: "语言",
  privacy: "隐私与使用统计",
  about: "关于 RawLab",
  "draft-confirm": "离开草稿确认",
  "lens-profile": "镜头配置",
  "update-ready": "更新已准备好",
  components: "组件与图标",
};
// The review selector is generated from this inventory, so a screen cannot silently disappear.
RawLabDesignScreens.forEach((screen) =>
  screen.states.forEach((id) => {
    if (!RawLabDesign.descriptions[id])
      RawLabDesign.descriptions[id] = [
        RawLabDesign.flowTitles[id] || screen.title,
        screen.scope === "proposed"
          ? "本轮新增的待评审设计。"
          : "复用现有功能语义的可交互设计稿。",
        [
          screen.scope === "existing"
            ? "现有能力，界面原型不代表原生验收"
            : "设计状态与实现状态分别维护",
          "取消、返回和相关下一步可在原型中操作",
        ],
      ];
  }),
);

RawLabDesign.supportsScreen = (screen, id, platform) =>
  (screen.statePlatforms?.[id] || screen.platforms).includes(platform);

RawLabDesign.descriptions.compare = [
  "三态对比：并排",
  "点击同一对比图标按关闭→并排→拖动分割线→关闭循环。模式切换保持查看与调整状态。",
  ["四端均支持本轮双模式提案", "并排两侧使用同一查看状态，照片仅为示意"],
];
RawLabDesign.descriptions["compare-wipe"] = [
  "三态对比：拖动分割线",
  "拖动照片上的分割线比较中性显影与调整后。再次点击图标关闭对比。",
  ["可用方向键调整分割位置", "不改变照片参数或视图高度"],
];
RawLabDesign.descriptions.processing = [
  "处理进度",
  "照片区域顶部叠加 2px 细线，正常状态保留相同布局。",
  [
    "显示与隐藏进度不改变画布、面板或工具高度",
    "进度通过无障碍标签表达，不弹出处理提示框",
  ],
];

RawLabDesign.nativeSources = {
  ios: {
    导入与浏览: "../../../RawLab/RawLab/UI/Editor/ContentView+Helpers.swift",
    编辑: "../../../RawLab/RawLab/UI/Editor/ContentView+Panels.swift",
    编辑工具: "../../../RawLab/RawLab/UI/Panels/AdjustmentPanels.swift",
    外观管理: "../../../RawLab/RawLab/UI/Editor/ContentView+Helpers.swift",
    导出: "../../../RawLab/RawLab/UI/Export/ExportSizePicker.swift",
    批量任务: "../../../RawLab/RawLab/UI/Export/BatchExportView.swift",
    设置: "../../../RawLab/RawLab/UI/Editor/ContentView.swift",
  },
  android: {
    导入与浏览:
      "../../../RawLabAndroid/app/src/main/java/com/rawlab/android/album/AlbumScreen.kt",
    编辑: "../../../RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/EditorScreen.kt",
    编辑工具:
      "../../../RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/AdjustmentDock.kt",
    外观管理:
      "../../../RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/AdjustmentDock.kt",
    导出: "../../../RawLabAndroid/app/src/main/java/com/rawlab/android/MainActivity.kt",
    批量任务:
      "../../../RawLabAndroid/app/src/main/java/com/rawlab/android/batch/ui/BatchExportScreen.kt",
    设置: "../../../RawLabAndroid/app/src/main/java/com/rawlab/android/about/AboutDialog.kt",
  },
  macos: {
    导入与浏览: "../../../RawLabMac/Sources/Library/FileBrowser.swift",
    编辑: "../../../RawLabMac/Sources/Editor/View/EditorView.swift",
    编辑工具: "../../../RawLabMac/Sources/Editor/View/AdjustmentDock.swift",
    外观管理: "../../../RawLabMac/Sources/Looks/FilmDock.swift",
    导出: "../../../RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift",
    批量任务: "../../../RawLabMac/Sources/Export/BatchExportView.swift",
    设置: "../../../RawLabMac/Sources/Presentation/AboutView.swift",
    桌面更新: "../../../RawLabMac/Sources/System/UpdateChecker.swift",
  },
  windows: {
    导入与浏览: "../../../RawLabWindows/MainWindow/Library.cs",
    编辑: "../../../RawLabWindows/MainWindow.xaml",
    编辑工具: "../../../RawLabWindows/GeometryPanel.xaml",
    外观管理: "../../../RawLabWindows/MainWindow/Library.cs",
    导出: "../../../RawLabWindows/MainWindow/InteractionExport.cs",
    批量任务: "../../../RawLabWindows/BatchExportWindow.xaml",
    设置: "../../../RawLabWindows/SettingsWindow.cs",
    桌面更新: "../../../RawLabWindows/AboutWindow.xaml",
  },
};

Object.assign(RawLabDesign.flowTitles, {
  "privacy-policy": "隐私政策",
  project: "GitHub 项目",
  author: "作者主页",
  "external-release": "官方发布页",
  results: "已保存的结果",
});

RawLabDesign.descriptions["wb-unavailable"] = [
  "白平衡校准缺失",
  "保留相机模式并说明不可用原因，不显示伪造的拍摄色温。",
  ["手动色温与色调不可用", "其他可用调整仍可进入"],
];
