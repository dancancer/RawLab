// One semantic icon catalog for the design asset. Native names stay documented alongside it.
window.RawLabDesignIcons = {
  back: { path: "M14 5 7 12l7 7", label: "返回" },
  next: { path: "m9 5 7 7-7 7", label: "进入" },
  sun: {
    path: "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5",
    label: "光线",
  },
  color: {
    path: "M12 3a9 9 0 0 0 0 18h1a2 2 0 0 0 0-4h-1a2 2 0 0 1 0-4h3a6 6 0 0 0 0-12M7 9h.1M10 6h.1M15 6h.1M18 9h.1",
    label: "颜色",
  },
  film: {
    path: "M4 4h16v16H4zM8 4v16M16 4v16M4 8h4m-4 8h4m8-8h4m-4 8h4",
    label: "胶片",
  },
  vignette: {
    path: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10",
    label: "效果",
  },
  detail: { path: "m4 19 8-15 8 15H4m5-4h6", label: "细节" },
  crop: { path: "M6 2v16h16M2 6h16v16M9 6h9v9", label: "几何" },
  folder: { path: "M3 6h6l2 2h10v12H3V6", label: "文件夹" },
  photo: { path: "M3 4h18v16H3V4m1 12 5-5 4 4 3-3 4 4M16 8h.1", label: "照片" },
  compare: { path: "M3 5h18v14H3zM12 5v14M4 6h7v12H4z", label: "前后对比" },
  "rotate-left": {
    path: "M4 11H14V21H4ZM19 14A8 8 0 0 0 11 6M14 3 11 6l3 3",
    label: "向左旋转",
  },
  "rotate-right": {
    path: "M10 11H20V21H10ZM5 14A8 8 0 0 1 13 6M10 3l3 3-3 3",
    label: "向右旋转",
  },
  "flip-horizontal": {
    path: "M12 2v3m0 3v3m0 3v3m0 3v2M9 5 3 18h6V5m6 0 6 13h-6V5",
    label: "水平翻转",
  },
  "flip-vertical": {
    path: "M2 12h3m3 0h3m3 0h3m3 0h2M5 9l13-6v6H5m0 6 13 6v-6H5",
    label: "垂直翻转",
  },
  reset: { path: "M4 8V3m0 5h5M4 8a8 8 0 1 1-1 8", label: "重置" },
  share: { path: "M12 16V3m-4 4 4-4 4 4M6 11H4v10h16V11h-2", label: "导出" },
  more: { path: "M5 12h.1M12 12h.1M19 12h.1", label: "更多" },
  close: { path: "m6 6 12 12M18 6 6 18", label: "关闭" },
  check: { path: "m5 12 4 4L19 6", label: "完成" },
  download: { path: "M12 3v12m-4-4 4 4 4-4M4 17v4h16v-4", label: "更新" },
  settings: {
    path: "M4 6h16M4 12h16M4 18h16M8 3v6m8 0v6M9 15v6",
    label: "调整",
  },
  warning: { path: "m12 3 10 18H2L12 3m0 6v5m0 3h.1", label: "错误" },
  zoom: {
    path: "M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14m5 12 6 6M7 10h6m-3-3v6",
    label: "缩放",
  },
  chevron: { path: "m6 9 6 6 6-6", label: "展开" },
  info: {
    path: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M12 10v7m0-10h.1",
    label: "照片信息",
  },
  grid: {
    path: "M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z",
    label: "相册",
  },
  trash: {
    path: "M4 6h16M9 3h6M6 6l1 15h10l1-15M10 10v7m4-7v7",
    label: "删除",
  },
  lock: { path: "M5 10h14v11H5zM8 10V7a4 4 0 0 1 8 0v3", label: "隐私" },
  swap: {
    path: "M4 8h16m-4-4 4 4-4 4M20 16H4m4-4-4 4 4 4",
    label: "拖动分割线",
  },
  fit: { path: "M8 3H3v5m13-5h5v5M3 16v5h5m8 0h5v-5", label: "适合窗口" },
};

Object.assign(RawLabDesignIcons.compare, {
  native: {
    ios: "circle.lefthalf.filled (current); rectangular comparison proposed",
    android: "Icons.Outlined.Compare",
    macos: "rectangle.split.2x1",
    windows: "EditorIcon.Compare",
  },
  decision: "三态循环：关闭、并排、拖动分割线；统一矩形分屏轮廓",
});
Object.assign(RawLabDesignIcons["rotate-left"], {
  native: {
    ios: "rotate.left",
    android: "RotateLeft",
    macos: "rotate.left",
    windows: "EditorIcon.RotateLeft",
  },
});
Object.assign(RawLabDesignIcons["rotate-right"], {
  native: {
    ios: "rotate.right",
    android: "RotateRight",
    macos: "rotate.right",
    windows: "EditorIcon.RotateRight",
  },
});
