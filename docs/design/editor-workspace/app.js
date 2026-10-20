const { palettes, groups, tools } = RawLabDesign;
const params = new URLSearchParams(location.search);
const platform = params.get("platform") || "ios";
const mobile = ["ios", "android"].includes(platform);
const app = document.querySelector("#app");
document.body.classList.add(platform, mobile ? "mobile" : "desktop");
let scene = "groups",
  group = null,
  tool = null,
  channel = 3,
  draft = false,
  modal = null,
  toastText = "",
  download = "available",
  autoInstall = false,
  autoCheck = true,
  large = false;
let hsl = palettes.map(() => [0, 0, 0]);
hsl[3] = [-12, 18, 8];
let draftTouched = false;
let selectedFilm = "PROVIA",
  selectedRecipe = "",
  wbMode = "拍摄时设置",
  denoiseEnabled = false;
const recipes = RawLabDesign.recipes;
const values = { ...RawLabDesign.fixture };
const fineModes = {};
let groupScrollLeft = 0;
let previewBusy = false;
let compareMode = 0,
  comparePosition = 50,
  zoomChoice = "适合窗口",
  infoState = "file",
  histogramVisible = true,
  sidebarVisible = true,
  dockVisible = true;
function icon(name) {
  const entry = RawLabDesignIcons[name];
  if (!entry) throw new Error("Unknown design icon: " + name);
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${entry.path}"/></svg>`;
}
function btn(action, name, label, extra = "") {
  return `<button class="icon ${extra}" data-action="${action}" aria-label="${label}" title="${label}">${icon(name)}</button>`;
}
function fmt(n) {
  return Number(n) > 0 ? "+" + Number(n) : String(Number(n));
}
function groupName() {
  return groups.find((g) => g[0] === group)?.[1] || "调整";
}
const defaults = { ...RawLabDesign.defaults };
let draftBefore = { ...values };
function setScene(s) {
  RawLabDesignFlows.close();
  scene = s;
  previewBusy = s === "processing";
  dockVisible = true;
  compareMode = s === "compare" ? 1 : s === "compare-wipe" ? 2 : 0;
  if (s === "draft-confirm") s = "draft";
  if (s === "draft") {
    draftBefore = { ...values, straighten: 0 };
    values.straighten = 1.2;
  }
  modal = null;
  draft = s === "draft";
  group =
    s === "hsl" || s === "saving-error" || s === "processing"
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
  if (
    RawLabDesign.flowTitles[scene] &&
    !["compare", "compare-wipe", "draft-confirm", "update-ready"].includes(
      scene,
    )
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
function toolbar() {
  const next = ["并排对比", "拖动分割线", "关闭对比"][compareMode];
  return `<div class="toolbar">${!mobile ? btn("sidebar", "folder", "显示或隐藏文件树") : ""}${btn("import", "photo", "打开照片", mobile ? "yellow" : "")}<span class="brand">RawLab</span><span class="file">${scene === "raster" ? "瀑布.jpg" : "瀑布.ARW"}</span><span class="space"></span>${btn("compare", "compare", "对比：" + ["关闭", "并排", "拖动分割线"][compareMode] + "；点击切换为" + next, compareMode ? "yellow" : "")}${!mobile ? btn("photo-info", "info", "照片信息") + btn("zoom", "zoom", "缩放") : ""}${btn("toggle-dock", "settings", "显示或隐藏调整区", dockVisible ? "yellow" : "")}${btn("more", "more", "更多")}${btn("export", "share", "导出照片", draft ? "" : "yellow")}</div>`;
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
function histogram() {
  return `<div class="histogram ${histogramVisible ? "" : "collapsed"}"><button data-action="histogram" aria-label="${histogramVisible ? "收起" : "展开"}直方图">直方图 ${icon("chevron")}</button>${histogramVisible ? '<svg viewBox="0 0 130 48" aria-hidden="true"><path d="M0 48V42L8 38 16 20 24 9 32 21 40 34 48 39 56 42 64 41 72 37 80 35 88 28 96 29 104 24 112 22 120 36 130 43V48Z" fill="#d7d7dc"/></svg>' : ""}</div>`;
}
function comparisonMarkup() {
  const original = photoMarkup("compare-photo", "中性显影示意");
  const result = photoMarkup("compare-photo", "调整后示意");
  return `<div class="compare-stage ${compareMode === 1 ? "side-by-side" : "wipe"}" style="--split:${comparePosition}%"><div class="comparison-pane original">${original}<span>中性显影</span></div><div class="comparison-pane result">${result}<span>调整后</span></div>${compareMode === 2 ? `<div class="compare-divider" style="left:${comparePosition}%"><i>${icon("swap")}</i></div><input class="compare-position" type="range" min="0" max="100" value="${comparePosition}" data-compare-position aria-label="调整对比分割线">` : ""}</div><button class="compare-mode-label" data-action="compare" title="点击切换对比状态">${compareMode === 1 ? "并排对比" : "拖动分割线"}</button>`;
}
function canvas() {
  if (scene === "empty")
    return `<div class="canvas"><div class="empty-content"><div class="empty-icon">${icon("photo")}</div><h2>打开一张照片</h2><p>导入 RAW 或支持的普通图片，开始调整与比较。</p><button class="primary" data-action="import">打开照片</button></div></div>`;
  return `<div class="canvas">${compareMode ? comparisonMarkup() : photoMarkup()}${infoState !== "hide" ? `<div class="info">${infoState === "capture" ? "1/200 秒 · f/4 · ISO 200（示例）" : scene === "raster" ? "JPEG · sRGB" : "RAW · 拍摄时白平衡"}</div>` : ""}${histogram()}${!compareMode ? `<div class="photo-footer">${selectedFilm} · ${zoomChoice}</div>` : ""}${draft ? '<div class="crop-box"></div>' : ""}<div class="preview-progress" role="progressbar" aria-label="正在更新预览" ${previewBusy ? "" : "hidden"}><i></i></div>${scene === "saving-error" ? `<div class="save-error">${icon("warning")}<span>调整未保存</span><button data-action="retry-save">重试</button></div>` : ""}</div>`;
}
function groupMark(id) {
  const fields = {
    light: ["exposure", "highlights", "shadows", "contrast", "curve"],
    color: ["saturation", "temperature", "tint"],
    effects: [
      "vignette",
      "vignetteMid",
      "vignetteRound",
      "vignetteFeather",
      "vignetteHigh",
      "grain",
      "grainSize",
      "grainRoughness",
    ],
    detail: ["denoiseLuma", "denoiseChroma", "denoiseCoarse", "sharpen"],
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
  if (id === "looks")
    return selectedRecipe
      ? "已选大师配方"
      : selectedFilm !== "PROVIA"
        ? selectedFilm
        : values.strength !== 100
          ? "强度已调整"
          : "";
  const changed = (fields[id] || []).filter(
    (f) => values[f] !== defaults[f],
  ).length;
  if (id === "color") {
    const bands = hsl.filter((c) => c.some((v) => v !== 0)).length;
    return bands
      ? bands + " 个色域已调整"
      : changed
        ? changed + " 项已调整"
        : "";
  }
  return changed ? changed + " 项已调整" : "";
}
function groupPanel() {
  return `<div class="group-list">${groups.map(([id, name, g]) => `<button class="group" data-group="${id}" aria-label="${name}${groupMark(id) ? "，" + groupMark(id) : ""}"><span class="glyph">${icon(g)}</span><span class="name">${name}</span><span class="mark">${groupMark(id)}</span></button>`).join("")}</div><p class="group-caption">左右滑动选择调整组</p>`;
}
function tabs() {
  return `<div class="tool-tabs" aria-label="${groupName()}组内工具">${tools[group].map(([id, name]) => `<button data-tool="${id}" class="${tool === id ? "selected" : ""}" aria-pressed="${tool === id}">${name}</button>`).join("")}</div>`;
}
function displayValue(value, field, min) {
  if (field === "temperature") return value + " K";
  if (field === "exposure") return fmt(Number(value).toFixed(2)) + " EV";
  return (
    (min < 0 ? fmt(value) : Number(value)) +
    (field.startsWith("hsl-") ||
    ["straighten", "perspective", "horizontal"].includes(field)
      ? ""
      : "%")
  );
}
function rulerSVG(value, min, max) {
  const interval = (max - min) / 40;
  let marks = "";
  for (let i = -12; i <= 12; i++) {
    const v = (Math.round(value / interval) + i) * interval;
    if (v < min || v > max) continue;
    const x = 170 + ((v - value) / interval) * 15;
    const major =
      Math.abs(v / interval - Math.round(v / interval / 5) * 5) < 0.01;
    marks += `<path d="M${x} ${major ? 9 : 17}V31" stroke="#929299" stroke-width="1"/>`;
    if (major)
      marks += `<text x="${x}" y="8" text-anchor="middle" fill="#b6b6bd" font-size="8">${Number(v.toFixed(2))}</text>`;
  }
  return `<svg viewBox="0 0 340 33" preserveAspectRatio="none" aria-hidden="true">${marks}<path d="M170 4V32" stroke="#f2ce48" stroke-width="2"/></svg>`;
}
function axis(name, value, field, min = -100, max = 100, step = 0.1) {
  const text = displayValue(value, field, min);
  return `<div class="axis"><label><span>${name}</span><span class="axis-controls">${mobile ? `<button class="fine-mode ${fineModes[field] ? "yellow" : ""}" data-fine="${field}" aria-label="${name}精细调整" aria-pressed="${!!fineModes[field]}">精细</button>` : ""}${mobile ? `<button class="number" data-number="${field}" data-min="${min}" data-max="${max}" data-step="${step}">${text}</button>` : `<input class="number inline-number" aria-label="${name}数值" data-inline-field="${field}" data-min="${min}" data-max="${max}" data-step="${step}" value="${text}">`}<button class="axis-reset" data-reset-axis="${field}" aria-label="重置${name}" title="重置${name}">${icon("reset")}</button></span></label>${platform === "ios" ? `<div class="ruler-control"><div class="ruler-ticks">${rulerSVG(value, min, max)}</div><input aria-label="${name}" type="range" min="${min}" max="${max}" step="${step}" value="${value}" data-axis="${field}"></div>` : `<input aria-label="${name}" type="range" min="${min}" max="${max}" step="${step}" value="${value}" data-axis="${field}">`}<div class="range-labels"><span>${min}</span><span>${min < 0 && max > 0 ? "0" : ""}</span><span>${max}</span></div></div>`;
}
function hslPanel() {
  return `<div class="hsl-layout"><div class="channel-block"><div class="channel-title"><strong>${palettes[channel][0]}色</strong><span class="muted">${channel + 1} / 8</span></div><div class="swatches" aria-label="HSL 色域">${palettes.map(([name, color], i) => `<button class="swatch" data-channel="${i}" aria-label="${name}色" aria-pressed="${channel === i}"><i style="background:${color}"></i></button>`).join("")}</div><p class="channel-help">调整照片中的${palettes[channel][0]}色。切换色域时保留各自设置。</p><button class="reset-current" data-action="reset-color">重置当前颜色</button></div><div class="axes">${["色相", "饱和度", "明度"].map((name, i) => axis(name, hsl[channel][i], "hsl-" + i, -100, 100, platform === "windows" ? 0.1 : 1)).join("")}</div></div>`;
}
function scalarPanel() {
  if (scene === "wb-unavailable" && tool === "wb")
    return '<div class="scalar-layout"><p class="notice-inline"><strong>无法取得有效的相机白平衡校准</strong><br>保留拍摄时模式，暂不可手动调整色温与色调。</p><div class="flow-static"><span>色温 / 色调</span><span>不可用</span></div></div>';
  if (["denoise", "grain", "vignette"].includes(tool)) return complexPanel();
  if (tool === "wb")
    return `<div class="scalar-layout"><div class="scalar-meta"><span>白平衡</span><button data-action="wb-mode">${scene === "raster" ? "普通图片不提供相机白平衡" : wbMode + " " + icon("chevron")}</button></div>${scene === "raster" ? '<p class="notice-inline">RAW 专属：普通图片不提供拍摄时白平衡校准。</p>' : axis("色温", values.temperature, "temperature", 2000, 50000, 10) + axis("色调", values.tint, "tint", -150, 150, 0.1)}</div>`;
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
  return `<div class="scalar-layout">${axis(name, values[tool] || 0, tool, min, max, step)}<div class="scalar-meta"><span>${tool === "exposure" ? `曝光基准 <select aria-label="曝光基准" ${scene === "raster" ? "disabled" : ""}><option>匹配内嵌预览</option><option>标准显影</option><option>传感器基准</option></select> <button data-action="auto-exposure">自动</button>` : "默认值：" + (tool === "strength" ? "100" : "0")}</span><button data-action="reset-scalar">重置${name}</button></div></div>`;
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
      ["高光保护", "vignetteHigh", 0, 100],
    ];
  if (tool === "denoise") {
    extra = `${!mobile ? `<div class="parameter-options"><label>RAW 降噪<select aria-label="RAW 降噪" ${scene === "raster" ? "disabled" : ""}><option>停用</option><option>轻度</option><option>强度</option></select></label></div>` : ""}<div class="parameter-options"><label><input id="denoise-enabled" type="checkbox" ${denoiseEnabled ? "checked" : ""}>启用降噪</label><select aria-label="降噪预设" id="denoise-preset"><option>细节优先</option><option>去噪优先</option><option>自定义</option></select></div>`;
    fields = [
      ["亮度降噪", "denoiseLuma", 0, 100],
      ["色彩降噪", "denoiseChroma", 0, 100],
      ["粗色斑抑制", "denoiseCoarse", 0, 100],
    ];
  }
  return `<div class="multi-parameter">${extra}<div class="parameter-grid">${fields.map(([n, f, min, max]) => axis(n, values[f], f, min, max, 0.1)).join("")}</div>${tool === "denoise" ? '<p class="notice-inline">保留现有降噪参数。RAW 专属的 FBDD 在支持的照片上单独呈现。</p>' : ""}</div>`;
}
function geometryPanel() {
  if (tool === "lens" && scene === "raster")
    return `<div class="scalar-layout"><p class="notice-inline"><strong>镜头校正仅适用于 RAW 照片</strong><br>当前为普通图片，无法使用相机和镜头校准数据。其他颜色与效果调整仍可使用。</p><button class="secondary" data-action="goto-color" style="margin-top:15px">前往颜色调整</button></div>`;
  if (tool === "lens")
    return `<div class="lens-panel"><div class="parameter-options"><label>匹配模式<select aria-label="镜头匹配模式"><option>自动匹配</option><option>手动选择</option></select></label><span class="muted">已匹配当前照片镜头</span></div><div class="parameter-options">${["畸变校正", "横向色差校正", "自动裁切"].map((n, i) => `<label><input type="checkbox" ${i === 2 ? "checked" : ""}>${n}</label>`).join("")}</div><button class="secondary" data-action="lens-profile">选择镜头配置</button><p class="draft-info">草稿预览，应用后保存到当前照片。</p></div>`;
  return `<div class="geometry-panel"><div class="parameter-options"><div class="geometry-icons">${[
    ["rotate-left", "向左旋转"],
    ["rotate-right", "向右旋转"],
    ["flip-horizontal", "水平翻转"],
    ["flip-vertical", "垂直翻转"],
  ]
    .map(([name, label]) => btn("geometry-operation", name, label))
    .join(
      "",
    )}</div><label>比例<select aria-label="裁切比例"><option>原始比例</option><option>自由</option><option>1:1</option><option>4:3</option><option>3:2</option><option>16:9</option></select></label><label><input type="checkbox" checked>三分网格</label></div><div class="parameter-grid">${axis("拉直", values.straighten, "straighten", -45, 45, 0.01)}${axis("水平透视", values.horizontal, "horizontal", platform === "windows" ? -1 : -100, platform === "windows" ? 1 : 100, platform === "windows" ? 0.001 : 0.1)}${axis("垂直透视", values.perspective, "perspective", platform === "windows" ? -1 : -100, platform === "windows" ? 1 : 100, platform === "windows" ? 0.001 : 0.1)}</div><details><summary>精确裁切</summary><div class="parameter-grid">${[
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
    .join(
      "",
    )}</div></details><p class="draft-info">草稿预览，应用后保存到当前照片。</p></div>`;
}
function looksPanel() {
  if (tool === "strength") return scalarPanel();
  if (tool === "recipe")
    return `<div class="look-list recipe-list"><button class="look ${!selectedRecipe ? "active" : ""}" data-recipe=""><span>无配方</span></button>${recipes.map((r) => `<button class="look ${selectedRecipe === r.id ? "active" : ""}" data-recipe="${r.id}"><img src="${RawLabDesignManifest.media.recipeArtwork}${r.id}.png" alt=""><span>${r.name}</span><small>${r.subtitle}</small></button>`).join("")}</div>`;
  return `<div class="look-list film-list"><button class="look ${selectedFilm === "中性" ? "active" : ""}" data-film="中性">${icon("photo")}<span>中性</span></button>${RawLabDesign.films.map((f) => `<button class="look ${selectedFilm === f.name ? "active" : ""}" data-film="${f.name}" title="${f.group} · ${f.name}"><img src="${f.artwork}" alt=""><span>${f.name}</span></button>`).join("")}<button class="look" data-flow="looks">${icon("folder")}<span>导入与管理外观</span></button></div>`;
}
function editor() {
  if (scene === "empty") return "";
  const hslActive = tool === "hsl";
  return `<section class="editor"><header class="editor-header">${group ? `<button class="back" data-action="groups">${icon("back")}调整</button><span class="divider"></span>` : ""}<h2>${groupName()}</h2><span class="space"></span><span class="save">${draft ? "未应用草稿" : scene === "saving-error" ? "调整未保存" : scene === "processing" ? "" : "调整已保存"}</span><button class="quiet ${group ? "yellow" : ""}" data-action="reset-group">${group ? (hslActive ? "重置 HSL" : "重置本组") : "重置全部"}</button></header>${group ? tabs() : ""}${group ? `<div class="panel">${hslActive ? hslPanel() : group === "geometry" ? geometryPanel() : group === "looks" ? looksPanel() : scalarPanel()}</div>` : groupPanel()}${draft ? '<div class="draft-actions"><button class="secondary" data-action="discard-draft">取消</button><button class="primary" data-action="apply-draft" ' + (!(draftTouched || Object.keys(values).some((k) => values[k] !== draftBefore[k])) ? "disabled" : "") + ">应用</button></div>" : ""}</section>`;
}
function updateWindow() {
  if (!scene.startsWith("updat")) return "";
  let block =
    download === "waiting"
      ? [
          "等待当前任务完成",
          "正在批量导出 3 / 12 张。任务结束并保存调整后，再安装更新。",
        ]
      : download === "error"
        ? [
            "暂时无法准备更新",
            "下载文件未完成校验，当前版本仍可继续使用。请重试，或前往发布页手动下载。",
          ]
        : download === "ready"
          ? ["更新已准备好", "已保存当前调整。重启 RawLab 后安装更新。"]
          : download === "downloading"
            ? ["正在下载更新", "下载完成后会先校验文件，再准备安装。"]
            : ["有可用更新", "下一版本（示例） · 128 MB（示例）"];
  return `<div class="update-backdrop"></div><section class="update-window" role="dialog" aria-modal="true" aria-label="软件更新"><div class="update-title">软件更新 ${btn("close-update", "close", "关闭更新窗口")}</div><div class="update-body"><div class="update-icon">${icon("download")}</div><h2>保持 RawLab 为最新版本</h2><p>当前版本 0.8.2 · 更新信息为设计示例</p><div class="setting-row"><input id="autocheck" type="checkbox" ${autoCheck ? "checked" : ""}><label for="autocheck">自动检查更新<small>后台检查，不打断正在进行的编辑。</small></label></div><div class="setting-row"><input id="autoinstall" type="checkbox" ${autoInstall ? "checked" : ""}><label for="autoinstall">自动下载并安装更新<small>先保存调整并等待导出结束，在退出或重启时安装。</small></label></div><div class="update-state"><strong>${block[0]}</strong><p>${block[1]}</p>${download === "downloading" ? '<div class="progress"><i style="width:62%"></i></div><p>62% · 下载进度示例</p>' : ""}${download === "waiting" ? '<div class="progress"><i style="width:25%"></i></div>' : ""}</div><div class="update-actions"><button class="quiet" data-action="release-notes">发布说明</button><button class="secondary" data-action="close-update">稍后</button><button class="primary" data-action="${download === "error" ? "retry-update" : download === "waiting" ? "wait-update" : download === "ready" ? "install-update" : "download-update"}">${download === "error" ? "重试" : download === "waiting" ? "任务结束后安装" : download === "ready" ? "重启并安装" : download === "downloading" ? "取消下载" : "下载更新"}</button></div>${download === "error" ? '<button class="reset-current" data-action="manual-download">前往发布页手动下载</button>' : ""}</div></section>`;
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
  return `<select id="number-field" class="wheel-values" size="5" aria-label="${modal.name}临时选择">${sorted.map((n) => `<option value="${n}" ${n === Number(modal.value) ? "selected" : ""}>${n >= 0 && min < 0 ? "+" : ""}${n}</option>`).join("")}</select><button class="reset-current" data-action="wheel-default">恢复默认</button>`;
}
function modalHTML() {
  if (!modal) return "";
  let title = "",
    copy = "",
    buttons = "";
  if (modal.kind === "reset") {
    title =
      tool === "hsl"
        ? "重置全部 HSL？"
        : group
          ? "重置" + groupName() + "组？"
          : "重置全部调整？";
    copy =
      tool === "hsl"
        ? "八个色域的色相、饱和度和明度都会恢复为 0。其他调整保持不变。"
        : group
          ? "此操作只恢复" + groupName() + "组内的调整，其他分组保持不变。"
          : "恢复当前照片的全部调整，不改写原始照片。";
    buttons =
      '<button class="secondary" data-action="cancel-modal">取消</button><button class="primary" data-action="confirm-reset">重置</button>';
  } else if (modal.kind === "leave") {
    title = "应用当前草稿？";
    copy = "几何或镜头调整尚未应用。离开前请选择如何处理，原照片不会被改写。";
    buttons =
      '<div class="vertical-actions"><button class="primary" data-action="apply-leave">应用并离开</button><button class="secondary destructive" data-action="discard-leave">放弃修改</button><button class="secondary" data-action="cancel-modal">继续编辑</button></div>';
  } else if (modal.kind === "number") {
    title = "调整" + modal.name;
    copy = "范围 " + modal.min + " 到 " + modal.max + "，步进 " + modal.step;
    buttons =
      '<button class="secondary" data-action="cancel-modal">取消</button><button class="primary" data-action="apply-number">应用</button>';
    return `<div class="overlay"><section class="dialog number-dialog" role="dialog" aria-modal="true" aria-label="${title}"><h2>${title}</h2><p>${copy}</p>${platform === "ios" ? valueWheel() : `<input class="numeric-field" id="number-field" type="number" value="${modal.value}" min="${modal.min}" max="${modal.max}" step="${modal.step}" aria-label="${modal.name}数值">`}<div class="actions">${buttons}</div></section></div>`;
  }
  return `<div class="overlay"><section class="dialog" role="dialog" aria-modal="true" aria-label="${title}"><h2>${title}</h2><p>${copy}</p><div class="actions">${buttons}</div></section></div>`;
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
    input
      .closest(".axis")
      .querySelectorAll("input,button")
      .forEach(
        (control) =>
          (control.disabled = unavailable.includes(input.dataset.axis)),
      );
  });
  const apply = document.querySelector('[data-action="apply-draft"]');
  if (apply)
    apply.disabled =
      previewBusy ||
      !(
        draftTouched ||
        Object.keys(values).some((k) => values[k] !== draftBefore[k])
      );
}
function setPreviewBusy(busy) {
  previewBusy = busy;
  const progress = document.querySelector(".preview-progress");
  if (progress) progress.hidden = !busy;
  const exportButton = document.querySelector("[data-action=export]");
  if (exportButton) exportButton.disabled = draft || scene === "empty" || busy;
  updateControlAvailability();
}
function render() {
  app.innerHTML = `<div class="native-app">${desktopTitle()}${toolbar()}<div class="workspace">${filetree()}<div class="main-column">${canvas()}${dockVisible ? editor() : ""}</div></div>${mobile ? `<div class="mobilebar"><i></i>${platform === "android" ? "<i></i><i></i>" : ""}</div>` : '<div class="bottom-status"><span>瀑布.ARW</span><span>适合窗口 · sRGB</span></div>'}${updateWindow()}${modalHTML()}${RawLabDesignFlows.render(
    {
      platform,
      mobile,
      icon,
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
  )}${toastText ? '<div class="toast" role="status">' + toastText + "</div>" : ""}</div>`;
  document
    .querySelector('[data-action="export"]')
    ?.toggleAttribute("disabled", draft || scene === "empty" || previewBusy);
  if (scene === "empty")
    document
      .querySelectorAll(
        ".toolbar [data-action=compare],.toolbar [data-action=photo-info],.toolbar [data-action=zoom],.toolbar [data-action=toggle-dock]",
      )
      .forEach((button) => (button.disabled = true));
  const groupList = document.querySelector(".group-list");
  if (groupList) groupList.scrollLeft = groupScrollLeft;
  updateControlAvailability();
  const dialogOpen =
    !!modal || scene.startsWith("updat") || !!RawLabDesignFlows.active;
  document
    .querySelectorAll(".toolbar,.workspace,.mobilebar,.bottom-status")
    .forEach((el) => (el.inert = dialogOpen));
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
  else if (dialogOpen)
    setTimeout(
      () =>
        document.querySelector("[role=dialog] button:not(:disabled)")?.focus(),
      30,
    );
}
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
  if (
    draft &&
    (draftTouched ||
      Object.keys(values).some((k) => values[k] !== draftBefore[k]))
  ) {
    modal = { kind: "leave", target: nextGroup };
    render();
    return;
  }
  draft = false;
  draftTouched = false;
  group = nextGroup;
  tool = group ? tools[group][0][0] : null;
  if (group === "geometry") {
    draftBefore = { ...values };
    draft = true;
    tool = "geometry";
  }
  render();
}
function resetConfirmed() {
  if (tool === "hsl") hsl = palettes.map(() => [0, 0, 0]);
  else if (group === "light")
    Object.assign(values, {
      exposure: 0,
      highlights: 0,
      shadows: 0,
      contrast: 0,
      curve: 0,
    });
  else if (group === "color") {
    values.saturation = 0;
    values.temperature = defaults.temperature;
    values.tint = 0;
    wbMode = "拍摄时设置";
    hsl = palettes.map(() => [0, 0, 0]);
  } else if (group === "looks") {
    selectedFilm = "PROVIA";
    selectedRecipe = "";
    values.strength = 100;
  } else if (group === "geometry") {
    [
      "straighten",
      "perspective",
      "horizontal",
      "cropX",
      "cropY",
      "cropW",
      "cropH",
    ].forEach((k) => (values[k] = defaults[k]));
  } else if (group === "effects") {
    [
      "vignette",
      "vignetteMid",
      "vignetteRound",
      "vignetteFeather",
      "vignetteHigh",
      "grain",
      "grainSize",
      "grainRoughness",
    ].forEach((k) => (values[k] = defaults[k]));
  } else if (group === "detail") {
    denoiseEnabled = false;
    ["denoiseLuma", "denoiseChroma", "denoiseCoarse", "sharpen"].forEach(
      (k) => (values[k] = defaults[k]),
    );
  } else if (!group) {
    hsl = palettes.map(() => [0, 0, 0]);
    Object.assign(values, defaults);
    selectedFilm = "PROVIA";
    selectedRecipe = "";
    denoiseEnabled = false;
    wbMode = "拍摄时设置";
  }
  modal = null;
  render();
}
app.addEventListener("click", (e) => {
  if (RawLabDesignFlows.handleClick(e)) return;
  const fine = e.target.closest("[data-fine]");
  if (fine) {
    fineModes[fine.dataset.fine] = !fineModes[fine.dataset.fine];
    render();
    return;
  }
  const reset = e.target.closest("[data-reset-axis]");
  if (reset) {
    const f = reset.dataset.resetAxis;
    if (f.startsWith("hsl-")) hsl[channel][Number(f.split("-")[1])] = 0;
    else values[f] = defaults[f];
    render();
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
    navigate(g.dataset.group);
    return;
  }
  const t = e.target.closest("[data-tool]");
  if (t) {
    if (
      draft &&
      t.dataset.tool !== tool &&
      (draftTouched ||
        Object.keys(values).some((k) => values[k] !== draftBefore[k]))
    ) {
      modal = { kind: "leave", target: group, nextTool: t.dataset.tool };
      render();
      return;
    }
    tool = t.dataset.tool;
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
      name: number.closest(".axis").querySelector("label").firstChild
        .textContent,
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
  if (!b) return;
  const a = b.dataset.action;
  if (a === "wheel-default") {
    document.querySelector("#number-field").value = defaults[modal.field] ?? 0;
  } else if (a === "wheel-down" || a === "wheel-up") {
    modal.value = Number(
      Math.max(
        Number(modal.min),
        Math.min(
          Number(modal.max),
          Number(modal.value) +
            (a === "wheel-up" ? 1 : -1) * Number(modal.step),
        ),
      ).toFixed(3),
    );
    render();
  } else if (a === "groups") {
    navigate(null);
  } else if (a === "reset-group") {
    modal = { kind: "reset" };
    render();
  } else if (a === "reset-color") {
    hsl[channel] = [0, 0, 0];
    render();
  } else if (a === "confirm-reset") {
    resetConfirmed();
  } else if (a === "cancel-modal") {
    modal = null;
    render();
  } else if (a === "apply-number") {
    const input = document.querySelector("#number-field");
    let n = Number(input.value);
    if (!Number.isFinite(n) || n < Number(modal.min) || n > Number(modal.max)) {
      input.setCustomValidity("请输入范围内的数值");
      input.reportValidity();
      return;
    }
    if (modal.field.startsWith("hsl-"))
      hsl[channel][Number(modal.field.split("-")[1])] = n;
    else {
      values[modal.field] = n;
      if (["temperature", "tint"].includes(modal.field)) wbMode = "自定义";
    }
    modal = null;
    render();
  } else if (a === "apply-leave" || a === "discard-leave") {
    const target = modal.target,
      next = modal.nextTool,
      afterFlow = modal.afterFlow;
    if (a === "discard-leave") Object.assign(values, draftBefore);
    draft = false;
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
  } else if (a === "reset-scalar") {
    values[tool] = tool === "strength" ? 100 : 0;
    render();
  } else if (a === "import") {
    if (
      draft &&
      (draftTouched ||
        Object.keys(values).some((k) => values[k] !== draftBefore[k]))
    ) {
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
    compareMode = (compareMode + 1) % 3;
    render();
  } else if (a === "export") {
    RawLabDesignFlows.open("export");
    render();
  } else if (a === "zoom") {
    RawLabDesignFlows.open("zoom");
    render();
  } else if (a === "update") {
    scene = "update";
    download = "available";
    render();
  } else if (a === "close-update") {
    scene = "groups";
    group = null;
    tool = null;
    render();
  } else if (a === "download-update" || a === "retry-update") {
    if (download === "downloading") {
      download = "available";
      render();
    } else {
      download = "downloading";
      render();
      setTimeout(() => {
        download = "ready";
        render();
      }, 2200);
    }
  } else if (a === "wait-update") {
    toast("已安排任务结束后安装 · 设计示例");
  } else if (a === "install-update") {
    toast("重启与安装流程 · 设计示例，不执行安装");
  } else if (a === "manual-download" || a === "release-notes") {
    toast("发布页入口 · 设计示例，不打开网络");
  } else if (a === "choose-look") {
    toast("外观选择 · 本轮不模拟真实渲染");
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
    RawLabDesignFlows.open("photo-info");
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
  }
});
app.addEventListener("input", (e) => {
  if (e.target.matches("[data-compare-position]")) {
    comparePosition = Number(e.target.value);
    document
      .querySelector(".compare-stage")
      .style.setProperty("--split", comparePosition + "%");
    document.querySelector(".compare-divider").style.left =
      comparePosition + "%";
    return;
  }
  const input = e.target;
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
    }
    updateControlAvailability();
    const ticks = input
      .closest(".ruler-control")
      ?.querySelector(".ruler-ticks");
    if (ticks)
      ticks.innerHTML = rulerSVG(n, Number(input.min), Number(input.max));
    const number = input.closest(".axis").querySelector(".number");
    const text = displayValue(n, f, Number(input.min));
    if (number.tagName === "INPUT") number.value = text;
    else number.textContent = text;
  }
});
app.addEventListener("change", (e) => {
  if (e.target.matches("[data-histogram-visible]")) {
    histogramVisible = e.target.checked;
    return;
  }
  if (RawLabDesignFlows.handleChange(e)) return;
  if (draft && e.target.closest(".lens-panel")) {
    draftTouched = true;
    updateControlAvailability();
  }
  if (e.target.id === "denoise-enabled") {
    denoiseEnabled = e.target.checked;
    render();
  }
  if (e.target.id === "autocheck") autoCheck = e.target.checked;
  if (e.target.id === "autoinstall") autoInstall = e.target.checked;
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (RawLabDesignFlows.active) {
      if (!RawLabDesignFlows.busy) {
        RawLabDesignFlows.close();
        render();
      }
      return;
    }
    if (modal) {
      modal = null;
      render();
    } else if (scene.startsWith("updat")) {
      scene = "groups";
      render();
    } else navigate(null);
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
  const f = e.target.dataset.inlineField;
  if (!f) return;
  if (e.key === "Enter") {
    const n = parseFloat(e.target.value);
    if (
      Number.isFinite(n) &&
      n >= Number(e.target.dataset.min) &&
      n <= Number(e.target.dataset.max)
    ) {
      if (f.startsWith("hsl-")) hsl[channel][Number(f.split("-")[1])] = n;
      else values[f] = n;
      render();
    } else toast("请输入范围内的数值");
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
      "button:not(:disabled),input:not([type=hidden]),select",
    ),
  ].filter((el) => el.offsetParent !== null);
  const first = items[0],
    last = items[items.length - 1];
  if (e.shiftKey && document.activeElement === first) {
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
  }
});
app.addEventListener("input", (e) => {
  if (e.target.matches("[data-lens-search]"))
    document
      .querySelectorAll(".lens-results .flow-row")
      .forEach(
        (row) =>
          (row.hidden =
            !!e.target.value && !row.textContent.includes(e.target.value)),
      );
});

app.addEventListener(
  "scroll",
  (e) => {
    if (e.target.matches?.(".group-list"))
      groupScrollLeft = e.target.scrollLeft;
  },
  true,
);
