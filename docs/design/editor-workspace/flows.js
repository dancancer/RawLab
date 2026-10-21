// Prototype screens only: no application data, network, file writes or installation.
window.RawLabDesignFlows = (() => {
  let active = null,
    context = null,
    selected = new Set(),
    format = "JPEG",
    size = "native",
    destination = "照片图库",
    language = "简体中文",
    privacy = false,
    haptics = true,
    autoCheck = true,
    autoInstall = false,
    imported = false,
    removed = false,
    batchSnapshot = null,
    pickerReturn = "import",
    timer;
  const photos = [
    "瀑布.ARW",
    "山谷.ARW",
    "林间.ARW",
    "溪流.ARW",
    "晨光.ARW",
    "岩石.ARW",
  ];
  const titles = () => RawLabDesign.flowTitles;
  const action = (id, text, style = "secondary", disabled = false) =>
    `<button class="${style}" data-flow-action="${id}" ${disabled ? "disabled" : ""}>${text}</button>`;
  const link = (id, text, value = "") =>
    `<button class="flow-row" data-flow="${id}"><span>${text}</span><span class="muted">${value}${context.icon("next")}</span></button>`;
  const note = (text) => `<p class="flow-note">${text}</p>`;
  // 设置类的开 / 关统一使用开关组件；照片多选和“已核对”确认仍是勾选框。
  const toggle = (label, attrs, checked, hint = "") =>
    `<label class="flow-toggle"><span>${label}${hint ? `<small>${hint}</small>` : ""}</span><input type="checkbox" role="switch" class="switch" ${attrs} ${checked ? "checked" : ""}></label>`;
  // 第二阶段入口先占位并明确不可用，避免下一轮再改导航。
  const planned = (text) =>
    `<div class="flow-row planned" aria-disabled="true"><span>${text}<small>第二阶段规划，当前不可用</small></span><span class="tag">规划中</span></div>`;
  const error = (title, text) =>
    `<div class="flow-error">${context.icon("warning")}<div><strong>${title}</strong><p>${text}</p></div></div>`;
  function open(id, options = {}) {
    if (id === "system-picker" || id === "destination")
      pickerReturn = active || "import";
    if (id === "batch-select" && !active?.startsWith("batch-"))
      batchSnapshot = { settings: context?.snapshot() || null };
    clearTimeout(timer);
    active = id;
    if (options.seed) {
      if (id === "batch-select") selected = new Set();
      else if (id.startsWith("batch-") && !selected.size)
        selected = new Set([0, 1, 2]);
    }
    if (id === "export-running")
      timer = setTimeout(() => {
        active = "export-done";
        context.repaint();
      }, 4000);
    if (id === "batch-running")
      timer = setTimeout(() => {
        active = "batch-done";
        context.repaint();
      }, 6000);
  }
  function close() {
    clearTimeout(timer);
    active = null;
  }
  function selectionGrid(checks = true) {
    return `<div class="flow-photo-grid">${photos.map((name, i) => `<div class="flow-photo-item ${selected.has(i) ? "is-selected" : ""}"><button data-flow-photo="${i}" aria-label="${checks ? "选择" : "查看"}${name}">${context.photoMarkup("flow-thumbnail", name)}<span>${name}</span></button>${checks ? `<input type="checkbox" data-flow-select="${i}" aria-label="选择${name}" ${selected.has(i) ? "checked" : ""}>` : ""}</div>`).join("")}</div>`;
  }
  function sizeControls() {
    return `<label class="flow-field">导出尺寸<select data-flow-field="size"><option value="native" ${size === "native" ? "selected" : ""}>原始分辨率</option>${[2048, 3000, 4096].map((n) => `<option ${size == n ? "selected" : ""}>${n}</option>`).join("")}<option value="custom" ${size === "custom" ? "selected" : ""}>自定义长边</option></select></label>${size === "custom" ? '<label class="flow-field">长边像素<input type="number" min="1" max="65535" value="5000" aria-label="长边像素"></label>' : ""}<div class="flow-static"><span>输出像素</span><strong>${outputPixels()}（示例）</strong></div>`;
  }
  // 示例照片 7952 × 5304；按长边缩放，便于确认导出前的实际尺寸。
  function outputPixels() {
    const edge =
      size === "native" ? 7952 : size === "custom" ? 5000 : Number(size);
    return edge + " × " + Math.round((edge * 5304) / 7952);
  }
  function formatControls() {
    const choices =
      context.platform === "ios" ? ["JPEG", "DNG"] : ["JPEG", "PNG", "DNG"];
    return `<label class="flow-field">格式<select data-flow-field="format">${choices.map((n) => `<option ${format === n ? "selected" : ""}>${n === "DNG" ? "渲染型 DNG" : n === "PNG" ? "16-bit PNG" : n}</option>`).join("")}</select></label>${sizeControls()}${context.mobile ? (context.platform === "ios" ? `<div class="flow-static"><span>保存位置</span><strong>${format === "DNG" ? "文件" : "照片图库"}</strong></div>` : `<label class="flow-field">保存位置<select data-flow-field="destination"><option ${destination === "照片图库" ? "selected" : ""} ${format === "DNG" ? "disabled" : ""}>照片图库</option><option ${destination === "文件夹" || format === "DNG" ? "selected" : ""}>文件夹</option></select></label>`) : `<div class="flow-static"><span>输出文件夹</span><button class="quiet yellow" data-flow="destination">导出照片 ${context.icon("folder")}</button></div>`}${note(format === "DNG" ? "保存的是渲染后的外观，不是原始 RAW 或可逆编辑历史。" : "保留原始照片；重名输出自动加序号。")}`;
  }
  function sourceSummary() {
    if (!batchSnapshot) batchSnapshot = { settings: null };
    if (!batchSnapshot.settings) batchSnapshot.settings = context.snapshot();
    const frozen = batchSnapshot.settings;
    return `<section class="flow-summary"><h3>来源：瀑布.ARW</h3><p>${frozen.film} · ${frozen.values.strength}% · 曝光 ${frozen.values.exposure >= 0 ? "+" : ""}${frozen.values.exposure.toFixed(2)} EV</p><details><summary>全部调整</summary><dl><dt>白平衡</dt><dd>${frozen.whiteBalance === "拍摄时设置" ? "拍摄时设置，按目标逐张解析" : "自定义：" + frozen.values.temperature + " K / " + frozen.values.tint}</dd><dt>高光 / 阴影</dt><dd>${frozen.values.highlights} / ${frozen.values.shadows}</dd><dt>HSL</dt><dd>绿色：${frozen.hsl[3].join(" / ")}</dd><dt>几何 / 镜头</dt><dd>使用冻结的当前设置</dd></dl></details></section>`;
  }
  function batchRows(state) {
    const list = [...selected];
    return `<div class="flow-job-list">${list
      .map((i, index) => {
        const status =
          state === "batch-done"
            ? "已完成"
            : state === "batch-partial" && index === list.length - 1
              ? "失败：无法写入输出位置"
              : state === "batch-running"
                ? index === 0
                  ? "已完成"
                  : index === 1
                    ? "处理中"
                    : "等待中"
                : state === "batch-cancelled"
                  ? index === 0
                    ? "已完成"
                    : "未处理"
                  : state === "batch-interrupted"
                    ? "未完成"
                    : "等待处理";
        return `<div class="flow-job-row">${context.photoMarkup("job-thumbnail", photos[i])}<div><strong>${photos[i]}</strong><span class="${status.startsWith("失败") ? "error-text" : ""}">${status}</span></div>${status.startsWith("失败") ? context.icon("warning") : status === "已完成" ? context.icon("check") : ""}</div>`;
      })
      .join("")}</div>`;
  }
  function content() {
    const p = context.platform;
    let body = "",
      footer = "",
      sub = "";
    if (active === "more") {
      body =
        link("import", "打开照片") +
        link("looks", "外观资源") +
        link("export", "导出") +
        link("histogram", "直方图与裁切提示") +
        link("photo-info", "照片信息") +
        link("settings", p === "ios" ? "语言、触觉与隐私" : "设置") +
        (p === "android"
          ? link("library", "相册") + link("licenses", "开源许可")
          : "") +
        (p === "ios" ? "" : link("about", "关于 RawLab")) +
        (context.mobile
          ? `<button class="flow-row" data-flow-action="toggle-dock"><span>${context.dockVisible() ? "隐藏调整面板" : "显示调整面板"}</span></button><button class="flow-row" data-flow-action="reset-all"><span>重置全部调整…</span></button>`
          : "") +
        `<h3>调整复用</h3>${planned("复制调整")}${planned("粘贴调整")}`;
    } else if (active === "import") {
      body = `<p class="flow-lead">打开 RAW 或支持的普通图片</p>${p === "ios" ? link("system-picker", "从照片图库选择") + link("system-picker", "从文件选择") : p === "android" ? link("library", "从相册选择") + link("system-picker", "从文件选择") : link("system-picker", "选择照片文件") + link("destination", "添加照片文件夹")}${note("继续前保存当前照片的调整。原始文件保持只读。")}`;
    } else if (active === "system-picker") {
      body = `<div class="system-handoff">${context.icon("photo")}<h3>${context.mobile ? "系统照片 / 文件选择器" : "系统打开文件对话框"}</h3><p>此界面由操作系统提供。设计资产记录打开、取消和返回结果的集成点。</p></div>`;
      footer =
        action("close", "取消") +
        action("import-selected", "使用示例照片", "primary");
    } else if (active === "import-error" || active === "preview-error") {
      body = error(
        active === "import-error" ? "无法打开这张照片" : "暂时无法生成预览",
        "文件不可读或格式不受支持。保留当前照片和调整，可以重试或重新选择。",
      );
      footer =
        action("close", "保留当前照片") +
        action("retry-import", "重新选择", "primary");
    } else if (active === "permission") {
      body =
        error(
          "需要照片访问权限",
          "允许访问后才能读取所选照片；也可以从文件选择。",
        ) +
        link("library", "选择可访问的照片") +
        link("system-picker", "从文件选择");
      footer =
        action("close", "稍后") +
        action("grant-permission", "前往系统设置", "primary");
    } else if (active === "permission-limited") {
      body =
        error(
          "仅可访问你选择的照片",
          "可以继续编辑已授权的照片，或在系统设置中管理照片访问范围。",
        ) + selectionGrid(false);
      footer = action("grant-permission", "管理授权", "primary");
    } else if (active === "library") {
      sub = p === "android" ? "相册" : "照片文件夹";
      body = `${p === "android" ? `<div class="flow-form-inline"><label>相册<select><option>全部照片</option><option>旅行照片</option></select></label><label>列数<select data-album-columns>${[1, 2, 3, 4, 5, 6].map((n) => `<option ${n === 3 ? "selected" : ""}>${n}</option>`).join("")}</select></label><label class="switch-inline">方形缩略图<input type="checkbox" role="switch" class="switch" checked data-album-aspect></label></div>` : `<div class="flow-form-inline">${action("folder-add", "添加目录")}${action("folder-refresh", "重新读取")}<span class="muted">旅行照片 / 瀑布</span></div>`}${selectionGrid(false)}`;
      footer = action("close", "返回编辑");
    } else if (active === "file-actions") {
      body = `<div class="flow-static"><strong>瀑布.ARW</strong><span>当前文件</span></div>${link("photo-info", "照片信息")}${link("apply-settings", "应用当前完整设置")}${link("destination", p === "macos" ? "在 Finder 中显示" : "在资源管理器中显示")}${link("folder-error", "目录无法读取时的重试")}${link("folder-remove", "移除照片目录")}`;
    } else if (active === "apply-settings") {
      body = `<p class="flow-lead">应用到 3 张照片？</p>${sourceSummary()}${note("替换所选照片本机保存的完整调整，不改写原始照片。这是已有的完整设置应用，不是后续按项复制粘贴。")}`;
      footer =
        action("close", "取消") +
        action("apply-complete-settings", "应用并保存", "primary");
    } else if (active === "folder-error" || active === "folder-remove") {
      body =
        active === "folder-error"
          ? error(
              "无法读取目录",
              "目录已移动或权限失效。重新选择目录后再读取。",
            )
          : note("仅从照片文件夹列表中移除，不删除磁盘中的原始文件。");
      footer =
        action("close", "取消") +
        action(
          "folder-add",
          active === "folder-error" ? "重新选择" : "移除目录",
          "primary",
        );
    } else if (active === "destination") {
      body = `<div class="system-handoff">${context.icon("folder")}<h3>系统文件位置选择器</h3><p>由平台选择输出文件夹或保存文件，检查可写权限与扩展名，保留原始照片。</p></div>`;
      footer =
        action("return-export", "取消") +
        action("destination-selected", "使用此位置", "primary");
    } else if (active === "zoom") {
      body = `${["适合窗口", "100% 实际像素", "放大", "缩小"].map((n) => `<button class="flow-row" data-zoom-choice="${n}">${n}</button>`).join("")}${toggle("照片四周留白", 'data-flow-field="photo-margin"', context.photoMargin(), "关闭后照片贴边显示，尽量占满预览区")}`;
    } else if (active === "histogram") {
      body = `<div class="system-handoff">${context.icon("sun")}<h3>直方图与裁切提示</h3><p>亮度 / RGB、展开 / 收起与高光/阴影裁切提示只改变查看状态。</p></div>${toggle("显示直方图", "data-histogram-visible", true)}${toggle("显示裁切提示", "data-clipping-visible", false)}`;
    } else if (active === "looks") {
      body = `<div class="flow-form-inline">${action("look-import", "导入外观", "primary")}</div><h3>内置外观</h3><p>胶片与 14 个大师配方仍在外观组内选择。</p><h3>已导入</h3>${removed ? note("尚无导入的外观。") : `<div class="flow-row"><span>自定义外观.cube<small>本机外观 · 33³（示例）</small></span>${p === "ios" ? action("look-use", "使用") : `<span>${action("look-use", "使用")}${["android", "macos"].includes(p) ? action("look-rename", "重命名") + action("look-delete", "删除") : ""}</span>`}</div>`}${imported ? note("1 个外观已导入，可在胶片列表选择。") : ""}`;
    } else if (active === "look-import") {
      body = `<p class="flow-lead">导入 .cube、.rlook 或 .dcp</p>${note("从文件选择一项或多项。先校验格式、数据与外观引用，逐项报告导入结果。")}${link("system-picker", "选择外观文件")}`;
      footer =
        action("back-looks", "取消") +
        action("look-import-complete", "使用示例导入结果", "primary");
    } else if (active === "look-error") {
      body = error(
        "1 个外观无法导入",
        "无效外观.cube：LUT 数据与声明的尺寸不一致。其余可用外观保持不变。",
      );
      footer =
        action("back-looks", "查看外观") +
        action("look-import", "重新选择", "primary");
    } else if (active === "look-delete" || active === "look-rename") {
      body =
        active === "look-delete"
          ? note(
              "删除“自定义外观.cube”？引用它的照片调整会保留记录，并提示外观缺失。",
            )
          : '<label class="flow-field">外观名称<input data-look-name value="自定义外观"></label>';
      footer =
        action("back-looks", "取消") +
        action(
          active === "look-delete" ? "look-remove" : "look-save-name",
          active === "look-delete" ? "删除外观" : "保存",
          "primary",
        );
    } else if (active === "look-missing") {
      body = error(
        "照片使用的外观不可用",
        "保留原有调整记录。请重新导入外观或明确选择另一外观，修复前不能使用不完整设置导出。",
      );
      footer = action("look-import", "重新导入", "primary");
    } else if (active === "export") {
      body =
        link("export-options", "导出当前照片") +
        link("batch-select", "使用当前调整批量导出") +
        link("batch-interrupted", "查看未完成的批量任务");
    } else if (active === "export-options") {
      body = `<div class="flow-static"><span>照片</span><strong>瀑布.ARW</strong></div>${formatControls()}`;
      footer =
        action("close", "取消") + action("start-export", "导出照片", "primary");
    } else if (active === "export-running") {
      body = `<p class="flow-lead">正在导出瀑布.ARW</p><div class="flow-job-progress"><i style="width:62%"></i></div>${note("渲染完成后还需保存到目标位置；此时尚不能报告导出成功。")}`;
    } else if (active === "export-done") {
      body = `<div class="flow-result">${context.icon("check")}<h3>照片已导出</h3><p>${format === "DNG" ? "渲染型 DNG · 文件" : format + " · " + (context.mobile ? "照片图库" : "导出照片文件夹")}</p></div>`;
      footer = action("close", "完成", "primary");
    } else if (active === "export-error") {
      body = error(
        "照片未能保存",
        "输出位置不可写。当前调整仍保留，可以重新选择位置后导出。",
      );
      footer =
        action("close", "返回编辑") +
        action("return-export", "重新选择输出", "primary");
    } else if (active === "batch-select") {
      body = `${sourceSummary()}<div class="flow-form-inline">${action("select-all", "全选")}${action("select-none", "全不选")}<span>已选 ${selected.size} 张</span></div>${selectionGrid()}${context.mobile ? link("system-picker", "从文件添加") : action("folder-add", "添加照片文件")}`;
      footer =
        action("close", "取消") +
        action(
          "batch-next",
          "下一步（" + selected.size + "）",
          "primary",
          !selected.size,
        );
    } else if (active === "batch-confirm") {
      body = `<div class="batch-layout"><section class="batch-targets"><div class="flow-section-title"><h3>${selected.size} 张目标照片</h3>${action("batch-edit-selection", "更改")}</div>${[...selected].map((i) => `<div class="flow-job-row">${context.photoMarkup("job-thumbnail", photos[i])}<button class="flow-link" data-inspect-target="${i}">${photos[i]}<small>查看效果</small></button><button class="icon remove-target" data-remove-target="${i}" aria-label="移除${photos[i]}">${context.icon("close")}</button></div>`).join("")}</section><section class="batch-output">${sourceSummary()}${formatControls()}</section></div>${note("仅用于本次导出，保留各照片原有调整；每张照片使用自己的拍摄元数据。")}`;
      // 桌面窗口保留“取消”结束整个流程；移动端由标题栏返回与系统手势处理。
      footer =
        (context.mobile ? "" : action("close", "取消")) +
        action(
          "start-batch",
          "导出 " + selected.size + " 张",
          "primary",
          !selected.size,
        );
    } else if (active === "batch-inspect") {
      body = `<div class="inspect-photo">${context.photoMarkup("inspect-image")}</div>${note("只检查所选目标使用冻结设置后的效果；这里不提供逐张调整，也不改变来源和目标记录。")}`;
      footer = action("return-confirm", "返回确认", "primary");
    } else if (active === "batch-uncertain") {
      body =
        error(
          "部分保存结果尚未确认",
          "照片图库可能已经保存，但应用没有收到确定结果。先核对图库，避免重复生成。",
        ) +
        batchRows("batch-interrupted") +
        '<label class="flow-toggle"><span>我已核对保存结果</span><input type="checkbox" data-result-checked></label>';
      footer =
        action("close", "稍后核对") +
        action("confirm-save-result", "确认并继续", "primary", true);
    } else if (active === "batch-save-files") {
      body =
        note(
          "渲染完成的 DNG 尚需保存到文件位置。文件保存成功后才能标记为完成。",
        ) + batchRows("batch-interrupted");
      footer =
        action("close", "稍后") +
        action("save-dng-files", "保存到文件", "primary");
    } else if (active === "discard-confirm") {
      body = note(
        "放弃未完成任务？已保存的输出保留，未处理项不再继续，原始照片与调整记录不受影响。",
      );
      footer =
        action("resume-choice", "继续查看") +
        action("discard-confirmed", "放弃任务", "primary");
    } else if (active.startsWith("batch-")) {
      const heading = {
        "batch-running": "正在导出",
        "batch-stopping": "正在停止",
        "batch-done": "全部导出完成",
        "batch-partial": "部分照片未导出",
        "batch-cancelled": "导出已取消",
        "batch-interrupted": "发现未完成任务",
        "batch-permission": "需要恢复输出权限",
      }[active];
      body = `<h3>${heading}</h3>${["batch-running", "batch-stopping"].includes(active) ? `<div class="flow-job-progress"><i style="width:${active === "batch-running" ? 38 : 46}%"></i></div>` : ""}${active === "batch-running" ? note("已完成 1 / " + selected.size + " 张 · 当前：山谷.ARW") : ""}${active === "batch-interrupted" ? note("继续使用上次冻结的来源设置，不读取之后的编辑；已成功的照片不会重复导出。") : ""}${active === "batch-permission" ? error("无法访问输出位置", "重新授权文件夹后继续，或选择新的输出位置。") : ""}${batchRows(active)}`;
      if (active === "batch-running")
        footer = action("cancel-batch", "取消导出");
      else if (active === "batch-stopping")
        footer = action("wait-stop", "等待当前阶段结束", "secondary", true);
      else if (active === "batch-partial")
        footer =
          action("close", "关闭") +
          action("retry-batch", "重试失败项", "primary");
      else if (active === "batch-cancelled" || active === "batch-interrupted")
        footer =
          action("discard-batch", "放弃任务") +
          action("resume-batch", "继续未处理项", "primary");
      else if (active === "batch-permission")
        footer =
          action("close", "稍后") +
          action("reauthorize", "重新授权", "primary");
      else
        footer =
          action(
            "open-results",
            context.mobile ? "查看保存结果" : "打开输出文件夹",
          ) + action("close", "完成", "primary");
    } else if (active === "settings") {
      body =
        link("language", "语言", language) +
        (p === "ios" || p === "android"
          ? link("haptics", "触觉反馈", haptics ? "开启" : "关闭")
          : "") +
        (["android", "windows"].includes(p)
          ? `<label class="flow-field">渲染加速<select><option>GPU Auto</option>${p === "windows" ? "<option>仅 CPU</option><option>强制 GPU</option>" : "<option>关闭 GPU</option>"}</select></label>`
          : "") +
        link("privacy", "隐私与使用统计") +
        (p === "ios" ? "" : link("about", "关于 RawLab")) +
        (p === "android" ? link("licenses", "开源许可") : "") +
        (!context.mobile ? link("update-settings", "软件更新") : "");
    } else if (active === "language") {
      body = `<label class="flow-field">界面语言<select data-flow-field="language">${["简体中文", "English", "Deutsch", "Français", "Español", "日本語"].map((n) => `<option ${n === language ? "selected" : ""}>${n}</option>`).join("")}</select></label>${note("外观、胶片和作者专有名称保持原名。")}`;
      footer = action("back-settings", "完成", "primary");
    } else if (active === "haptics") {
      body = `${toggle("调整时的触觉反馈", 'data-flow-field="haptics"', haptics)}${note("原型不产生真实设备触觉。")}`;
    } else if (active === "privacy") {
      body = `${toggle("允许使用统计", 'data-flow-field="privacy"', privacy)}<p>开启后，由阿里云处理功能使用次数，数据存储在中国大陆。SDK 可能采集设备标识、设备与系统信息、网络/IP、地区及会话信息。</p><p>不采集照片、预览、文件名、路径、EXIF 或 AI 内容。关闭后停止新采集，已发出的请求无法撤回。</p>${link("privacy-policy", "隐私政策")}`;
      footer = action("close", "完成", "primary");
    } else if (active === "about") {
      body = `<div class="flow-result"><h3>RawLab</h3><p>版本 0.8.2（设计示例）</p></div>${link("project", "GitHub 项目")}${link("author", "作者")}${link("language", "语言", language)}${p === "android" ? link("mobile-update", "检查更新") : link("update-settings", "软件更新")}${link("privacy", "使用统计与隐私")}`;
    } else if (active === "update-settings") {
      body = `<div class="flow-static"><span>当前版本</span><strong>0.8.2（示例）</strong></div>${toggle("自动检查更新", 'data-flow-field="auto-check"', autoCheck)}${toggle("自动下载并安装更新", 'data-flow-field="auto-install"', autoInstall, "先保存调整、等待导出结束，在退出或重启时安装")}${note("上次检查：今天 09:41（示例）。更新提示只询问本次是否安装，长期设置在这里修改。")}`;
      footer = action("check-now", "立即检查", "primary");
    } else if (active === "mobile-update") {
      body = `${toggle("自动检查更新", "", true)}<p>发现更新时前往官方发布页下载。</p>${note("Android 保持现有检查与手动下载方式，本轮不设计移动端自动安装。")}`;
      footer =
        action("close", "完成") + action("release-page", "前往下载", "primary");
    } else if (active === "licenses") {
      body = `<h3>第三方软件许可</h3>${note("随应用打包的 licenses 目录承载实际许可全文，本设计不替换或重写许可内容。")}<div class="license-content"><p>组件名称、版权声明与许可全文</p><p class="muted">实际内容来自应用打包资源；支持滚动与文本选择。</p></div>`;
      footer = action("close", "关闭", "primary");
    } else if (active === "lens-profile") {
      body = `<label class="flow-field">搜索镜头<input type="search" placeholder="镜头名称、焦距或厂商" data-lens-search></label><div class="lens-results">${["自动匹配的镜头配置", "同系列镜头配置", "手动选择其他配置"].map((n) => `<button class="flow-row" data-flow-action="lens-selected"><span>${n}</span>${context.icon("next")}</button>`).join("")}</div>${note("列表内容为布局示例；正式匹配使用照片信息与现有镜头配置库。")}`;
      footer = action("close", "取消");
    } else if (
      ["privacy-policy", "project", "author", "external-release"].includes(
        active,
      )
    ) {
      const target = {
        "privacy-policy": "隐私政策",
        project: "GitHub 项目",
        author: "作者公开主页",
        "external-release": "官方发布页",
      }[active];
      body = `<div class="system-handoff">${context.icon("share")}<h3>${target}</h3><p>交给系统浏览器打开对应页面。此原型展示跳转集成点，不发起外部网络访问。</p></div>`;
      footer = action("close", "返回 RawLab", "primary");
    } else if (active === "results") {
      body = `<h3>已完成的输出</h3>${batchRows("batch-done")}${note(context.mobile ? "正式应用打开照片图库或文件位置查看保存结果。" : "正式应用在文件管理器中打开输出文件夹。")}`;
      footer = action("close", "完成", "primary");
    } else if (active === "components") {
      const tokens = [
        ["--canvas", "照片画布"],
        ["--surface", "调整区与对话框"],
        ["--raised", "输入框"],
        ["--control", "次要按钮"],
        ["--line", "分隔线"],
        ["--fg", "主要文字"],
        ["--muted", "次要文字"],
        ["--accent", "选中 / 已改动 / 进度"],
        ["--accent-weak", "选中底色"],
        ["--danger", "错误与破坏性"],
      ];
      const sizes = [
        ["--text-2xs", "刻度、角标"],
        ["--text-xs", "说明"],
        ["--text-sm", "参数名、页签"],
        ["--text-md", "正文"],
        ["--text-base", "主要正文"],
        ["--text-lg", "标题"],
        ["--text-2xl", "空状态标题"],
      ];
      body = `<h3>颜色令牌</h3>${note("黄色只表示选中、已改动和进度；重置、自动等次要操作使用中性灰。")}<div class="token-grid">${tokens.map(([v, t]) => `<div><i style="background:var(${v})"></i><strong>${t}</strong><code>${v}</code></div>`).join("")}</div><h3>字号阶梯</h3>${note("大字号模式整体替换这一组令牌，控件尺寸随之放大。")}<div class="type-scale">${sizes.map(([v, t]) => `<p style="font-size:var(${v})"><code>${v}</code>${t}</p>`).join("")}</div><h3>按钮</h3><div class="flow-form-inline">${action("component-demo", "主要", "primary")}${action("component-demo", "次要")}<button class="quiet" data-flow-action="component-demo">${context.icon("reset")}重置</button>${action("component-demo", "不可用", "secondary", true)}<button class="secondary destructive" data-flow-action="component-demo">放弃修改</button></div><h3>滑杆与数值</h3>${note("填充从默认值画到当前值：双向参数从中点向两侧；数值未改动时为中性色，改动后为黄色。HSL 轨道显示颜色变化方向。")}<div class="component-axes">${context.axis("双向 · 默认", 0, "contrast")}${context.axis("双向 · 负向已改动", -35, "highlights")}${context.axis("单向 · 已改动", 40, "sharpen", 0, 200)}${context.axis("单向 · 默认", 25, "grainSize", 0, 100)}</div><h3>分组与工具</h3><div class="component-row"><span class="group-sample"><span class="sample-dot"></span>已调整分组带小点，完整说明在可访问名称中</span><span class="tool-tabs"><button class="selected" aria-pressed="true">曝光<i class="tab-dot"></i></button><button>高光<i class="tab-dot"></i></button><button>对比度</button><button class="planned" disabled>我的预设<small>规划中</small></button></span></div><h3>语义图标</h3><div class="icon-catalog">${Object.entries(
        RawLabDesignIcons,
      )
        .map(
          ([id, value]) =>
            `<div>${context.icon(id)}<strong>${value.label}</strong><code>${id}</code></div>`,
        )
        .join(
          "",
        )}</div><h3>状态提示</h3>${error("保存失败示例", "保留参数并提供重试。")}`;
    } else {
      body = `<p>${titles()[active] || "平台界面"}</p>${note("由系统或现有应用入口打开；原型不发起真实外部访问。")}`;
      footer = action("close", "返回", "primary");
    }
    return { body, footer, sub };
  }
  // 有上一级时只显示返回；顶层界面只显示关闭，两者不同时出现。
  function parentOf(id) {
    if (["system-picker", "destination"].includes(id)) return pickerReturn;
    if (id === "batch-confirm") return "batch-select";
    if (id === "batch-inspect") return "batch-confirm";
    if (
      [
        "language",
        "haptics",
        "privacy",
        "about",
        "licenses",
        "update-settings",
      ].includes(id)
    )
      return "settings";
    if (
      ["look-import", "look-error", "look-delete", "look-rename"].includes(id)
    )
      return "looks";
    return null;
  }
  function render(ctx) {
    context = ctx;
    if (!active) return "";
    const busy = ["export-running", "batch-running", "batch-stopping"].includes(
      active,
    );
    const result = content();
    const { body, sub } = result;
    let footer = result.footer;
    const parent = parentOf(active);
    // 移动端顶层界面由标题栏关闭；桌面窗口用底部按钮和 Esc 关闭，不再重复右上角关闭。
    if (ctx.mobile && !parent)
      footer = footer.replace(
        /<button class="secondary" data-flow-action="close"[^>]*>[^<]*<\/button>/g,
        "",
      );
    const showClose =
      !parent && !(!ctx.mobile && /data-flow-action="close"/.test(footer));
    const sheet = ["import", "export", "zoom", "file-actions"].includes(active);
    return `<div class="flow-backdrop"></div><section class="flow-window ${sheet ? "flow-sheet" : ""}" role="dialog" aria-modal="true" tabindex="-1" aria-label="${titles()[active] || active}" data-flow-view="${active}"><header class="flow-header">${parent ? `<button class="icon" data-flow-action="back" aria-label="返回" ${busy ? "disabled" : ""}>${ctx.icon("back")}</button>` : ""}<h2>${titles()[active] || { "system-picker": "选择照片", destination: "选择位置", haptics: "触觉反馈", "look-rename": "重命名外观", "folder-error": "目录读取失败", "folder-remove": "移除目录", "apply-settings": "应用完整设置" }[active] || "RawLab"}</h2><span class="space"></span>${showClose ? `<button class="icon" data-flow-action="close" aria-label="关闭" ${busy ? "disabled" : ""}>${ctx.icon("close")}</button>` : ""}</header>${sub ? `<p class="flow-subtitle">${sub}</p>` : ""}<div class="flow-body">${body}</div>${footer ? `<footer class="flow-footer">${footer}</footer>` : ""}</section>`;
  }
  function handleClick(e) {
    const to = e.target.closest("[data-flow]");
    if (to) {
      const id = to.dataset.flow;
      if (id === "update") {
        close();
        context.gotoScene("update");
      } else if (id === "photo-info") {
        close();
        context.setInfo("file");
        context.repaint();
      } else {
        open(id);
        context.repaint();
      }
      return true;
    }
    const checkbox = e.target.closest("[data-flow-select]");
    if (checkbox) return true;
    const photo = e.target.closest("[data-flow-photo]");
    if (photo) {
      const n = Number(photo.dataset.flowPhoto);
      if (active === "batch-select") {
        selected.has(n) ? selected.delete(n) : selected.add(n);
        context.repaint();
      } else {
        close();
        context.gotoScene("groups");
      }
      return true;
    }
    const remove = e.target.closest("[data-remove-target]");
    if (remove) {
      selected.delete(Number(remove.dataset.removeTarget));
      context.repaint();
      return true;
    }
    if (e.target.closest("[data-inspect-target]")) {
      open("batch-inspect");
      context.repaint();
      return true;
    }
    const zoom = e.target.closest("[data-zoom-choice]");
    if (zoom) {
      context.setZoom(zoom.dataset.zoomChoice);
      close();
      context.repaint();
      return true;
    }
    const button = e.target.closest("[data-flow-action]");
    if (!button) return false;
    const a = button.dataset.flowAction;
    if (["start-export", "start-batch"].includes(a)) {
      const input = document.querySelector(".flow-body input[type=number]");
      if (input && !input.reportValidity()) return true;
    }
    if (a === "close" && ["system-picker", "destination"].includes(active))
      open(pickerReturn);
    else if (a === "close") close();
    else if (a === "back") {
      const parent = parentOf(active);
      parent ? open(parent) : close();
    } else if (a === "import-selected") {
      if (active === "system-picker" && pickerReturn === "look-import") {
        imported = true;
        open("looks");
      } else if (pickerReturn === "library") {
        open("library");
      } else if (pickerReturn === "batch-select") {
        selected = new Set([0, 1, 2]);
        open("batch-select");
      } else {
        close();
        context.gotoScene("groups");
      }
    } else if (a === "retry-import") open("import");
    else if (a === "grant-permission") open("library");
    else if (a === "folder-add" || a === "folder-refresh")
      open("system-picker");
    else if (a === "apply-complete-settings") {
      close();
      context.notify("完整设置已保存 · 设计示例");
    } else if (a === "destination-selected")
      open(
        pickerReturn === "batch-permission"
          ? "batch-running"
          : pickerReturn === "batch-confirm"
            ? "batch-confirm"
            : pickerReturn === "batch-save-files"
              ? "batch-done"
              : "export-options",
      );
    else if (a === "return-export")
      open(active === "destination" ? pickerReturn : "export-options");
    else if (a === "back-looks" || a === "look-save-name") open("looks");
    else if (a === "look-remove") {
      removed = true;
      open("looks");
    } else if (a === "look-import-complete") {
      imported = true;
      removed = false;
      open("looks");
    } else if (a === "look-use") {
      close();
      context.notify("已选择导入外观 · 设计示例");
    } else if (a === "start-export") open("export-running");
    else if (a === "select-all") selected = new Set(photos.map((_, i) => i));
    else if (a === "select-none") selected.clear();
    else if (a === "batch-next" || a === "return-confirm")
      open("batch-confirm");
    else if (a === "batch-edit-selection") open("batch-select");
    else if (a === "start-batch") {
      batchSnapshot = { ...batchSnapshot, ids: [...selected], format, size };
      open("batch-running");
    } else if (a === "cancel-batch") {
      open("batch-stopping");
      timer = setTimeout(() => {
        open("batch-cancelled");
        context.repaint();
      }, 700);
    } else if (a === "retry-batch" || a === "resume-batch")
      open("batch-running");
    else if (a === "discard-batch") {
      open("discard-confirm");
    } else if (a === "reauthorize") open("destination");
    else if (a === "save-dng-files") open("destination");
    else if (a === "confirm-save-result") open("batch-cancelled");
    else if (a === "resume-choice") open("batch-interrupted");
    else if (a === "discard-confirmed") {
      batchSnapshot = null;
      close();
    } else if (a === "back-settings") open("settings");
    else if (a === "lens-selected") {
      close();
      context.lensChanged();
    } else if (a === "open-results") open("results");
    else if (a === "release-page") open("external-release");
    else if (a === "component-demo") context.notify("按钮已触发 · 组件演示");
    else if (a === "check-now") {
      close();
      context.gotoScene("update");
      return true;
    } else if (a === "toggle-dock") {
      context.toggleDock();
      close();
    } else if (a === "reset-all") {
      close();
      context.requestResetAll();
    } else if (RawLabDesign.flowTitles[a]) open(a);
    context.repaint();
    return true;
  }
  function handleChange(e) {
    if (e.target.matches("[data-album-aspect]")) {
      document
        .querySelector(".flow-photo-grid")
        .classList.toggle("original-aspect", !e.target.checked);
      return true;
    }
    if (e.target.matches("[data-result-checked]")) {
      document.querySelector(
        "[data-flow-action=confirm-save-result]",
      ).disabled = !e.target.checked;
      return true;
    }
    if (e.target.matches("[data-flow-select]")) {
      const n = Number(e.target.dataset.flowSelect);
      e.target.checked ? selected.add(n) : selected.delete(n);
      context.repaint();
      return true;
    }
    const f = e.target.dataset.flowField;
    if (f) {
      const v =
        e.target.type === "checkbox" ? e.target.checked : e.target.value;
      if (f === "format") {
        format = v;
        if (v === "DNG") destination = "文件夹";
      }
      if (f === "size") size = v;
      if (f === "destination") destination = v;
      if (f === "language") language = v;
      if (f === "privacy") privacy = v;
      if (f === "haptics") haptics = v;
      if (f === "auto-check") autoCheck = v;
      if (f === "auto-install") autoInstall = v;
      if (f === "photo-margin") context.setMargin(v);
      context.repaint();
      return true;
    }
    if (e.target.matches("[data-album-columns]")) {
      document.querySelector(".flow-photo-grid").style.gridTemplateColumns =
        `repeat(${e.target.value},minmax(0,1fr))`;
      return true;
    }
    return false;
  }
  return {
    open,
    close,
    render,
    handleClick,
    handleChange,
    get active() {
      return active;
    },
    get busy() {
      return ["export-running", "batch-running", "batch-stopping"].includes(
        active,
      );
    },
  };
})();
