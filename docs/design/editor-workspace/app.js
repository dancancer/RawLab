const { palettes, groups, tools } = RawLabDesign;
const params = new URLSearchParams(location.search);
const platform = params.get("platform") || "ios";
const mobile = ["ios", "android"].includes(platform);
const app = document.querySelector("#app");
document.body.classList.add(platform, mobile ? "mobile" : "desktop");
const UPDATE_SCENES = [
  "update",
  "updating-wait",
  "update-error",
  "update-ready",
];
let scene = "groups",
  group = null,
  tool = null,
  channel = 3,
  draft = false,
  modal = null,
  menu = null,
  toastText = "",
  download = "available",
  large = false;
let hsl = palettes.map(() => [0, 0, 0]);
hsl[3] = [-12, 18, 8];
let draftTouched = false;
let selectedFilm = "中性",
  selectedRecipe = "",
  wbMode = "拍摄时设置",
  denoiseEnabled = false;
const recipes = RawLabDesign.recipes;
const values = { ...RawLabDesign.fixture };
let fineMode = false;
let groupScrollLeft = 0;
let swatchScrollLeft = 0;
let previewBusy = false;
// compareMode: 0 关闭，1 并排，2 分割线；lastCompare 让点按开关回到上次使用的方式。
let compareMode = 0,
  lastCompare = 1,
  comparePosition = 50,
  holdingBefore = false,
  zoomChoice = "适合窗口",
  infoState = "hide",
  photoMargin = true,
  immersive = false,
  histogramVisible = true,
  sidebarVisible = true,
  dockVisible = true,
  cropGrid = true,
  canRedo = false;
const compareNames = ["关闭对比", "并排对比", "拖动分割线"];
const defaults = { ...RawLabDesign.defaults };
const neutralFilm = "中性";
let draftBefore = { ...values };
let cropDrag = null,
  holdTimer = null,
  holdPointer = null,
  tapStart = null;
