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
      "reset-menu",
      "compare",
      "compare-wipe",
      "compare-hold",
      "zoom",
      "edge-to-edge",
      "immersive",
      "photo-info",
      "histogram",
      "processing",
      "saving-error",
      "raster",
      "preview-error",
      "wb-unavailable",
      "more",
    ],
    statePlatforms: { immersive: ["ios", "android"] },
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
    states: [
      "update",
      "updating-wait",
      "update-error",
      "update-ready",
      "update-settings",
    ],
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
  "compare-hold": "按住看调整前",
  "edge-to-edge": "照片顶满",
  immersive: "纯预览",
  "reset-menu": "重置菜单",
  "update-settings": "软件更新设置",
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
  "对比：并排",
  "点按对比图标开关对比，并记住上次使用的方式；桌面旁边的下拉箭头、移动端长按图标或画面底部的切换选择并排/分割线。画布高而窄时并排改为上下排列。",
  [
    "两侧共用同一查看状态，标签贴在各自照片上",
    "切换方式不修改照片参数，也不改变照片区或调整区高度",
  ],
];
RawLabDesign.descriptions["compare-wipe"] = [
  "对比：拖动分割线",
  "分割线只在照片范围内。拖动或用方向键调整位置；再点对比图标关闭，下次打开仍回到分割线。",
  ["左侧调整前、右侧调整后", "不改变照片参数或视图高度"],
];
RawLabDesign.descriptions["compare-hold"] = [
  "按住看调整前",
  "不打开对比时，按住照片（桌面按住反斜杠键）临时显示调整前，松开恢复。这是最快的前后对比方式。",
  ["短按不触发，避免与点按、缩放冲突", "顶部标签说明当前显示的是调整前"],
];
RawLabDesign.descriptions["photo-info"] = [
  "照片信息",
  "照片信息放回左上角：平时只显示信息图标，点击依次显示文件信息、拍摄参数，再点收起（桌面也可按 I）。白平衡等细节放进信息层，不常驻在画面上。",
  [
    "信息文字不拦截照片上的缩放与拖动",
    "工具栏和“更多”中的照片信息入口打开同一信息层",
  ],
];
RawLabDesign.descriptions["edge-to-edge"] = [
  "照片顶满",
  "在“缩放与显示”（Windows 为“查看”菜单）关闭“照片四周留白”后，照片贴边显示，尽量占满预览区。",
  ["默认保留四周留白", "只改变查看方式，不改变照片参数"],
];
RawLabDesign.descriptions.immersive = [
  "纯预览",
  "移动端单击照片区隐藏所有其他界面，只显示照片；再单击恢复。按住照片仍是查看调整前。",
  [
    "几何草稿编辑时不进入纯预览，避免与裁切操作冲突",
    "单击与按住按时长和位移区分",
  ],
];
RawLabDesign.descriptions["reset-menu"] = [
  "重置菜单",
  "重置统一收进调整区右上角的菜单，按作用范围从小到大排列；影响整组或全部的项需要确认。",
  [
    "HSL：当前颜色 → 全部 HSL → 颜色组 → 全部调整",
    "重置是次要操作，使用中性灰，不使用表示选中的黄色",
    "双击参数名称或滑杆可直接恢复单个值",
  ],
];
RawLabDesign.descriptions.processing = [
  "处理进度",
  "照片区域顶部叠加 2px 细线，正常状态保留相同布局。",
  [
    "显示与隐藏进度不改变画布、面板或工具高度",
    "进度通过无障碍标签表达，不弹出处理提示框",
  ],
];
RawLabDesign.descriptions["update-settings"] = [
  "软件更新设置",
  "长期设置集中在“设置 → 软件更新”：自动检查默认开启，自动下载并安装默认关闭；可从这里立即检查。",
  ["更新提示只询问本次是否安装", "Android 保持现有检查与手动下载方式"],
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
