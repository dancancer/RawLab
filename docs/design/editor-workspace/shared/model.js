// Prototype-only fixtures and navigation; application contracts remain in their native sources.
window.RawLabDesign = {};
window.RawLabDesign.palettes = [
  ["红", "#eb625e"],
  ["橙", "#e89a51"],
  ["黄", "#e2ce55"],
  ["绿", "#72b771"],
  ["青", "#66c5bd"],
  ["蓝", "#719cdd"],
  ["紫", "#a38cde"],
  ["品红", "#cf83bb"],
];
window.RawLabDesign.groups = [
  ["looks", "外观", "film"],
  ["light", "光线", "sun"],
  ["color", "颜色", "color"],
  ["effects", "效果", "vignette"],
  ["detail", "细节", "detail"],
  ["geometry", "几何与镜头", "crop"],
];
window.RawLabDesign.tools = {
  looks: [
    ["film", "胶片"],
    ["recipe", "大师配方"],
    ["strength", "强度"],
  ],
  light: [
    ["exposure", "曝光"],
    ["highlights", "高光"],
    ["shadows", "阴影"],
    ["contrast", "对比度"],
    ["curve", "S 曲线"],
  ],
  color: [
    ["wb", "白平衡"],
    ["saturation", "饱和度"],
    ["hsl", "HSL 混色器"],
  ],
  effects: [
    ["vignette", "暗角"],
    ["grain", "颗粒"],
  ],
  detail: [
    ["denoise", "降噪"],
    ["sharpen", "锐化"],
  ],
  geometry: [
    ["geometry", "几何"],
    ["lens", "镜头校正"],
  ],
};
window.RawLabDesign.recipes = [
  {
    id: "hamada_daylight_v2",
    name: "滨田英明",
    subtitle: "日系青空 · 高调日光",
  },
  {
    id: "takashi_yasui_zen",
    name: "保井崇志",
    subtitle: "极简禅意 · 日系街拍",
  },
  {
    id: "takahiro_sakai_blue",
    name: "酒井贵弘",
    subtitle: "空气清透 · 少女淡蓝",
  },
  { id: "withluke_epic", name: "withluke", subtitle: "史诗自然 · 雾气冷青" },
  {
    id: "daniel_casson_autumn",
    name: "Daniel Casson",
    subtitle: "乡村秋日 · 古典油画",
  },
  {
    id: "billy_dinh_cinema",
    name: "Billy Dinh",
    subtitle: "纽约电影 · 戏剧光影",
  },
  { id: "rkrkrk_cyberpunk", name: "rkrkrk", subtitle: "赛博朋克 · 极致反差" },
  { id: "samalive_vintage", name: "Samalive", subtitle: "油润复古 · 城市胶片" },
  { id: "iwona_fairy_tale", name: "Iwona", subtitle: "童话油画 · 梦幻微光" },
  {
    id: "cinestill_800t",
    name: "CineStill 800T",
    subtitle: "钨丝电影 · 红灯冷青",
  },
  {
    id: "wilson_lee_golden",
    name: "Wilson Lee",
    subtitle: "暖调日系 · 漫射金光",
  },
  {
    id: "luizclas_portrait",
    name: "Luiz Clas",
    subtitle: "暖金光影 · 质感人像",
  },
  {
    id: "ivan_ivanchenko_twilight",
    name: "Ivan Ivanchenko",
    subtitle: "暮色黄昏 · 相邻色过渡",
  },
  { id: "jungraphy_neon", name: "Jungraphy", subtitle: "霓虹都市 · 冷青粉紫" },
];
window.RawLabDesign.fixture = {
  exposure: 0.35,
  highlights: -15,
  shadows: 10,
  contrast: 0,
  curve: 0,
  saturation: 0,
  strength: 100,
  vignette: 0,
  grain: 0,
  denoise: 0,
  sharpen: 0,
  temperature: 5600,
  tint: 0,
  straighten: 0,
  perspective: 0,
  horizontal: 0,
  cropX: 0,
  cropY: 0,
  cropW: 100,
  cropH: 100,
  grainSize: 25,
  grainRoughness: 50,
  vignetteMid: 50,
  vignetteRound: 0,
  vignetteFeather: 50,
  vignetteHigh: 0,
  denoiseLuma: 0,
  denoiseChroma: 46,
  denoiseCoarse: 50,
};
window.RawLabDesign.descriptions = {
  groups: [
    "分组栏（面板收起）",
    "六个分组常驻：手机在底部，横屏和平板在侧栏顶部，桌面在调整区顶部。未展开时只显示分组栏，照片获得最大空间。",
    [
      "点分组展开组内工具；再点当前分组收起",
      "已调整的分组在图标右上角显示小点，完整说明在可访问名称中",
      "横屏侧栏六组同时可见，不需要横向滑动",
    ],
  ],
  hsl: [
    "HSL 混色器",
    "颜色组内切换白平衡、饱和度与混色器。八个色域保持一行，三条轨道显示颜色变化方向。",
    [
      "点击色域切换，参数各自保留；已调整的色域下方有小点",
      "当前颜色与全部 HSL 的重置在右上角重置菜单中",
      "移动端一个面板只有一个“精细”开关，拖动灵敏度降为四分之一",
    ],
  ],
  light: [
    "光线参数",
    "分组栏保持可见，组内工具切换与参数调节在上方面板。页签上的小点表示该工具已调整。",
    [
      "仅显示已有曝光、高光、阴影、对比度、S 曲线",
      "滑杆填充从默认值画到当前值；未改动的数值为中性色",
      "白场、黑场、多点曲线待后续实现",
    ],
  ],
  draft: [
    "几何草稿与裁切框",
    "几何与镜头仍使用临时草稿。照片上的裁切框可直接拖动四角和四边，外部压暗；数值用于精确调整。离开时展示应用、放弃、继续编辑，导出等待草稿处理。",
    [
      "拖动角点或用方向键验证裁切框",
      "点其他分组验证退出确认，不把导航切换当作自动应用草稿",
    ],
  ],
  processing: [
    "处理中",
    "预览在后台更新时保留照片与当前参数，进度留在画面边缘。",
    ["不在照片中央叠加阻挡内容的加载窗", "保存与预览完成是不同状态"],
  ],
  "saving-error": [
    "调整未保存",
    "保留当前预览与参数，明确显示未保存及重试入口，不把预览完成当作保存成功。",
    ["错误留在照片边缘，不遮住照片中心", "点击重试仅演示状态恢复"],
  ],
  raster: [
    "普通图片限制",
    "普通图片继续使用可用调色工具，相机专属白平衡与镜头校正有清楚的不可用原因。",
    ["不伪造相机拍摄时白平衡", "保持参数分组位置一致"],
  ],
  empty: [
    "无照片",
    "保留清楚的照片导入入口，隐藏调整工具，避免空参数面板占据空间。",
    ["导入为设计状态切换，不打开系统文件"],
  ],
  update: [
    "有可用更新",
    "参照 Mac 上常见的 Sparkle 更新提示：版本、内嵌发布说明，以及“跳过此版本 / 稍后提醒 / 安装更新”。长期设置在“设置 → 软件更新”。",
    [
      "提示里只保留“以后自动下载并安装”一个勾选，初始关闭",
      "先保存调整、等待任务完成，再重启安装",
      "版本号、发布说明与下载进度为示例",
    ],
  ],
  "updating-wait": [
    "等待安全安装时机",
    "更新已经准备好，但当前仍有任务。等待任务完成，不强制结束导出或丢失调整。",
    ["显示阻挡安装的任务与进度", "可以延后安装并继续使用"],
  ],
  "update-error": [
    "失败与手动回退",
    "下载、校验或安装准备失败时保留当前可用版本，提供明确重试和手动下载入口。",
    ["不把打开发布页说成安装成功", "安装与回退的技术细节待方案确认"],
  ],
};