const activePointers = new Set();
const toolFields = {
  exposure: ["exposure"],
  highlights: ["highlights"],
  shadows: ["shadows"],
  contrast: ["contrast"],
  curve: ["curve"],
  saturation: ["saturation"],
  wb: ["temperature", "tint"],
  strength: ["strength"],
  vignette: [
    "vignette",
    "vignetteMid",
    "vignetteRound",
    "vignetteFeather",
    "vignetteHigh",
  ],
  grain: ["grain", "grainSize", "grainRoughness"],
  denoise: ["denoiseLuma", "denoiseChroma", "denoiseCoarse"],
  sharpen: ["sharpen"],
  geometry: [
    "straighten",
    "perspective",
    "horizontal",
    "cropX",
    "cropY",
    "cropW",
    "cropH",
  ],
};
function icon(name) {
  const entry = RawLabDesignIcons[name];
  if (!entry) throw new Error("Unknown design icon: " + name);
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${entry.path}"/></svg>`;
}
function btn(action, name, label, extra = "", disabled = false) {
  return `<button class="icon ${extra}" data-action="${action}" aria-label="${label}" title="${label}" ${disabled ? "disabled" : ""}>${icon(name)}</button>`;
}
function fmt(n) {
  return Number(n) > 0 ? "+" + Number(n) : String(Number(n));
}
function groupName(id = group) {
  return groups.find((g) => g[0] === id)?.[1] || "调整";
}
function toolName(id = tool) {
  return Object.values(tools)
    .flat()
    .find(([t]) => t === id)?.[1];
}
function isDraftChanged() {
  return (
    draftTouched ||
    Object.keys(values).some((k) => values[k] !== draftBefore[k])
  );
}
function setScene(s) {
  cancelBeforeHold();
  cropDrag = null;
  activePointers.clear();
  RawLabDesignFlows.close();
  scene = s;
  previewBusy = s === "processing";
  dockVisible = true;
  menu = null;
  holdingBefore = s === "compare-hold";
  infoState = s === "photo-info" ? "file" : "hide";
  photoMargin = s !== "edge-to-edge";
  immersive = s === "immersive";
  compareMode = s === "compare" ? 1 : s === "compare-wipe" ? 2 : 0;
  if (compareMode) lastCompare = compareMode;
  if (s === "draft-confirm") s = "draft";
  if (s === "draft") {
    draftBefore = {
      ...values,
      straighten: 0,
      cropX: 0,
      cropY: 0,
      cropW: 100,
      cropH: 100,
    };
    Object.assign(values, {
      straighten: 1.2,
      cropX: 4,
      cropY: 5,
      cropW: 90,
      cropH: 88,
    });
  }
  modal = null;
  draft = s === "draft";
  group = ["hsl", "saving-error", "processing", "reset-menu"].includes(s)
    ? "color"
    : s === "light"
      ? "light"
      : ["draft", "raster"].includes(s)
        ? "geometry"
        : null;
  tool =
    group === "color"
      ? "hsl"
      : group === "light"
        ? "exposure"
        : group === "geometry"
          ? s === "raster"
            ? "lens"
            : "geometry"
          : null;
  download =
    s === "updating-wait"
      ? "waiting"
      : s === "update-error"
        ? "error"
        : s === "update-ready"
          ? "ready"
          : "available";
  if (s.startsWith("tool-")) {
    tool = s.slice(5);
    group =
      Object.keys(tools).find((key) =>
        tools[key].some(([id]) => id === tool),
      ) || null;
    if (group === "geometry") {
      draft = true;
      draftBefore = { ...values };
    }
  }
  if (scene === "wb-unavailable") {
    group = "color";
    tool = "wb";
  }
  if (scene === "draft-confirm") modal = { kind: "leave", target: null };
  if (scene === "reset-menu") menu = { kind: "reset" };
  if (
    RawLabDesign.flowTitles[scene] &&
    ![
      "compare",
      "compare-wipe",
      "compare-hold",
      "draft-confirm",
      "update-ready",
      "reset-menu",
      "photo-info",
      "edge-to-edge",
      "immersive",
    ].includes(scene)
  )
    RawLabDesignFlows.open(scene, { seed: true });
  render();
}
function desktopTitle() {
  if (mobile)
    return `<div class="statusbar"><span>9:41</span><span class="system-status"><svg viewBox="0 0 38 16" aria-hidden="true"><path d="M1 13V9h3v4m3 0V6h3v7m3 0V3h3v10" stroke="currentColor" stroke-width="2"/><path d="M22 5q6-5 12 0m-10 3q4-3 8 0m-6 3q2-1 4 0" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>93%</span></div>`;
  if (platform === "macos")
    return `<div class="os-title"><div class="traffic"><i></i><i></i><i></i></div><span class="app-title">RawLab Mac</span><span style="width:45px"></span></div>`;
  return `<div class="os-title">${icon("photo")}<span>RawLab</span><div class="win-controls"><span>−</span><span><svg viewBox="0 0 16 16"><path d="M4 4h8v8H4z" stroke="currentColor" fill="none"/></svg></span><span>×</span></div></div>`;
}
// WPF MainWindow.xaml 有经典菜单栏；撤销、重做和复制粘贴放在“编辑”下并标明规划状态。
const winMenus = {
  文件: [
    ["import", "打开 RAW…", "Ctrl+O"],
    ["sidebar", "文件树"],
    ["-"],
    ["export", "导出…"],
  ],
  编辑: [
    ["undo", "撤销", "Ctrl+Z"],
    ["redo", "重做", "Ctrl+Y", !canRedo],
    ["-"],
    ["planned", "复制调整 · 规划中", "Ctrl+Shift+C", true],
    ["planned", "粘贴调整 · 规划中", "Ctrl+Shift+V", true],
    ["-"],
    ["reset-tool", "重置本工具"],
    ["reset-all", "重置全部调整…"],
  ],
  查看: [
    ["toggle-dock", "调整栏"],
    ["histogram", "直方图"],
    ["photo-info", "照片信息"],
    ["photo-margin", "照片四周留白"],
    ["-"],
    ["compare-set:0", "关闭对比"],
    ["compare-set:1", "并排对比"],
    ["compare-set:2", "拖动分割线"],
    ["-"],
    ["zoom", "缩放…"],
  ],
  工具: [["auto-exposure", "自动调整曝光"], ["-"], ["settings", "设置"]],
  帮助: [["about", "关于 RawLab / 检查更新"]],
};
function winMenubar() {
  if (platform !== "windows") return "";
  const keys = { 文件: "F", 编辑: "E", 查看: "V", 工具: "T", 帮助: "H" };
  return `<div class="win-menubar" role="menubar">${Object.keys(winMenus)
    .map(
      (name) =>
        `<button role="menuitem" data-action="win-menu" data-menu="${name}" data-menu-anchor="win-${name}" aria-haspopup="menu" aria-expanded="${menu?.kind === "win-" + name}">${name}(<u>${keys[name]}</u>)</button>`,
    )
    .join("")}</div>`;
}
function compareControl() {
  const label = compareMode
    ? "关闭对比（当前：" + compareNames[compareMode] + "）"
    : "打开对比：" +
      compareNames[lastCompare] +
      (mobile ? "；长按选择方式" : "");
  return `<span class="split-button" data-menu-anchor="compare">${btn("compare", "compare", label, compareMode ? "yellow" : "")}${mobile ? "" : `<button class="icon caret" data-action="compare-menu" aria-label="选择对比方式" title="选择对比方式" aria-haspopup="menu" aria-expanded="${menu?.kind === "compare"}">${icon("chevron")}</button>`}</span>`;
}
function toolbar() {
  const history =
    btn("undo", "undo", "撤销（第二阶段规划）") +
    btn("redo", "redo", "重做（第二阶段规划）", "", !canRedo);
  const exportButton = btn(
    "export",
    "share",
    "导出照片",
    draft ? "" : "yellow",
  );
  if (platform === "windows")
    return `<div class="toolbar"><span class="brand wordmark">RAWLAB</span>${btn("import", "folder", "打开 RAW（Ctrl+O）")}${btn("sidebar", "grid", "显示或收起文件树")}<span class="toolbar-sep"></span>${history}<span class="toolbar-sep"></span>${compareControl()}${btn("zoom", "zoom", "缩放")}${btn("photo-info", "info", "照片信息")}${btn("toggle-dock", "settings", "调整栏", dockVisible ? "yellow" : "")}<span class="space"></span>${exportButton}${btn("settings", "gear", "设置")}${btn("about", "help", "关于 RawLab / 检查更新")}</div>`;
  if (mobile)
    return `<div class="toolbar">${btn("import", "photo", "打开照片", "yellow")}<span class="brand">RawLab</span><span class="space"></span>${history}${compareControl()}${btn("more", "more", "更多")}${exportButton}</div>`;
  return `<div class="toolbar">${btn("sidebar", "folder", "显示或隐藏文件树")}${btn("import", "photo", "打开照片")}<span class="brand">RawLab</span><span class="file">${fileName()}</span><span class="space"></span>${history}<span class="toolbar-sep"></span>${compareControl()}${btn("photo-info", "info", "照片信息")}${btn("zoom", "zoom", "缩放")}${btn("toggle-dock", "settings", "显示或隐藏调整区", dockVisible ? "yellow" : "")}${btn("more", "more", "更多")}${exportButton}</div>`;
}
function fileName() {
  return scene === "raster" ? "瀑布.jpg" : "瀑布.ARW";
}
let photoId = 0;
function photoMarkup(cssClass = "photo", label = "用于布局评审的瀑布示例照片") {
  const media = RawLabDesignManifest.media.photo;
  const clipId = `review-photo-${++photoId}`;
  const [x, y, width, height] = media.viewBox;
  return `<svg class="${cssClass}" viewBox="${media.viewBox.join(" ")}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="${label}"><defs><clipPath id="${clipId}"><rect x="${x}" y="${y}" width="${width}" height="${height}"/></clipPath></defs><image clip-path="url(#${clipId})" href="${media.source}" width="${media.sourceSize[0]}" height="${media.sourceSize[1]}"/></svg>`;
}
function filetree() {
  return mobile || !sidebarVisible
    ? ""
    : `<aside class="filetree"><h3>照片文件夹 <button class="icon" data-flow="library" aria-label="浏览照片文件夹">${icon("folder")}</button></h3><div class="folder">${icon("chevron")}旅行照片</div><div class="thumbs">${["瀑布.ARW", "山谷.ARW", "林间.ARW", "溪流.ARW", "晨光.ARW", "岩石.ARW"].map((name, i) => `<button class="thumbnail ${i === 0 ? "selected" : ""}" data-action="photo">${photoMarkup("photo", "照片缩略图")}<span>${name}</span></button>`).join("")}</div></aside>`;
}
// 示例数据：森林照片绿色集中在中间调，天空让蓝色偏向高光，红色整体偏低。
const histogramChannels = [
  ["#ff3b30", [46, 40, 30, 22, 24, 31, 38, 41, 42, 43, 40, 37, 39, 44, 47]],
  ["#34c759", [46, 43, 34, 18, 9, 12, 20, 27, 33, 35, 31, 30, 36, 43, 47]],
  ["#0a84ff", [46, 44, 38, 30, 27, 31, 36, 34, 28, 22, 19, 24, 33, 41, 46]],
];
function histogramSVG() {
  const step = 130 / (histogramChannels[0][1].length - 1);
  return `<svg class="rgb-histogram" viewBox="0 0 130 48" aria-hidden="true">${histogramChannels
    .map(
      ([color, ys]) =>
        `<path d="M0 48${ys.map((y, i) => `L${(i * step).toFixed(1)} ${y}`).join("")}L130 48Z" fill="${color}"/>`,
    )
    .join("")}</svg>`;
}
function histogram() {
  return `<div class="histogram ${histogramVisible ? "" : "collapsed"}" role="img" aria-label="RGB 直方图（示例）"><button data-action="histogram" aria-label="${histogramVisible ? "收起" : "展开"}直方图">直方图 ${icon("chevron")}</button>${histogramVisible ? histogramSVG() : ""}</div>`;
}
function compareSwitch() {
  return `<div class="compare-switch" role="radiogroup" aria-label="对比方式">${[
    [1, "并排"],
    [2, "分割线"],
  ]
    .map(
      ([m, t]) =>
        `<button role="radio" data-compare-mode="${m}" aria-checked="${compareMode === m}">${t}</button>`,
    )
    .join("")}</div>`;
}
function comparisonMarkup() {
  const before = photoMarkup("compare-photo", "调整前（中性显影）示意");
  const after = photoMarkup("compare-photo", "调整后示意");
  const panes = `<div class="comparison-pane original">${before}<span class="pane-label">调整前</span></div><div class="comparison-pane result">${after}<span class="pane-label">调整后</span></div>`;
  if (compareMode === 1)
    return `<div class="compare-stage side-by-side">${panes}</div>${compareSwitch()}`;
  return `<div class="compare-stage wipe" style="--split:${comparePosition}%"><div class="photo-frame">${panes}<div class="compare-divider"><i>${icon("swap")}</i></div><input class="compare-position" type="range" min="0" max="100" value="${comparePosition}" data-compare-position aria-label="调整对比分割线"></div></div>${compareSwitch()}`;
}
function cropOverlay() {
  if (!(draft && group === "geometry" && tool === "geometry")) return "";
  const rect = `left:${values.cropX}%;top:${values.cropY}%;width:${values.cropW}%;height:${values.cropH}%`;
  const handles = [
    ["nw", "左上角"],
    ["n", "上边"],
    ["ne", "右上角"],
    ["e", "右边"],
    ["se", "右下角"],
    ["s", "下边"],
    ["sw", "左下角"],
    ["w", "左边"],
  ];
  return `<div class="crop-shade" aria-hidden="true"><i style="${rect}"></i></div><div class="crop-frame ${cropGrid ? "grid" : ""}" style="${rect}">${handles.map(([h, n]) => `<span class="crop-handle ${h}" data-crop-handle="${h}" tabindex="0" role="slider" aria-label="裁切${n}，方向键调整" aria-valuetext="左 ${values.cropX}% 上 ${values.cropY}% 宽 ${values.cropW}% 高 ${values.cropH}%"></span>`).join("")}</div>`;
}
function photoInfo() {
  const raster = scene === "raster";
  const rows =
    infoState === "file"
      ? [
          ["文件", fileName()],
          ["类型", raster ? "JPEG · sRGB" : "RAW · Sony ARW"],
          ["尺寸", "7952 × 5304"],
          ["大小", raster ? "18.4 MB" : "61.2 MB"],
          ["白平衡", raster ? "不适用" : "拍摄时设置"],
        ]
      : infoState === "capture"
        ? [
            ["相机", "Sony α7R IV"],
            ["镜头", "FE 24-70mm F2.8 GM"],
            ["曝光", "1/200 秒 · f/4 · ISO 200"],
            ["焦距", "35 mm"],
            ["拍摄", "2026-08-12 06:41"],
          ]
        : [];
  const label =
    infoState === "file"
      ? "文件信息"
      : infoState === "capture"
        ? "拍摄参数"
        : "";
  // 只有标题可点击，信息文字不拦截照片上的缩放与拖动。
  return `<div class="photo-info ${rows.length ? "open" : ""}"><button class="info-chip ${rows.length ? "" : "icon-only"}" data-action="photo-info" aria-label="照片信息${label ? "：" + label : ""}" aria-expanded="${!!rows.length}" title="照片信息：点击依次显示文件信息、拍摄参数，再点收起${mobile ? "" : "（I）"}">${icon("info")}${label ? `<span>${label}</span>` : ""}${rows.length ? `<small>${infoState === "file" ? "1" : "2"} / 2</small>` : ""}</button>${rows.length ? `<dl class="info-layer">${rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("")}<dt></dt><dd class="sample">示例数据</dd></dl>` : ""}</div>`;
}
function canvas() {
  if (scene === "empty")
    return `<div class="canvas ${photoMargin ? "" : "edge"}"><div class="empty-content"><div class="empty-icon">${icon("photo")}</div><h2>打开一张照片</h2><p>导入 RAW 或支持的普通图片，开始调整与比较。</p><button class="primary" data-action="import">打开照片</button></div></div>`;
  const photo = compareMode
    ? comparisonMarkup()
    : `<div class="photo-frame ${holdingBefore ? "holding" : ""}" data-photo-frame title="按住照片查看调整前">${photoMarkup()}${holdingBefore ? '<span class="before-badge" role="status">调整前</span>' : ""}${cropOverlay()}</div>`;
  return `<div class="canvas ${photoMargin ? "" : "edge"}">${photo}${photoInfo()}${histogram()}${!compareMode ? `<div class="photo-footer">${selectedFilm} · ${zoomChoice}</div>` : ""}<div class="preview-progress" role="progressbar" aria-label="正在更新预览" ${previewBusy ? "" : "hidden"}><i></i></div>${scene === "saving-error" ? `<div class="save-error">${icon("warning")}<span>调整未保存</span><button data-action="retry-save">重试</button></div>` : ""}</div>`;
}
function toolChanged(id) {
  if (id === "film") return selectedFilm !== neutralFilm;
  if (id === "recipe") return !!selectedRecipe;
  if (id === "hsl") return hsl.some((c) => c.some((v) => v !== 0));
  if (id === "wb" && wbMode !== "拍摄时设置") return true;
  if (id === "denoise" && denoiseEnabled) return true;
  return (toolFields[id] || []).some((f) => values[f] !== defaults[f]);
}
// 可见标记统一为小点；完整说明只放在可访问名称和提示里，避免外语文案被截断。
function groupMark(id) {
  if (id === "looks")
    return selectedRecipe
      ? "已选大师配方"
      : selectedFilm !== neutralFilm
        ? "已选 " + selectedFilm
        : values.strength !== 100
          ? "强度已调整"
          : "";
  const n = tools[id].filter(([t]) => toolChanged(t)).length;
  return n ? n + " 项已调整" : "";
}
function groupNav() {
  return `<nav class="group-nav" aria-label="调整分组">${groups
    .map(([id, name, g]) => {
      const mark = groupMark(id);
      return `<button class="group ${group === id ? "selected" : ""}" data-group="${id}" aria-pressed="${group === id}" aria-label="${name}${mark ? "，" + mark : ""}" title="${mark ? name + "：" + mark : name}"><span class="glyph">${icon(g)}<i class="mark ${mark ? "on" : ""}" aria-hidden="true"></i></span><span class="name">${name}</span></button>`;
    })
    .join("")}</nav>`;
}
function tabs() {
  const planned =
    group === "looks"
      ? '<button class="planned" disabled aria-label="我的预设，第二阶段规划，当前不可用">我的预设<small>规划中</small></button>'
      : "";
  return `<div class="tool-tabs" aria-label="${groupName()}组内工具">${tools[
    group
  ]
    .map(([id, name]) => {
      const changed = toolChanged(id);
      return `<button data-tool="${id}" class="${tool === id ? "selected" : ""}" aria-pressed="${tool === id}" aria-label="${name}${changed ? "，已调整" : ""}">${name}${changed ? '<i class="tab-dot" aria-hidden="true"></i>' : ""}</button>`;
    })
    .join("")}${planned}</div>`;
}
// 输入框里只放数字；单位在框外单独显示，不参与编辑。
function displayValue(value, field, min) {
  if (field === "temperature") return String(value);
  if (field === "exposure") return fmt(Number(value).toFixed(2));
  return min < 0 ? fmt(value) : String(Number(value));
}
function parameterValue(field) {
  return field.startsWith("hsl-")
    ? hsl[channel][Number(field.slice(4))]
    : values[field];
}
function parseParameter(raw, min, max, step, original) {
  const text = raw.trim();
  if (!/^[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(text))
    return { error: "请输入完整的数值" };
  const value = Number(text);
  if (!Number.isFinite(value) || value < min || value > max)
    return { error: "请输入范围内的数值" };
  // 旧记录的合法小数可原样关闭；只有新的输入才按当前平台网格校验。
  if (value === original) return { value, unchanged: true };
  const grid = (value - min) / step;
  if (Math.abs(grid - Math.round(grid)) > 1e-7)
    return { error: "请输入步进为 " + step + " 的数值" };
  return { value, unchanged: false };
}
function commitParameter(field, value) {
  if (field.startsWith("hsl-")) hsl[channel][Number(field.slice(4))] = value;
  else {
    values[field] = value;
    if (["temperature", "tint"].includes(field)) wbMode = "自定义";
  }
}
function unitOf(field) {
  if (field === "temperature") return "K";
  if (field === "exposure") return "EV";
  if (field === "straighten") return "°";
  if (
    field.startsWith("hsl-") ||
    ["tint", "perspective", "horizontal"].includes(field)
  )
    return "";
  return "%";
}
function axisDefault(field) {
  return field.startsWith("hsl-") ? 0 : (defaults[field] ?? 0);
}
// 黄色填充从默认值画到当前值：双向参数从中点向两侧，单向参数从起点开始。
function fillVars(value, field, min, max) {
  const d = Math.min(max, Math.max(min, axisDefault(field)));
  const p = (v) => (((v - min) / (max - min)) * 100).toFixed(2) + "%";
  return `--lo:${p(Math.min(d, value))};--hi:${p(Math.max(d, value))}`;
}
function hexHue(hex) {
  const [r, g, b] = [1, 3, 5].map(
    (i) => parseInt(hex.slice(i, i + 2), 16) / 255,
  );
  const max = Math.max(r, g, b),
    d = max - Math.min(r, g, b);
  if (!d) return 0;
  const h =
    max === r
      ? ((g - b) / d) % 6
      : max === g
        ? (b - r) / d + 2
        : (r - g) / d + 4;
  return Math.round((h * 60 + 360) % 360);
}
// 色相条显示当前色域向两侧邻色的偏移；饱和度从灰到纯色；明度从暗到亮。
function hslTrack(axisIndex) {
  const h = hexHue(palettes[channel][1]);
  if (axisIndex === 0)
    return `linear-gradient(90deg,hsl(${h - 35} 62% 55%),hsl(${h} 62% 55%),hsl(${h + 35} 62% 55%))`;
  if (axisIndex === 1)
    return `linear-gradient(90deg,hsl(${h} 0% 55%),hsl(${h} 80% 55%))`;
  return `linear-gradient(90deg,hsl(${h} 55% 14%),hsl(${h} 55% 52%),hsl(${h} 55% 88%))`;
}
function ruler(value, min, max) {
  const interval = (max - min) / 40,
    px = 15,
    span = (340 / px) * interval;
  // 视窗以当前值居中，但不越过参数范围；靠近两端时指示线移向边缘，刻度始终铺满整条。
  const start = Math.min(Math.max(value - span / 2, min), max - span);
  const x = (v) => ((v - start) / interval) * px;
  let marks = "",
    labels = "";
  for (
    let k = Math.ceil(start / interval - 1e-6);
    k * interval <= start + span + 1e-6;
    k++
  ) {
    const v = k * interval;
    if (v < min - 1e-6 || v > max + 1e-6) continue;
    const major = Math.abs(k / 5 - Math.round(k / 5)) < 0.01;
    marks += `<path d="M${x(v).toFixed(1)} ${major ? 4 : 10}V20" stroke="#929299" stroke-width="1"/>`;
    // 数字按百分比定位，不随刻度尺宽度变形；两端留出字宽，避免被裁成半个字符。
    if (major && x(v) > 24 && x(v) < 316)
      labels += `<span class="tick-label" style="left:${((x(v) / 340) * 100).toFixed(2)}%">${Number(v.toFixed(2))}</span>`;
  }
  const at = x(value).toFixed(1);
  return `<svg viewBox="0 0 340 20" preserveAspectRatio="none" aria-hidden="true">${marks}<path d="M${at} 0V20" stroke="#f2ce48" stroke-width="2"/></svg>${labels}`;
}
function axis(
  name,
  value,
  field,
  min = -100,
  max = 100,
  step = 0.1,
  note = "",
) {
  const text = displayValue(value, field, min);
  const changed = Number(value) !== axisDefault(field);
  const track = field.startsWith("hsl-")
    ? hslTrack(Number(field.slice(4)))
    : "";
  const range = `<input class="slider ${track ? "gradient" : ""}" aria-label="${name}" type="range" min="${min}" max="${max}" step="${step}" value="${value}" data-axis="${field}" style="${fillVars(value, field, min, max)}${track ? ";--track-image:" + track : ""}">`;
  const control =
    platform === "ios"
      ? `<div class="ruler-control">${track ? `<i class="ruler-band" style="background:${track}"></i>` : ""}<div class="ruler-ticks">${ruler(value, min, max)}</div>${range}</div>`
      : range;
  const unit = unitOf(field);
  const number = mobile
    ? `<button class="number ${changed ? "changed" : ""}" data-number="${field}" data-min="${min}" data-max="${max}" data-step="${step}" aria-label="${name}精确数值：${text}${unit}">${text}</button>`
    : `<input class="number inline-number ${changed ? "changed" : ""}" aria-label="${name}数值${unit ? "（" + unit + "）" : ""}" data-inline-field="${field}" data-min="${min}" data-max="${max}" data-step="${step}" value="${text}">`;
  // 单位位置每行都保留，没有单位时留空，上下行的数值框保持对齐。
  return `<div class="axis" data-axis-row="${field}" title="双击名称或滑杆恢复默认"><span class="axis-name">${name}</span>${control}<span class="axis-value">${number}<span class="unit" aria-hidden="true">${unit}</span></span>${note ? `<p class="axis-note">${note}</p>` : ""}</div>`;
}
// 开关统一用开关组件；保留原生复选框语义，便于读屏与键盘操作。
function switchControl(label, attrs, checked) {
  return `<label class="switch-row"><span>${label}</span><input type="checkbox" role="switch" class="switch" ${attrs} ${checked ? "checked" : ""}></label>`;
}
function segmented(label, items, attr) {
  return `<div class="segmented" role="radiogroup" aria-label="${label}">${items.map(([value, text, checked, disabled]) => `<button role="radio" ${attr}="${value}" aria-checked="${!!checked}" ${disabled ? "disabled" : ""}>${text}</button>`).join("")}</div>`;
}
function hslPanel() {
  const name = palettes[channel][0];
  const bandChanged = (i) => hsl[i].some((v) => v !== 0);
  return `<div class="hsl-layout"><div class="channel-block">${mobile ? "" : `<div class="channel-title"><strong>${name}色</strong></div>`}<div class="swatches" role="radiogroup" aria-label="HSL 色域">${palettes.map(([n, color], i) => `<button class="swatch ${bandChanged(i) ? "changed" : ""}" role="radio" data-channel="${i}" aria-label="${n}色${bandChanged(i) ? "，已调整" : ""}" aria-checked="${channel === i}" aria-pressed="${channel === i}"><i style="background:${color}"></i></button>`).join("")}</div></div><div class="axes">${["色相", "饱和度", "明度"].map((axisName, i) => axis(axisName, hsl[channel][i], "hsl-" + i, -100, 100, mobile ? 1 : 0.1)).join("")}</div></div>`;
}
function scalarPanel() {
  if (scene === "wb-unavailable" && tool === "wb")
    return '<div class="scalar-layout"><p class="notice-inline"><strong>无法取得有效的相机白平衡校准</strong><br>保留拍摄时模式，暂不可手动调整色温与色调。</p><div class="flow-static"><span>色温 / 色调</span><span>不可用</span></div></div>';
  if (["denoise", "grain", "vignette"].includes(tool)) return complexPanel();
  if (tool === "wb")
    return `<div class="scalar-layout"><div class="option-row"><span class="field-inline">白平衡<button class="menu-button" data-action="wb-mode" ${scene === "raster" ? "disabled" : ""}>${scene === "raster" ? "不适用" : wbMode + " " + icon("chevron")}</button></span></div>${scene === "raster" ? '<p class="notice-inline">RAW 专属：普通图片不提供拍摄时白平衡校准。</p>' : axis("色温", values.temperature, "temperature", 2000, 50000, 10) + axis("色调", values.tint, "tint", -150, 150, 0.1)}</div>`;
  const specs = {
    exposure: ["曝光", -4, 4, platform === "ios" ? 0.05 : 0.01],
    highlights: ["高光", -100, 100, 0.1],
    shadows: ["阴影", -100, 100, 0.1],
    contrast: ["对比度", -100, 100, 0.1],
    curve: ["S 曲线", -100, 100, 0.1],
    saturation: ["饱和度", -100, 100, 0.1],
    strength: ["外观强度", 0, 200, 0.1],
    vignette: ["暗角", -100, 100, 0.1],
    grain: ["颗粒", 0, 100, 0.1],
    denoise: ["降噪强度", 0, 100, 1],
    sharpen: ["锐化", 0, 200, 0.1],
  };
  const [name, min, max, step] = specs[tool] || specs.exposure;
  return `<div class="scalar-layout">${axis(name, values[tool] || 0, tool, min, max, step)}${tool === "exposure" ? `<div class="option-row"><label class="field-inline">曝光基准<select aria-label="曝光基准" ${scene === "raster" ? "disabled" : ""}><option>匹配内嵌预览</option><option>标准显影</option><option>传感器基准</option></select></label><button class="secondary small" data-action="auto-exposure">自动曝光</button></div>` : ""}</div>`;
}
function complexPanel() {
  let fields = [];
  let extra = "";
  if (tool === "grain")
    fields = [
      ["强度", "grain", 0, 100],
      ["大小", "grainSize", 0, 100],
      ["粗糙度", "grainRoughness", 0, 100],
    ];
  if (tool === "vignette")
    fields = [
      ["强度", "vignette", -100, 100],
      ["中点", "vignetteMid", 0, 100],
      ["圆度", "vignetteRound", -100, 100],
      ["羽化", "vignetteFeather", 0, 100],
      ["高光保护", "vignetteHigh", 0, 100, "仅在压暗四角（强度为负）时可用"],
    ];
  if (tool === "denoise") {
    const presets = { detail: [0, 46, 50], clean: [10, 72, 100] };
    const current = [
      values.denoiseLuma,
      values.denoiseChroma,
      values.denoiseCoarse,
    ];
    const preset =
      Object.keys(presets).find((k) => presets[k].join() === current.join()) ||
      "custom";
    // 与原生 Mac 一致：降噪开关加预设分段，自定义只在参数偏离预设时出现。
    extra = `<div class="option-row">${switchControl("降噪", 'id="denoise-enabled"', denoiseEnabled)}${segmented(
      "降噪预设",
      [
        ["detail", "细节优先", preset === "detail"],
        ["clean", "去噪优先", preset === "clean"],
        ...(preset === "custom" ? [["custom", "自定义", true, true]] : []),
      ],
      "data-denoise-preset",
    )}</div>`;
    fields = [
      ["亮度降噪", "denoiseLuma", 0, 100],
      ["色彩降噪", "denoiseChroma", 0, 100],
      ["粗色斑抑制", "denoiseCoarse", 0, 100, "抑制成片出现的彩色噪点"],
    ];
  }
  return `<div class="multi-parameter">${extra}<div class="parameter-grid">${fields.map(([n, f, min, max, note]) => axis(n, values[f], f, min, max, 0.1, note)).join("")}</div></div>`;
}
function geometryPanel() {
  if (tool === "lens" && scene === "raster")
    return `<div class="scalar-layout"><p class="notice-inline"><strong>镜头校正仅适用于 RAW 照片</strong><br>当前为普通图片，无法使用相机和镜头校准数据。其他颜色与效果调整仍可使用。</p><button class="secondary" data-action="goto-color" style="margin-top:15px">前往颜色调整</button></div>`;
  if (tool === "lens")
    return `<div class="lens-panel"><div class="option-row">${switchControl("自动匹配镜头", "data-lens-auto", true)}<span class="muted">已匹配：FE 24-70mm F2.8 GM</span><button class="secondary small" data-action="lens-profile">选择镜头配置</button></div><div class="option-row">${["畸变校正", "横向色差校正", "自动裁切"].map((n, i) => switchControl(n, "data-lens-option", i === 2)).join("")}</div></div>`;
  return `<div class="geometry-panel"><div class="option-row"><div class="geometry-icons">${[
    ["rotate-left", "向左旋转"],
    ["rotate-right", "向右旋转"],
    ["flip-horizontal", "水平翻转"],
    ["flip-vertical", "垂直翻转"],
  ]
    .map(([name, label]) => btn("geometry-operation", name, label))
    .join(
      "",
    )}</div><label class="field-inline">比例<select aria-label="裁切比例"><option>原始比例</option><option>自由</option><option>1:1</option><option>4:3</option><option>3:2</option><option>16:9</option></select></label>${switchControl("三分网格", "data-crop-grid", cropGrid)}</div><div class="parameter-grid">${axis("拉直", values.straighten, "straighten", -45, 45, 0.01)}${axis("水平透视", values.horizontal, "horizontal", platform === "windows" ? -1 : -100, platform === "windows" ? 1 : 100, platform === "windows" ? 0.001 : 0.1)}${axis("垂直透视", values.perspective, "perspective", platform === "windows" ? -1 : -100, platform === "windows" ? 1 : 100, platform === "windows" ? 0.001 : 0.1)}</div><details><summary>精确裁切</summary><div class="parameter-grid">${[
    ["左边", "cropX"],
    ["上边", "cropY"],
    ["宽度", "cropW"],
    ["高度", "cropH"],
  ]
    .map(([n, f]) =>
      axis(
        "裁切" + n,
        values[f],
        f,
        f === "cropW" || f === "cropH" ? 0.01 : 0,
        100,
        0.01,
      ),
    )
    .join("")}</div></details></div>`;
}
function looksPanel() {
  if (tool === "strength") return scalarPanel();
  if (tool === "recipe")
    return `<div class="look-list recipe-list"><button class="look ${!selectedRecipe ? "active" : ""}" data-recipe=""><span class="look-art">${icon("none")}</span><span>无配方</span><small>只使用所选胶片</small></button>${recipes.map((r) => `<button class="look ${selectedRecipe === r.id ? "active" : ""}" data-recipe="${r.id}"><img src="${RawLabDesignManifest.media.recipeArtwork}${r.id}.png" alt=""><span>${r.name}</span><small>${r.subtitle}</small></button>`).join("")}</div>`;
  return `<div class="look-list film-list"><button class="look ${selectedFilm === "中性" ? "active" : ""}" data-film="中性"><span class="look-art">${icon("photo")}</span><span>中性</span></button>${RawLabDesign.films.map((f) => `<button class="look ${selectedFilm === f.name ? "active" : ""}" data-film="${f.name}" title="${f.group} · ${f.name}"><img src="${f.artwork}" alt=""><span>${f.name}</span></button>`).join("")}<button class="look" data-flow="looks"><span class="look-art">${icon("folder")}</span><span>导入与管理外观</span></button></div>`;
}
function panelContent() {
  return tool === "hsl"
    ? hslPanel()
    : group === "geometry"
      ? geometryPanel()
      : group === "looks"
        ? looksPanel()
        : scalarPanel();
}
function hasAxes() {
  return (
    !["film", "recipe", "lens"].includes(tool) && scene !== "wb-unavailable"
  );
}
function editor() {
  if (scene === "empty") return "";
  const save = `<span class="save" role="status">${draft ? "未应用草稿" : scene === "saving-error" ? "调整未保存" : scene === "processing" ? "" : "调整已保存"}</span>`;
  const reset = `<button class="quiet reset-trigger" data-action="reset-menu" data-menu-anchor="reset" aria-label="重置" title="重置" aria-haspopup="menu" aria-expanded="${menu?.kind === "reset"}">${icon("reset")}<span>重置</span></button>`;
  // 原生“精细”是拖动灵敏度降为四分之一，一个面板一个开关，不在每行重复。
  const fine =
    mobile && hasAxes()
      ? `<button class="fine-toggle" data-action="fine" aria-pressed="${fineMode}" aria-label="精细" title="精细：拖动灵敏度降为四分之一">${icon("scope")}<span>精细</span></button>`
      : "";
  const panel = group ? `<div class="panel">${panelContent()}</div>` : "";
  const draftBar = draft
    ? `<div class="draft-actions"><button class="secondary" data-action="discard-draft">取消</button><button class="primary" data-action="apply-draft" ${isDraftChanged() ? "" : "disabled"}>应用</button></div>`
    : "";
  // 参数区高度固定，切换工具或出现草稿按钮都不改变照片区大小。
  const area = group ? `<div class="panel-area">${panel}${draftBar}</div>` : "";
  if (!mobile)
    return `<section class="editor ${group ? "has-group" : ""}"><div class="dock-bar">${groupNav()}<span class="space"></span>${save}${reset}</div>${group ? `<div class="tool-row">${tabs()}</div>` : ""}${area}</section>`;
  return `<section class="editor ${group ? "has-group" : ""}">${group ? `<div class="tool-row">${tabs()}<span class="tool-actions">${fine}${reset}</span></div>${area}` : ""}${groupNav()}</section>`;
}
function appIcon() {
  return `<svg class="app-icon" viewBox="0 0 64 64" aria-hidden="true"><rect x="2" y="2" width="60" height="60" rx="14" fill="#2a2a2d"/><rect x="13" y="15" width="28" height="22" rx="2" fill="none" stroke="#f2ce48" stroke-width="4"/><rect x="23" y="27" width="28" height="22" rx="2" fill="none" stroke="#5fc9d2" stroke-width="4"/></svg>`;
}
function windowTitlebar(title, closeAction) {
  return platform === "macos"
    ? `<div class="window-titlebar mac"><span class="traffic"><button class="traffic-close" data-action="${closeAction}" aria-label="关闭窗口"></button><i></i><i></i></span><span>${title}</span><span></span></div>`
    : `<div class="window-titlebar win"><span>${title}</span><button class="caption-close" data-action="${closeAction}" aria-label="关闭窗口">${icon("close")}</button></div>`;
}
// 更新提示只放版本、发布说明和本次选择；长期的自动检查/安装设置在“设置 → 软件更新”。
function updateWindow() {
  if (!UPDATE_SCENES.includes(scene)) return "";
  const notes =
    '<div class="release-notes" tabindex="0" aria-label="发布说明"><strong>0.9.0 更新内容（示例）</strong><ul><li>调整分组与 HSL 混色器</li><li>修复部分照片导入失败</li><li>更新界面翻译</li></ul></div>';
  const progress = (n, label) =>
    `<div class="progress" role="progressbar" aria-valuenow="${n}" aria-label="${label}"><i style="width:${n}%"></i></div><p class="progress-note">${n}% · ${label}（示例）</p>`;
  const act = (id, text, style = "secondary") =>
    `<button class="${style}" data-action="${id}">${text}</button>`;
  const states = {
    available: {
      title: "RawLab 有新版本",
      copy: "RawLab 0.9.0（示例）已可用，当前版本为 0.8.2。安装前会先保存调整，并等待导出完成。",
      extra: notes,
      actions:
        act("skip-version", "跳过此版本", "quiet leading") +
        act("close-update", "稍后提醒") +
        act("download-update", "安装更新", "primary"),
    },
    downloading: {
      title: "正在下载更新",
      copy: "下载完成后会先校验文件，再准备安装。可以继续编辑。",
      extra: progress(62, "下载进度"),
      actions: act("cancel-download", "取消下载"),
    },
    waiting: {
      title: "等待当前任务完成",
      copy: "正在批量导出 3 / 12 张。任务结束并保存调整后再安装，不会强制结束导出。",
      extra: progress(25, "批量导出进度"),
      actions:
        act("close-update", "稍后提醒") +
        act("wait-update", "任务结束后安装", "primary"),
    },
    ready: {
      title: "更新已准备好",
      copy: "当前调整已保存。重启 RawLab 后完成安装。",
      extra: notes,
      actions:
        act("install-later", "下次退出时安装") +
        act("install-update", "重启并安装", "primary"),
    },
    error: {
      title: "暂时无法准备更新",
      copy: "下载文件未通过校验，当前版本仍可继续使用。",
      extra: `<div class="flow-error">${icon("warning")}<div><strong>校验失败</strong><p>请重试；仍失败时可前往官方发布页手动下载。</p></div></div>`,
      actions:
        act("manual-download", "前往发布页手动下载", "quiet leading") +
        act("close-update", "稍后") +
        act("retry-update", "重试", "primary"),
    },
  }[download];
  return `<div class="update-backdrop"></div><section class="update-window" role="dialog" aria-modal="true" aria-label="软件更新" tabindex="-1">${windowTitlebar("软件更新", "close-update")}<div class="update-body">${appIcon()}<div class="update-main"><h2>${states.title}</h2><p>${states.copy}</p>${states.extra}</div></div><div class="update-actions">${states.actions}</div></section>`;
}
function valueWheel() {
  const step = Number(modal.step),
    min = Number(modal.min),
    max = Number(modal.max);
  const numbers = [];
  for (let i = 0; i <= Math.round((max - min) / step); i++)
    numbers.push(Number((min + i * step).toFixed(4)));
  numbers.push(Number(modal.value), defaults[modal.field] ?? 0);
  const sorted = [...new Set(numbers.filter((n) => n >= min && n <= max))].sort(
    (a, b) => a - b,
  );
  return `<select id="number-field" class="wheel-values" size="5" aria-label="${modal.name}临时选择">${sorted.map((n) => `<option value="${n}" ${n === Number(modal.value) ? "selected" : ""}>${n >= 0 && min < 0 ? "+" : ""}${n}</option>`).join("")}</select><button class="quiet" data-action="wheel-default">恢复默认</button>`;
}
function resetCopy(scope) {
  if (scope === "hsl")
    return [
      "重置全部 HSL？",
      "八个色域的色相、饱和度和明度都会恢复为 0。其他调整保持不变。",
    ];
  if (scope === "group")
    return [
      "重置" + groupName() + "组？",
      "此操作只恢复" + groupName() + "组内的调整，其他分组保持不变。",
    ];
  return ["重置全部调整？", "恢复当前照片的全部调整，不改写原始照片。"];
}
function modalHTML() {
  if (!modal) return "";
  let title = "",
    copy = "",
    buttons = "";
  if (modal.kind === "reset") {
    [title, copy] = resetCopy(modal.scope);
    buttons =
      '<button class="secondary" data-action="cancel-modal">取消</button><button class="primary" data-action="confirm-reset">重置</button>';
  } else if (modal.kind === "leave") {
    title = "应用当前草稿？";
    copy = "几何或镜头调整尚未应用。离开前请选择如何处理，原照片不会被改写。";
    if (modal.afterReset)
      copy =
        "几何或镜头调整尚未应用。先处理草稿，再单独确认全部重置；继续编辑会取消本次重置。";
    buttons = `<div class="choice-actions"><button class="primary" data-action="apply-leave" ${previewBusy ? "disabled" : ""}>应用并${modal.afterReset ? "继续" : "离开"}</button><button class="secondary destructive" data-action="discard-leave">放弃修改</button><button class="secondary" data-action="cancel-modal">继续编辑</button></div>`;
  } else if (modal.kind === "number") {
    title = "调整" + modal.name;
    const unit = unitOf(modal.field);
    title = "调整" + modal.name + (unit ? "（" + unit + "）" : "");
    copy = "范围 " + modal.min + " 到 " + modal.max + "，步进 " + modal.step;
    buttons =
      '<button class="secondary" data-action="cancel-modal">取消</button><button class="primary" data-action="apply-number">应用</button>';
    return `<div class="overlay"><section class="dialog number-dialog" role="dialog" aria-modal="true" aria-label="${title}" tabindex="-1"><h2>${title}</h2><p>${copy}</p>${platform === "ios" ? valueWheel() : `<input class="numeric-field" id="number-field" type="number" value="${modal.value}" min="${modal.min}" max="${modal.max}" step="${modal.step}" aria-label="${modal.name}数值">`}<div class="actions">${buttons}</div></section></div>`;
  }
  return `<div class="overlay"><section class="dialog ${modal.kind}-dialog" role="dialog" aria-modal="true" aria-label="${title}" tabindex="-1"><h2>${title}</h2><p>${copy}</p><div class="actions">${buttons}</div></section></div>`;
}
function menuItems() {
  if (!menu) return [];
  if (menu.kind === "reset") {
    const items = [];
    if (tool === "hsl")
      items.push(
        [
          "reset-color",
          `重置当前颜色（${palettes[channel][0]}色）`,
          !hsl[channel].some((v) => v !== 0),
        ],
        ["reset-scope:hsl", "重置全部 HSL…"],
      );
    else if (group && tool)
      items.push(["reset-tool", "重置" + toolName(), !toolChanged(tool)]);
    if (group) items.push(["reset-scope:group", "重置" + groupName() + "组…"]);
    if (items.length) items.push(["-"]);
    items.push(["reset-scope:all", "重置全部调整…"]);
    return items;
  }
  if (menu.kind === "compare")
    return [0, 1, 2].map((m) => [
      "compare-set:" + m,
      compareNames[m],
      false,
      compareMode === m,
    ]);
  if (menu.kind.startsWith("win-"))
    return winMenus[menu.kind.slice(4)].map(([id, text, key, disabled]) => [
      id,
      text,
      id === "redo" ? !canRedo : disabled,
      id.startsWith("compare-set:")
        ? compareMode === Number(id.slice(12))
        : id === "photo-margin"
          ? photoMargin
          : undefined,
      key,
    ]);
  return [];
}
function menuHTML() {
  const items = menuItems();
  if (!items.length) return "";
  return `<div class="menu-popover" role="menu" data-menu-kind="${menu.kind}">${items
    .map(([id, text, disabled, checked, key]) =>
      id === "-"
        ? '<hr role="separator">'
        : `<button role="${checked === undefined ? "menuitem" : "menuitemradio"}" ${checked === undefined ? "" : `aria-checked="${checked}"`} data-menu-action="${id}" ${disabled ? "disabled" : ""}><span class="check">${checked ? icon("check") : ""}</span><span>${text}</span>${key ? `<kbd>${key}</kbd>` : ""}</button>`,
    )
    .join("")}</div>`;
}
function positionMenu() {
  const pop = document.querySelector(".menu-popover");
  if (!pop) return;
  const anchor = document.querySelector(`[data-menu-anchor="${menu.kind}"]`);
  const root = document.querySelector(".native-app").getBoundingClientRect();
  if (!anchor) return;
  const r = anchor.getBoundingClientRect();
  const w = pop.offsetWidth,
    h = pop.offsetHeight;
  let left = Math.min(r.left - root.left, root.width - w - 8);
  if (menu.kind === "reset" || menu.kind === "compare")
    left = Math.min(r.right - root.left - w, root.width - w - 8);
  let top = r.bottom - root.top + 4;
  if (top + h > root.height - 8) top = r.top - root.top - h - 4;
  pop.style.left = Math.max(8, left) + "px";
  pop.style.top = Math.max(8, top) + "px";
}
function updateControlAvailability() {
  const unavailable = [];
  if (tool === "denoise" && !denoiseEnabled)
    unavailable.push("denoiseLuma", "denoiseChroma", "denoiseCoarse");
  if (tool === "grain" && values.grain === 0)
    unavailable.push("grainSize", "grainRoughness");
  if (tool === "vignette") {
    if (values.vignette === 0)
      unavailable.push("vignetteMid", "vignetteRound", "vignetteFeather");
    if (values.vignette >= 0) unavailable.push("vignetteHigh");
  }
  document.querySelectorAll("[data-axis]").forEach((input) => {
    const off = unavailable.includes(input.dataset.axis);
    const row = input.closest(".axis");
    row.classList.toggle("unavailable", off);
    row
      .querySelectorAll("input,button")
      .forEach((control) => (control.disabled = off));
  });
  const apply = document.querySelector('[data-action="apply-draft"]');
  if (apply) apply.disabled = previewBusy || !isDraftChanged();
}
function setPreviewBusy(busy) {
  previewBusy = busy;
  const progress = document.querySelector(".preview-progress");
  if (progress) progress.hidden = !busy;
  const exportButton = document.querySelector("[data-action=export]");
  if (exportButton) exportButton.disabled = draft || scene === "empty" || busy;
  updateControlAvailability();
}
// 每次重绘都会替换 DOM，这里记住焦点所在控件，键盘操作不会被打断。
function focusKey(el) {
  if (!el || el === document.body) return null;
  for (const attr of [
    "data-axis",
    "data-inline-field",
    "data-number",
    "data-tool",
    "data-group",
    "data-channel",
    "data-menu-action",
    "data-flow-action",
    "data-flow-field",
    "data-flow",
    "data-action",
    "data-compare-mode",
    "data-crop-handle",
    "id",
  ])
    if (el.hasAttribute(attr)) return `[${attr}="${el.getAttribute(attr)}"]`;
  return null;
}
function render() {
  if (!canHoldBefore()) cancelBeforeHold();
  const swatches = document.querySelector(".swatches");
  if (swatches) swatchScrollLeft = swatches.scrollLeft;
  const keep = focusKey(document.activeElement);
  const nav = document.querySelector(".group-nav");
  if (nav) groupScrollLeft = nav.scrollLeft;
  app.innerHTML = `<div class="native-app ${immersive ? "immersive" : ""}">${desktopTitle()}${winMenubar()}${toolbar()}<div class="workspace">${filetree()}<div class="main-column">${canvas()}${dockVisible ? editor() : ""}</div></div>${mobile ? `<div class="mobilebar"><i></i>${platform === "android" ? "<i></i><i></i>" : ""}</div>` : `<div class="bottom-status"><span>${fileName()}</span><span>${zoomChoice} · sRGB</span></div>`}${updateWindow()}${modalHTML()}${RawLabDesignFlows.render(
    {
      platform,
      mobile,
      icon,
      axis,
      photoMarkup,
      repaint: render,
      gotoScene: setScene,
      notify: toast,
      setZoom: (value) => {
        zoomChoice = value;
      },
      setInfo: (value) => {
        infoState = value;
      },
      photoMargin: () => photoMargin,
      setMargin: (value) => {
        photoMargin = value;
      },
      requestResetAll: () => {
        requestReset("all");
      },
      toggleDock: () => {
        dockVisible = !dockVisible;
      },
      dockVisible: () => dockVisible,
      snapshot: () =>
        structuredClone({
          values,
          hsl,
          film: selectedFilm,
          whiteBalance: wbMode,
        }),
      lensChanged: () => {
        draftTouched = true;
        updateControlAvailability();
      },
    },
  )}${menuHTML()}${toastText ? '<div class="toast" role="status">' + toastText + "</div>" : ""}</div>`;
  document
    .querySelector('[data-action="export"]')
    ?.toggleAttribute("disabled", draft || scene === "empty" || previewBusy);
  if (scene === "empty")
    document
      .querySelectorAll(
        ".toolbar [data-action=compare],.toolbar [data-action=compare-menu],.toolbar [data-action=photo-info],.toolbar [data-action=zoom],.toolbar [data-action=toggle-dock],.toolbar [data-action=undo],.toolbar [data-action=redo]",
      )
      .forEach((button) => (button.disabled = true));
  const groupList = document.querySelector(".group-nav");
  if (groupList) groupList.scrollLeft = groupScrollLeft;
  const colorList = document.querySelector(".swatches");
  if (colorList) colorList.scrollLeft = swatchScrollLeft;
  document.querySelectorAll(".group-nav,.tool-tabs").forEach(updateNavFade);
  updateControlAvailability();
  positionMenu();
  const dialogOpen =
    !!modal || UPDATE_SCENES.includes(scene) || !!RawLabDesignFlows.active;
  document
    .querySelectorAll(
      ".toolbar,.win-menubar,.workspace,.mobilebar,.bottom-status",
    )
    .forEach((el) => (el.inert = dialogOpen));
  const restored = keep && document.querySelector(keep);
  if (modal?.kind === "number")
    setTimeout(() => {
      const field = document.querySelector("#number-field");
      field?.focus();
      if (field?.tagName === "SELECT") {
        const rowHeight = field.options[0].getBoundingClientRect().height;
        field.scrollTop =
          field.selectedIndex * rowHeight -
          (field.clientHeight - rowHeight) / 2;
      }
    }, 30);
  else if (restored && !restored.closest("[inert]")) restored.focus();
  else if (menu && keyboardUsed)
    document.querySelector(".menu-popover button:not(:disabled)")?.focus();
  else if (dialogOpen) {
    // 打开对话框时把焦点放在对话框本身，不预先落在关闭或破坏性按钮上。
    const dialog = document.querySelector("[role=dialog]");
    dialog?.setAttribute("tabindex", "-1");
    dialog?.focus({ preventScroll: true });
  }
}
function updateNavFade(nav) {
  nav.classList.toggle(
    "more-right",
    nav.scrollLeft + nav.clientWidth < nav.scrollWidth - 2,
  );
  nav.classList.toggle("more-left", nav.scrollLeft > 2);
}
// 只有用键盘打开菜单时才把焦点移到第一项，指针点开时不显示焦点框。
let keyboardUsed = false;
document.addEventListener("keydown", () => (keyboardUsed = true), true);
document.addEventListener("pointerdown", () => (keyboardUsed = false), true);
let toastTimer;
function toast(t) {
  toastText = t;
  render();
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toastText = "";
    render();
  }, 2400);
}
function navigate(nextGroup) {
  cancelBeforeHold();
  if (draft && isDraftChanged()) {
    modal = { kind: "leave", target: nextGroup };
    render();
    return;
  }
  draft = false;
  draftTouched = false;
  group = nextGroup;
  tool = group ? tools[group][0][0] : null;
  fineMode = false;
  if (group === "geometry") {
    draftBefore = { ...values };
    draft = true;
    tool = "geometry";
  }
  render();
}
function resetTool(id = tool) {
  if (id === "film") selectedFilm = neutralFilm;
  else if (id === "recipe") selectedRecipe = "";
  else if (id === "hsl") hsl = palettes.map(() => [0, 0, 0]);
  else if (id === "wb") {
    wbMode = "拍摄时设置";
    values.temperature = defaults.temperature;
    values.tint = defaults.tint;
  } else {
    if (id === "denoise") denoiseEnabled = false;
    (toolFields[id] || []).forEach((k) => (values[k] = defaults[k]));
  }
}
function requestReset(scope) {
  if (scope === "all" && draft && isDraftChanged()) {
    modal = { kind: "leave", afterReset: scope };
  } else {
    const resumeDraft = scope === "all" && draft;
    if (resumeDraft) draft = false;
    modal = { kind: "reset", scope, resumeDraft };
  }
  render();
}
function resumeResetDraft() {
  if (modal?.resumeDraft) {
    draft = true;
    draftBefore = { ...values };
    draftTouched = false;
  }
}
function resetConfirmed() {
  const scope = modal.scope;
  if (scope === "hsl") hsl = palettes.map(() => [0, 0, 0]);
  else if (scope === "group") tools[group].forEach(([id]) => resetTool(id));
  else {
    hsl = palettes.map(() => [0, 0, 0]);
    Object.assign(values, defaults);
    selectedFilm = neutralFilm;
    selectedRecipe = "";
    denoiseEnabled = false;
    wbMode = "拍摄时设置";
  }
  resumeResetDraft();
  modal = null;
  render();
}
function setCompare(mode) {
  cancelBeforeHold();
  compareMode = mode;
  if (mode) lastCompare = mode;
  holdingBefore = false;
}
function runAction(a, b) {
  if (a === "undo") {
    canRedo = true;
    toast("撤销 · 第二阶段规划入口，原型不回退参数");
  } else if (a === "redo") {
    canRedo = false;
    toast("重做 · 第二阶段规划入口，原型不回放参数");
  } else if (a === "planned") {
    toast("第二阶段规划，当前不可用");
  } else if (a === "reset-tool") {
    resetTool();
    render();
  } else if (a === "reset-all") {
    requestReset("all");
  } else if (a.startsWith("reset-scope:")) {
    requestReset(a.slice(12));
  } else if (a.startsWith("compare-set:")) {
    setCompare(Number(a.slice(12)));
    render();
  } else if (a === "reset-color") {
    hsl[channel] = [0, 0, 0];
    render();
  } else if (a === "settings" || a === "about") {
    RawLabDesignFlows.open(a);
    render();
  } else return false;
  return true;
}
app.addEventListener("click", (e) => {
  const menuItem = e.target.closest("[data-menu-action]");
  if (menuItem) {
    menu = null;
    handleAction(menuItem.dataset.menuAction, null);
    return;
  }
  const hadMenu = !!menu;
  if (menu && !e.target.closest(".menu-popover")) {
    const sameTrigger = e.target.closest(
      `[data-menu-anchor="${menu.kind}"] [data-action$="menu"], [data-menu-anchor="${menu.kind}"][data-action$="menu"]`,
    );
    menu = null;
    if (sameTrigger) {
      render();
      return;
    }
  }
  if (RawLabDesignFlows.handleClick(e)) return;
  const preset = e.target.closest("[data-denoise-preset]");
  if (preset) {
    const v = { detail: [0, 46, 50], clean: [10, 72, 100] }[
      preset.dataset.denoisePreset
    ];
    if (v) {
      [values.denoiseLuma, values.denoiseChroma, values.denoiseCoarse] = v;
      denoiseEnabled = true;
      render();
    }
    return;
  }
  const film = e.target.closest("[data-film]");
  if (film) {
    selectedFilm = film.dataset.film;
    selectedRecipe = "";
    render();
    return;
  }
  const recipe = e.target.closest("[data-recipe]");
  if (recipe) {
    selectedRecipe = recipe.dataset.recipe;
    render();
    return;
  }
  const g = e.target.closest("[data-group]");
  if (g) {
    // 再点一次当前分组即收起面板，把空间还给照片。
    navigate(g.dataset.group === group ? null : g.dataset.group);
    return;
  }
  const mode = e.target.closest("[data-compare-mode]");
  if (mode) {
    setCompare(Number(mode.dataset.compareMode));
    render();
    return;
  }
  const t = e.target.closest("[data-tool]");
  if (t) {
    if (draft && t.dataset.tool !== tool && isDraftChanged()) {
      modal = { kind: "leave", target: group, nextTool: t.dataset.tool };
      render();
      return;
    }
    tool = t.dataset.tool;
    fineMode = false;
    if (group === "geometry" && scene !== "raster") draft = true;
    render();
    return;
  }
  const c = e.target.closest("[data-channel]");
  if (c) {
    channel = Number(c.dataset.channel);
    render();
    return;
  }
  const number = e.target.closest("[data-number]");
  if (number) {
    let f = number.dataset.number;
    modal = {
      kind: "number",
      field: f,
      name: number.closest(".axis").querySelector(".axis-name").textContent,
      value: f.startsWith("hsl-")
        ? hsl[channel][Number(f.split("-")[1])]
        : values[f],
      min: number.dataset.min,
      max: number.dataset.max,
      step: number.dataset.step,
    };
    render();
    return;
  }
  const b = e.target.closest("[data-action]");
  if (!b) {
    // 只有确实关闭了菜单才重绘；否则会替换掉刚被点击的复选框标签。
    if (hadMenu) render();
    return;
  }
  handleAction(b.dataset.action, b);
});
function handleAction(a, b) {
  if (runAction(a, b)) return;
  if (a === "wheel-default") {
    document.querySelector("#number-field").value = defaults[modal.field] ?? 0;
  } else if (a === "reset-menu" || a === "compare-menu") {
    menu = { kind: a === "reset-menu" ? "reset" : "compare" };
    render();
  } else if (a === "win-menu") {
    menu = { kind: "win-" + b.dataset.menu };
    render();
  } else if (a === "fine") {
    fineMode = !fineMode;
    render();
  } else if (a === "confirm-reset") {
    resetConfirmed();
  } else if (a === "cancel-modal") {
    resumeResetDraft();
    modal = null;
    render();
  } else if (a === "apply-number") {
    const input = document.querySelector("#number-field");
    const parsed = parseParameter(
      input.value,
      Number(modal.min),
      Number(modal.max),
      Number(modal.step),
      modal.value,
    );
    if (parsed.error) {
      input.setCustomValidity(parsed.error);
      input.reportValidity();
      return;
    }
    if (!parsed.unchanged) commitParameter(modal.field, parsed.value);
    modal = null;
    render();
  } else if (a === "apply-leave" || a === "discard-leave") {
    if (a === "apply-leave" && previewBusy) return;
    const target = modal.target,
      next = modal.nextTool,
      afterFlow = modal.afterFlow,
      afterReset = modal.afterReset;
    if (a === "discard-leave") Object.assign(values, draftBefore);
    draft = false;
    draftTouched = false;
    if (afterReset) {
      modal = { kind: "reset", scope: afterReset, resumeDraft: true };
      render();
      return;
    }
    modal = null;
    group = target;
    tool = next || (group ? tools[group][0][0] : null);
    if (next && group === "geometry") {
      draft = true;
      draftBefore = { ...values };
      draftTouched = false;
    }
    if (afterFlow) RawLabDesignFlows.open(afterFlow);
    render();
  } else if (a === "apply-draft" || a === "discard-draft") {
    if (a === "discard-draft") Object.assign(values, draftBefore);
    draft = false;
    draftTouched = false;
    group = "light";
    tool = "exposure";
    render();
  } else if (a === "import") {
    if (draft && isDraftChanged()) {
      modal = { kind: "leave", target: null, afterFlow: "import" };
      render();
    } else {
      RawLabDesignFlows.open("import");
      render();
    }
  } else if (a === "retry-save") {
    scene = "hsl";
    toast("调整已保存");
  } else if (a === "goto-color") {
    group = "color";
    tool = "hsl";
    render();
  } else if (a === "photo") {
    if (draft) {
      modal = { kind: "leave", target: null };
      render();
    } else toast("设计示例：已选择照片");
  } else if (a === "compare") {
    setCompare(compareMode ? 0 : lastCompare);
    render();
  } else if (a === "export") {
    RawLabDesignFlows.open("export");
    render();
  } else if (a === "zoom") {
    RawLabDesignFlows.open("zoom");
    render();
  } else if (a === "close-update") {
    scene = "groups";
    group = null;
    tool = null;
    render();
  } else if (a === "skip-version") {
    scene = "groups";
    toast("已跳过 0.9.0（示例）；手动检查时仍可安装");
  } else if (a === "download-update" || a === "retry-update") {
    download = "downloading";
    render();
    setTimeout(() => {
      if (download !== "downloading") return;
      download = "ready";
      render();
    }, 2200);
  } else if (a === "cancel-download") {
    download = "available";
    render();
  } else if (a === "wait-update") {
    toast("已安排任务结束后安装 · 设计示例");
  } else if (a === "install-later") {
    toast("将在下次退出 RawLab 时安装 · 设计示例");
  } else if (a === "install-update") {
    toast("重启与安装流程 · 设计示例，不执行安装");
  } else if (a === "manual-download") {
    toast("发布页入口 · 设计示例，不打开网络");
  } else if (a === "lens-profile") {
    RawLabDesignFlows.open("lens-profile");
    render();
  } else if (a === "geometry-operation") {
    draftTouched = true;
    toast(b.getAttribute("aria-label") + " · 设计示例");
  } else if (a === "more") {
    RawLabDesignFlows.open("more");
    render();
  } else if (a === "sidebar") {
    sidebarVisible = !sidebarVisible;
    render();
  } else if (a === "toggle-dock") {
    dockVisible = !dockVisible;
    render();
  } else if (a === "photo-info") {
    infoState = { hide: "file", file: "capture", capture: "hide" }[infoState];
    render();
  } else if (a === "photo-margin") {
    photoMargin = !photoMargin;
    render();
  } else if (a === "histogram") {
    histogramVisible = !histogramVisible;
    render();
  } else if (a === "auto-exposure") {
    values.exposure = 0.45;
    render();
  } else if (a === "wb-mode") {
    wbMode = wbMode === "拍摄时设置" ? "自定义" : "拍摄时设置";
    if (wbMode === "拍摄时设置") {
      values.temperature = defaults.temperature;
      values.tint = defaults.tint;
    }
    render();
  } else render();
}
function syncAxis(input) {
  const f = input.dataset.axis,
    n = Number(input.value),
    min = Number(input.min),
    max = Number(input.max);
  const row = input.closest(".axis");
  input.setAttribute(
    "style",
    fillVars(n, f, min, max) +
      (input.classList.contains("gradient")
        ? ";--track-image:" + hslTrack(Number(f.slice(4)))
        : ""),
  );
  const ticks = row.querySelector(".ruler-ticks");
  if (ticks) ticks.innerHTML = ruler(n, min, max);
  const number = row.querySelector(".number");
  const text = displayValue(n, f, min);
  if (number.tagName === "INPUT") number.value = text;
  else number.textContent = text;
  number.classList.toggle("changed", n !== axisDefault(f));
}
app.addEventListener("input", (e) => {
  if (e.target.matches("#number-field,[data-inline-field]"))
    e.target.setCustomValidity("");
  if (e.target.matches("[data-compare-position]")) {
    comparePosition = Number(e.target.value);
    document
      .querySelector(".compare-stage")
      .style.setProperty("--split", comparePosition + "%");
    return;
  }
  const input = e.target;
  if (input.matches("[data-lens-search]")) {
    document
      .querySelectorAll(".lens-results .flow-row")
      .forEach(
        (row) =>
          (row.hidden =
            !!input.value && !row.textContent.includes(input.value)),
      );
    return;
  }
  if (input.dataset.axis) {
    const f = input.dataset.axis,
      n = Number(input.value);
    if (f.startsWith("hsl-")) hsl[channel][Number(f.split("-")[1])] = n;
    else {
      values[f] = n;
      if (["temperature", "tint"].includes(f)) {
        wbMode = "自定义";
        const button = document.querySelector("[data-action=wb-mode]");
        if (button) button.textContent = wbMode;
      }
      if (f.startsWith("crop")) {
        const frame = document.querySelector(".crop-frame");
        if (frame)
          frame.style.setProperty(
            f === "cropX"
              ? "left"
              : f === "cropY"
                ? "top"
                : f === "cropW"
                  ? "width"
                  : "height",
            n + "%",
          );
      }
    }
    syncAxis(input);
    updateControlAvailability();
  }
});
app.addEventListener("change", (e) => {
  if (e.target.matches("[data-histogram-visible]")) {
    histogramVisible = e.target.checked;
    return;
  }
  if (RawLabDesignFlows.handleChange(e)) return;
  // 拖动结束后再重绘，让分组与工具上的已调整小点同步。
  if (e.target.dataset.axis) {
    render();
    return;
  }
  if (e.target.matches("[data-crop-grid]")) {
    cropGrid = e.target.checked;
    render();
    return;
  }
  if (draft && e.target.closest(".lens-panel")) {
    draftTouched = true;
    updateControlAvailability();
  }
  if (e.target.id === "denoise-enabled") {
    denoiseEnabled = e.target.checked;
    render();
  }
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (menu) {
      menu = null;
      render();
      return;
    }
    if (RawLabDesignFlows.active) {
      if (!RawLabDesignFlows.busy) {
        RawLabDesignFlows.close();
        render();
      }
      return;
    }
    if (modal) {
      handleAction("cancel-modal");
    } else if (UPDATE_SCENES.includes(scene)) {
      scene = "groups";
      render();
    } else navigate(null);
  }
  if (
    !mobile &&
    (e.key === "i" || e.key === "I") &&
    !e.metaKey &&
    !e.ctrlKey &&
    !e.target.closest("input,select,textarea,[contenteditable]") &&
    !draft &&
    !menu &&
    !UPDATE_SCENES.includes(scene) &&
    !modal &&
    !RawLabDesignFlows.active
  )
    handleAction("photo-info");
  // Lightroom 同款：按住反斜杠查看调整前，松开恢复。
  if (
    e.key === "\\" &&
    !e.repeat &&
    !mobile &&
    !e.metaKey &&
    !e.ctrlKey &&
    !e.altKey &&
    canHoldBefore() &&
    !e.target.closest("input,select,textarea,[contenteditable]")
  ) {
    holdingBefore = true;
    render();
  }
});
document.addEventListener("keyup", (e) => {
  if (e.key === "\\" && holdingBefore) {
    cancelBeforeHold();
    render();
  }
});
window.addEventListener("message", (e) => {
  if (e.data?.type === "preview-progress") {
    setPreviewBusy(!!e.data.busy);
    return;
  }
  if (e.data?.type === "review-state") {
    large = !!e.data.largeText;
    document.body.classList.toggle("large-text", large);
    setScene(e.data.scene || "groups");
  }
});
large = params.get("largeText") === "true";
document.body.classList.toggle("large-text", large);
setScene(params.get("scene") || "groups");