window.RawLabDesign.viewports = {
  ios: [
    [390, 844, "iPhone 390 × 844"],
    [1024, 768, "iPad 横屏 1024 × 768"],
    [844, 390, "iPhone 横屏 844 × 390"],
  ],
  android: [
    [412, 892, "手机 412 × 892"],
    [960, 640, "平板横屏 960 × 640"],
    [892, 412, "手机横屏 892 × 412"],
  ],
  macos: [
    [1280, 820, "标准窗口 1280 × 820"],
    [950, 620, "紧凑窗口 950 × 620"],
  ],
  windows: [
    [1280, 820, "标准窗口 1280 × 820"],
    [1024, 720, "紧凑窗口 1024 × 720"],
  ],
};

// Effective defaults for this illustrative RAW; camera WB uses its own per-photo baseline.
RawLabDesign.defaults = {
  ...RawLabDesign.fixture,
  exposure: 0,
  highlights: 0,
  shadows: 0,
};

// Card metadata mirrors the tracked native artwork/catalog; image pixels are not duplicated.
RawLabDesign.films = [
  {
    id: "provia",
    name: "PROVIA",
    artwork: "../../../RawLabMac/Resources/FilmIcons/provia.png",
    group: "Fujifilm",
  },
  {
    id: "velvia",
    name: "VELVIA",
    artwork: "../../../RawLabMac/Resources/FilmIcons/velvia.png",
    group: "Fujifilm",
  },
  {
    id: "astia",
    name: "ASTIA",
    artwork: "../../../RawLabMac/Resources/FilmIcons/astia.png",
    group: "Fujifilm",
  },
  {
    id: "acros",
    name: "ACROS",
    artwork: "../../../RawLabMac/Resources/FilmIcons/acros.png",
    group: "Fujifilm",
  },
  {
    id: "pro-neg-std",
    name: "PRO NEG.STD",
    artwork: "../../../RawLabMac/Resources/FilmIcons/pro-neg-std.png",
    group: "Fujifilm",
  },
  {
    id: "classic-neg",
    name: "CLASSIC NEG.",
    artwork: "../../../RawLabMac/Resources/FilmIcons/classic-neg.png",
    group: "Fujifilm",
  },
  {
    id: "eterna",
    name: "ETERNA",
    artwork: "../../../RawLabMac/Resources/FilmIcons/eterna.png",
    group: "Fujifilm",
  },
  {
    id: "eterna-bb",
    name: "ETERNA BB",
    artwork: "../../../RawLabMac/Resources/FilmIcons/eterna-bb.png",
    group: "Fujifilm",
  },
  {
    id: "classic-chrome",
    name: "CLASSIC CHROME",
    artwork: "../../../RawLabMac/Resources/FilmIcons/classic-chrome.png",
    group: "Fujifilm",
  },
  {
    id: "reala-ace",
    name: "REALA ACE",
    artwork: "../../../RawLabMac/Resources/FilmIcons/reala-ace.png",
    group: "Fujifilm",
  },
  {
    id: "EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65",
    name: "EKTAR 100 RawLab edition",
    artwork: "../../../RawLabMac/Resources/FilmIcons/ektar-100-phuket.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_camera_contax_nd_std_sRGB_v1",
    name: "Contax ND STD",
    artwork: "../../../Shared/BundledLooks/Artwork/camera-contax-nd-std.png",
    group: "相机风格",
  },
  {
    id: "RawLab_camera_lumix_s1r_vivid_sRGB_v1",
    name: "Lumix S1R Vivid",
    artwork: "../../../Shared/BundledLooks/Artwork/camera-lumix-s1r-vivid.png",
    group: "相机风格",
  },
  {
    id: "RawLab_camera_pentax_k5_reversal_sRGB_v1",
    name: "Pentax K-5 Reversal",
    artwork:
      "../../../Shared/BundledLooks/Artwork/camera-pentax-k5-reversal.png",
    group: "相机风格",
  },
  {
    id: "RawLab_camera_ricoh_gr2_hibw_sRGB_v1",
    name: "Ricoh GR II Hi-BW",
    artwork: "../../../Shared/BundledLooks/Artwork/camera-ricoh-gr2-hibw.png",
    group: "相机风格",
  },
  {
    id: "RawLab_camera_ricoh_gr2_vivid_sRGB_v1",
    name: "Ricoh GR II Vivid",
    artwork: "../../../Shared/BundledLooks/Artwork/camera-ricoh-gr2-vivid.png",
    group: "相机风格",
  },
  {
    id: "RawLab_look_2383_sRGB_v1",
    name: "Kodak 2383 RGB",
    artwork: "../../../Shared/BundledLooks/Artwork/look-2383.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_2393_sRGB_v1",
    name: "Kodak 2393 RGB",
    artwork: "../../../Shared/BundledLooks/Artwork/look-2393.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_bw_400_cn_sRGB_v1",
    name: "Kodak BW 400 CN",
    artwork: "../../../Shared/BundledLooks/Artwork/look-bw-400-cn.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_e100_gx_sRGB_v1",
    name: "Kodak E100 GX",
    artwork: "../../../Shared/BundledLooks/Artwork/look-e100-gx.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_ektachrome_100_vs_sRGB_v1",
    name: "Kodak Ektachrome 100 VS",
    artwork: "../../../Shared/BundledLooks/Artwork/look-ektachrome-100-vs.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_ektar_100_sRGB_v1",
    name: "Ektar 100 G'MIC",
    artwork: "../../../Shared/BundledLooks/Artwork/look-ektar-100.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_elite_100_xpro_sRGB_v1",
    name: "Kodak Elite 100 XPRO",
    artwork: "../../../Shared/BundledLooks/Artwork/look-elite-100-xpro.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_elite_chrome_200_sRGB_v1",
    name: "Kodak Elite Chrome 200",
    artwork: "../../../Shared/BundledLooks/Artwork/look-elite-chrome-200.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_elite_chrome_400_sRGB_v1",
    name: "Kodak Elite Chrome 400",
    artwork: "../../../Shared/BundledLooks/Artwork/look-elite-chrome-400.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_elite_color_200_sRGB_v1",
    name: "Kodak Elite Color 200",
    artwork: "../../../Shared/BundledLooks/Artwork/look-elite-color-200.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_elite_color_400_sRGB_v1",
    name: "Kodak Elite Color 400",
    artwork: "../../../Shared/BundledLooks/Artwork/look-elite-color-400.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_elite_extracolor_100_sRGB_v1",
    name: "Kodak Elite Extra 100",
    artwork:
      "../../../Shared/BundledLooks/Artwork/look-elite-extracolor-100.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_hie_sRGB_v1",
    name: "Kodak HIE Infrared",
    artwork: "../../../Shared/BundledLooks/Artwork/look-hie.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_kodachrome_200_sRGB_v1",
    name: "Kodak Kodachrome 200",
    artwork: "../../../Shared/BundledLooks/Artwork/look-kodachrome-200.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_kodachrome_25_sRGB_v1",
    name: "Kodak Kodachrome 25",
    artwork: "../../../Shared/BundledLooks/Artwork/look-kodachrome-25.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_kodachrome_64_sRGB_v1",
    name: "Kodak Kodachrome 64",
    artwork: "../../../Shared/BundledLooks/Artwork/look-kodachrome-64.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_portra_160_sRGB_v1",
    name: "Kodak Portra 160",
    artwork: "../../../Shared/BundledLooks/Artwork/look-portra-160.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_portra_400_sRGB_v1",
    name: "Kodak Portra 400",
    artwork: "../../../Shared/BundledLooks/Artwork/look-portra-400.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_portra_800_sRGB_v1",
    name: "Kodak Portra 800",
    artwork: "../../../Shared/BundledLooks/Artwork/look-portra-800.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_tmax_100_sRGB_v1",
    name: "Kodak T-MAX 100",
    artwork: "../../../Shared/BundledLooks/Artwork/look-tmax-100.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_tmax_400_sRGB_v1",
    name: "Kodak T-MAX 400",
    artwork: "../../../Shared/BundledLooks/Artwork/look-tmax-400.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_tmax_3200_sRGB_v1",
    name: "Kodak T-MAX 3200",
    artwork: "../../../Shared/BundledLooks/Artwork/look-tmax-3200.png",
    group: "Kodak / 创意",
  },
  {
    id: "RawLab_look_trix_400_sRGB_v1",
    name: "Kodak TRI-X 400",
    artwork: "../../../Shared/BundledLooks/Artwork/look-trix-400.png",
    group: "Kodak / 创意",
  },
];