app.addEventListener("keydown", (e) => {
  const handle = e.target.dataset?.cropHandle;
  if (handle && e.key.startsWith("Arrow")) {
    e.preventDefault();
    const dx = e.key === "ArrowLeft" ? -1 : e.key === "ArrowRight" ? 1 : 0;
    const dy = e.key === "ArrowUp" ? -1 : e.key === "ArrowDown" ? 1 : 0;
    moveCrop(handle, dx, dy);
    draftTouched = true;
    render();
    return;
  }
  const f = e.target.dataset.inlineField;
  if (!f) return;
  if (e.key === "Enter") {
    const parsed = parseParameter(
      e.target.value,
      Number(e.target.dataset.min),
      Number(e.target.dataset.max),
      Number(e.target.dataset.step),
      parameterValue(f),
    );
    if (parsed.error) {
      e.target.setCustomValidity(parsed.error);
      e.target.reportValidity();
      return;
    }
    if (!parsed.unchanged) commitParameter(f, parsed.value);
    render();
  }
  if (e.key === "Escape") {
    e.stopPropagation();
    render();
  }
});

document.addEventListener("keydown", (e) => {
  if (e.key !== "Tab") return;
  const d = document.querySelector("[role=dialog][aria-modal=true]");
  if (!d) return;
  const items = [
    ...d.querySelectorAll(
      "button:not(:disabled),input:not([type=hidden]),select,[tabindex='0']",
    ),
  ].filter((el) => el.offsetParent !== null);
  const first = items[0],
    last = items[items.length - 1];
  if (
    e.shiftKey &&
    (document.activeElement === first || document.activeElement === d)
  ) {
    last.focus();
    e.preventDefault();
  } else if (!e.shiftKey && document.activeElement === last) {
    first.focus();
    e.preventDefault();
  }
});

app.addEventListener("contextmenu", (e) => {
  if (e.target.closest(".filetree")) {
    e.preventDefault();
    RawLabDesignFlows.open("file-actions");
    render();
  } else if (e.target.closest("[data-action=compare]")) {
    // 移动端长按（桌面右键）选择对比方式，与 Windows 现有的对比菜单一致。
    e.preventDefault();
    menu = { kind: "compare" };
    render();
  }
});

app.addEventListener(
  "scroll",
  (e) => {
    if (e.target.matches?.(".group-nav,.tool-tabs")) {
      if (e.target.matches(".group-nav")) groupScrollLeft = e.target.scrollLeft;
      updateNavFade(e.target);
    }
  },
  true,
);

// 裁切框拖动：只在指针抬起时重绘，避免拖动过程中替换 DOM。
function moveCrop(handle, dx, dy) {
  let { cropX: x, cropY: y, cropW: w, cropH: h } = values;
  const min = 10;
  if (handle.includes("w")) {
    const nx = Math.min(Math.max(0, x + dx), x + w - min);
    w += x - nx;
    x = nx;
  }
  if (handle.includes("e")) w = Math.min(Math.max(min, w + dx), 100 - x);
  if (handle.includes("n")) {
    const ny = Math.min(Math.max(0, y + dy), y + h - min);
    h += y - ny;
    y = ny;
  }
  if (handle.includes("s")) h = Math.min(Math.max(min, h + dy), 100 - y);
  Object.assign(values, {
    cropX: Math.round(x * 10) / 10,
    cropY: Math.round(y * 10) / 10,
    cropW: Math.round(w * 10) / 10,
    cropH: Math.round(h * 10) / 10,
  });
}
function canHoldBefore() {
  return (
    scene !== "empty" &&
    !compareMode &&
    !draft &&
    !modal &&
    !menu &&
    !RawLabDesignFlows.active &&
    !UPDATE_SCENES.includes(scene)
  );
}
function cancelBeforeHold() {
  const pointerId = holdPointer?.id;
  clearTimeout(holdTimer);
  holdTimer = null;
  holdPointer = null;
  tapStart = null;
  const changed = holdingBefore;
  holdingBefore = false;
  if (pointerId != null && app.hasPointerCapture(pointerId))
    app.releasePointerCapture(pointerId);
  return changed;
}
function cancelPhotoGesture() {
  const pointers = [...activePointers];
  activePointers.clear();
  cropDrag = null;
  const changed = cancelBeforeHold();
  pointers.forEach((id) => {
    if (app.hasPointerCapture(id)) app.releasePointerCapture(id);
  });
  if (changed) render();
}
function capturePhotoPointer(e) {
  // 合成检查事件没有浏览器的活动指针，只有真实输入才能取得 capture。
  if (e.isTrusted) app.setPointerCapture(e.pointerId);
}
app.addEventListener("pointerdown", (e) => {
  if (e.button !== 0) return;
  activePointers.add(e.pointerId);
  if (activePointers.size > 1 || !e.isPrimary) {
    cropDrag = null;
    if (cancelBeforeHold()) render();
    return;
  }
  const handle = e.target.closest("[data-crop-handle]");
  if (handle) {
    e.preventDefault();
    cancelBeforeHold();
    const frame = handle.closest(".photo-frame").getBoundingClientRect();
    cropDrag = {
      pointerId: e.pointerId,
      handle: handle.dataset.cropHandle,
      frame,
      x: e.clientX,
      y: e.clientY,
    };
    capturePhotoPointer(e);
    return;
  }
  if (!canHoldBefore() || e.target.closest("button,input,select,textarea"))
    return;
  // 一个指针只判断一次；移动、缩放或第二指针到来后不能在同一手势重新触发。
  if (e.target.closest("[data-photo-frame]")) {
    holdPointer = { id: e.pointerId, x: e.clientX, y: e.clientY };
    capturePhotoPointer(e);
    holdTimer = setTimeout(() => {
      holdTimer = null;
      if (!holdPointer || !canHoldBefore()) return;
      holdingBefore = true;
      render();
    }, 180);
  }
  if (
    mobile &&
    e.target.closest(".canvas") &&
    !e.target.closest(".histogram,.compare-switch,.save-error")
  )
    tapStart = { id: e.pointerId, x: e.clientX, y: e.clientY, t: Date.now() };
});
document.addEventListener("pointermove", (e) => {
  if (
    holdPointer?.id === e.pointerId &&
    Math.hypot(e.clientX - holdPointer.x, e.clientY - holdPointer.y) >= 8
  ) {
    if (cancelBeforeHold()) render();
  }
  if (!cropDrag || cropDrag.pointerId !== e.pointerId) return;
  const dx = ((e.clientX - cropDrag.x) / cropDrag.frame.width) * 100;
  const dy = ((e.clientY - cropDrag.y) / cropDrag.frame.height) * 100;
  cropDrag.x = e.clientX;
  cropDrag.y = e.clientY;
  moveCrop(cropDrag.handle, dx, dy);
  const rect = {
    left: values.cropX,
    top: values.cropY,
    width: values.cropW,
    height: values.cropH,
  };
  document
    .querySelectorAll(".crop-frame,.crop-shade i")
    .forEach((el) =>
      Object.entries(rect).forEach(([k, v]) => (el.style[k] = v + "%")),
    );
});
document.addEventListener("pointerup", (e) => {
  activePointers.delete(e.pointerId);
  const tap =
    tapStart?.id === e.pointerId &&
    !holdingBefore &&
    Date.now() - tapStart.t < 300 &&
    Math.hypot(e.clientX - tapStart.x, e.clientY - tapStart.y) < 8;
  const held = cancelBeforeHold();
  const cropped = cropDrag?.pointerId === e.pointerId;
  if (cropped) {
    cropDrag = null;
    draftTouched = true;
  }
  if (tap) immersive = !immersive;
  if (tap || held || cropped) render();
});
document.addEventListener("pointercancel", cancelPhotoGesture);
app.addEventListener("lostpointercapture", cancelPhotoGesture);
window.addEventListener("blur", cancelPhotoGesture);
window.addEventListener("pagehide", cancelPhotoGesture);
document.addEventListener("visibilitychange", cancelPhotoGesture);
document.addEventListener(
  "wheel",
  (e) => {
    if (e.target.closest(".canvas")) cancelPhotoGesture();
  },
  { passive: true },
);

// 双击（移动端双点）参数名称或滑杆恢复该项默认值，替代每行的重置按钮。
app.addEventListener("dblclick", (e) => {
  const row = e.target.closest(".axis");
  if (
    !row ||
    e.target.closest(".number") ||
    row.classList.contains("unavailable")
  )
    return;
  const f = row.dataset.axisRow;
  if (f.startsWith("hsl-")) hsl[channel][Number(f.split("-")[1])] = 0;
  else values[f] = defaults[f];
  render();
});
