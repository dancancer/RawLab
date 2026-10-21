// 可评审的本地交互稿。没有图像处理、磁盘写入、网络下载或原生安装。
window.RawLabIteration = (() => {
  const D = RawLabDesign;
  let ctx,
    scopeMode = "custom",
    scopePurpose = "copy",
    clipboard = null;
  let renameDraft = null;
  let presetName = "森林柔光",
    presetError = "",
    selectedPreset = "p1";
  const T = RawLabIterationTools;
  let presetTarget = false,
    activePresetPayload = null,
    activePresetName = "";
  let scopeExpanded = new Set(["light"]);
  let historyUndone = false,
    batchEditing = false,
    editPhotoId = "photo-1";
  let editReturnSnapshot = null,
    editTemporary = null,
    frozenItems = [],
    lastOutcome = "";
  let installKind = "supported",
    migrationDone = false;
  let targetDraftOutcome = "",
    discardedCount = 0;
  let singleBefore = null,
    singleAfter = null,
    pendingBefore = null;
  const photos = [
    { id: "source", name: "瀑布.ARW", location: "旅行 / 第一天", source: true },
    { id: "photo-1", name: "山谷.ARW", location: "旅行 / 第一天" },
    { id: "photo-2", name: "林间.ARW", location: "旅行 / 第一天" },
    { id: "photo-3", name: "瀑布.ARW", location: "旅行 / 第二天" },
    {
      id: "photo-4",
      name: "晨光.JPG",
      location: "旅行 / 第二天",
      raster: true,
    },
  ];
  let selectedPhotos = new Set(["photo-1", "photo-2", "photo-3"]);
  const edits = new Map(),
    results = new Map();
  const presets = [
    {
      id: "p1",
      name: "森林柔光",
      summary: "光线、颜色、HSL · 不含几何与镜头",
      payload: null,
    },
    {
      id: "p2",
      name: "日落暖调",
      summary: "白平衡、鲜艳度、颜色分级",
      payload: null,
    },
    {
      id: "p3",
      name: "黑白街景",
      summary: "光线、饱和度、颗粒",
      payload: null,
    },
  ];
  const fieldGroups = [
    [
      "looks",
      "外观",
      [
        ["look", "胶片/配方"],
        ["strength", "强度"],
      ],
    ],
    [
      "light",
      "光线",
      [
        ["exposure", "曝光"],
        ["highlights", "高光"],
        ["shadows", "阴影"],
        ["contrast", "对比度"],
        ["blackPoint", "黑场"],
        ["whitePoint", "白场"],
        ["curve", "曲线及模式"],
      ],
    ],
    [
      "color",
      "颜色",
      [
        ["whiteBalance", "白平衡模式与自定义值"],
        ["saturation", "饱和度"],
        ["vibrance", "鲜艳度"],
        ["grading", "三分区颜色分级"],
      ],
    ],
    [
      "effects",
      "效果",
      [
        ["clarity", "清晰度"],
        ["dehaze", "去朦胧"],
        ["vignette", "暗角及辅助参数"],
        ["grain", "颗粒及辅助参数"],
      ],
    ],
    [
      "detail",
      "细节",
      [
        ["sharpen", "锐化"],
        ["denoise", "降噪完整设置"],
      ],
    ],
    [
      "geometry",
      "几何与镜头",
      [
        ["geometry", "裁切、旋转、透视"],
        ["lens", "镜头请求配置"],
      ],
    ],
  ];
  const hslFields = D.palettes.flatMap(([name], i) =>
    ["色相", "饱和度", "明度"].map((axis, a) => [
      `hsl.${i}.${a}`,
      name + "色 · " + axis,
    ]),
  );
  const allFields = [
    ...fieldGroups.flatMap(([, , fields]) => fields),
    ...hslFields,
  ];
  let scope = new Set(
    allFields
      .map(([id]) => id)
      .filter((id) => !["geometry", "lens"].includes(id)),
  );
  const expandedFields = {
    vignette: [
      "vignette",
      "vignetteMid",
      "vignetteRound",
      "vignetteFeather",
      "vignetteHigh",
    ],
    grain: ["grain", "grainSize", "grainRoughness"],
    denoise: ["denoiseLuma", "denoiseChroma", "denoiseCoarse"],
    geometry: [
      "straighten",
      "perspective",
      "horizontal",
      "cropX",
      "cropY",
      "cropW",
      "cropH",
    ],
    grading: [
      "shadowHue",
      "shadowSat",
      "midHue",
      "midSat",
      "highHue",
      "highSat",
    ],
  };
  const esc = (s) =>
    String(s).replace(
      /[&<>"']/g,
      (c) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[c],
    );
  const button = (id, text, style = "secondary", disabled = false) =>
    `<button class="${style}" data-iter="${id}" ${disabled ? "disabled" : ""}>${text}</button>`;
  const link = (id, text, small = "") =>
    `<button class="flow-row" data-iter="open:${id}"><span>${text}${small ? `<small>${small}</small>` : ""}</span>${ctx.icon("next")}</button>`;
  const note = (s) => `<p class="flow-note">${s}</p>`;
  const error = (title, copy) =>
    `<div class="flow-error" role="status">${ctx.icon("warning")}<div><strong>${title}</strong><p>${copy}</p></div></div>`;
  const success = (title, copy) =>
    `<div class="iteration-result">${ctx.icon("check")}<div><h3>${title}</h3><p>${copy}</p></div></div>`;
  const close = () => {
    RawLabDesignFlows.close();
    presetTarget = false;
    ctx.repaint();
  };
  const open = (id) => {
    RawLabDesignFlows.open(id);
    ctx.repaint();
  };
  const currentTargets = () =>
    presetTarget
      ? [photos[0]]
      : photos.filter((p) => selectedPhotos.has(p.id) && !p.source);
  const snapshot = () => ({
    ...structuredClone(ctx.snapshot()),
    curve: T.snapshot(),
  });
  const currentPreset = () =>
    presets.find((p) => p.id === selectedPreset) || presets[0];
  const sourcePhoto = () => {
    const frozen = [
      "copy-ready",
      "paste-result",
      "paste-targets",
      "paste-draft",
      "paste-partial",
      "paste-done",
      "paste-incompatible",
    ].includes(RawLabDesignFlows.active);
    return frozen && clipboard?.sourceInfo
      ? clipboard.sourceInfo
      : photos.find((p) => p.id === (batchEditing ? editPhotoId : "source"));
  };
  const sourceSummary = () =>
    `<div class="iteration-source">${ctx.photoMarkup("job-thumbnail", "来源照片")}<div><strong>${presetTarget ? esc(activePresetName) : esc(sourcePhoto().name)}</strong><small>${presetTarget ? "来源：我的调整预设" : "来源 · " + esc(sourcePhoto().location)}</small></div><span class="tag">${presetTarget ? activePresetPayload?.fields.length || 0 : RawLabDesignFlows.active?.startsWith("paste-") || RawLabDesignFlows.active === "copy-ready" ? clipboard?.fields.length || scope.size : scope.size} 项调整</span></div>`;
  function capture() {
    return {
      fields: [...scope],
      snapshot: snapshot(),
      source: batchEditing
        ? photos.find((p) => p.id === editPhotoId).name
        : "瀑布.ARW",
      sourceInfo: structuredClone(
        photos.find((p) => p.id === (batchEditing ? editPhotoId : "source")),
      ),
      version: 1,
    };
  }
  function merge(base, payload) {
    const next = structuredClone(base);
    for (const id of payload.fields) {
      if (id.startsWith("hsl.")) {
        const [, i, a] = id.split(".").map(Number);
        next.hsl[i][a] = payload.snapshot.hsl[i][a];
      } else if (id === "look") {
        next.film = payload.snapshot.film;
        next.recipe = payload.snapshot.recipe;
      } else if (id === "whiteBalance") {
        next.whiteBalance = payload.snapshot.whiteBalance;
        if (next.whiteBalance === "自定义")
          for (const k of ["temperature", "tint"])
            next.values[k] = payload.snapshot.values[k];
      } else if (id === "lens")
        next.lens = structuredClone(payload.snapshot.lens);
      else if (id === "curve") {
        next.curve = structuredClone(payload.snapshot.curve);
        next.values.curve = payload.snapshot.values.curve;
      } else if (id === "denoise") {
        next.denoiseEnabled = payload.snapshot.denoiseEnabled;
        for (const k of expandedFields[id])
          next.values[k] = payload.snapshot.values[k];
      } else
        for (const k of expandedFields[id] || [id])
          if (k in payload.snapshot.values)
            next.values[k] = payload.snapshot.values[k];
    }
    return next;
  }
  function applyTargets(
    partial = false,
    retry = false,
    skipIncompatible = false,
  ) {
    const payload = presetTarget ? activePresetPayload : clipboard || capture();
    if (!retry) results.clear();
    for (const p of currentTargets()) {
      if (retry && results.get(p.id)?.status !== "failed") continue;
      if (partial && p.id === "photo-2") {
        results.set(p.id, {
          status: "failed",
          reason: "无法写入编辑记录",
          before: structuredClone(edits.get(p.id)),
        });
        continue;
      }
      const before = structuredClone(edits.get(p.id) || snapshot());
      const safePayload = structuredClone(payload);
      if (skipIncompatible && p.raster)
        safePayload.fields = safePayload.fields.filter(
          (id) => !["whiteBalance", "lens"].includes(id),
        );
      if (skipIncompatible && p.id === "photo-3")
        safePayload.fields = safePayload.fields.filter((id) => id !== "look");
      const after = merge(before, safePayload);
      edits.set(p.id, after);
      results.set(p.id, {
        status: "applied",
        historyState: "applied",
        before,
        after,
        skipped: skipIncompatible
          ? p.raster
            ? "已跳过白平衡、镜头"
            : p.id === "photo-3"
              ? "已跳过缺失外观"
              : ""
          : "",
      });
      if (presetTarget) {
        singleBefore = structuredClone(before);
        singleAfter = structuredClone(after);
        ctx.setCanRedo(false);
        ctx.restore(after);
        T.restore(after.curve);
      }
    }
    historyUndone = false;
  }
  function scopePicker() {
    const checks = (fields) =>
      fields
        .map(
          ([id, label]) =>
            `<label class="scope-item"><input type="checkbox" data-scope-field="${id}" ${scope.has(id) ? "checked" : ""}><span>${label}</span></label>`,
        )
        .join("");
    return `<div class="iteration-segments" role="group" aria-label="调整范围">${[
      ["all", "全部"],
      ["modified", "仅已修改"],
      ["custom", "自定义"],
    ]
      .map(
        ([id, label]) =>
          `<button data-iter="scope:${id}" aria-pressed="${scopeMode === id}">${label}</button>`,
      )
      .join(
        "",
      )}</div><p class="scope-summary" aria-live="polite">已选 ${scope.size} 项 · 未选项保留目标原值</p><div class="scope-groups">${fieldGroups.map(([id, title, fields]) => `<details data-scope-section="${id}" ${scopeExpanded.has(id) ? "open" : ""}><summary><label><input type="checkbox" data-scope-group="${id}" ${fields.every(([key]) => scope.has(key)) ? "checked" : ""}>${title}${id === "geometry" ? "<small>默认不包含</small>" : ""}</label></summary>${checks(fields)}</details>`).join("")}<details data-scope-section="hsl" ${scopeExpanded.has("hsl") ? "open" : ""}><summary>HSL · 八色域 / 三轴 <small>${hslFields.filter(([id]) => scope.has(id)).length} / 24</small></summary>${D.palettes.map(([name], i) => `<details class="scope-channel" data-scope-section="hsl-${i}" ${scopeExpanded.has("hsl-" + i) ? "open" : ""}><summary>${name}色</summary>${checks(hslFields.slice(i * 3, i * 3 + 3))}</details>`).join("")}</details></div>`;
  }
  function targetRows(mode = "preview") {
    return `<div class="iteration-targets">${currentTargets()
      .map((p) => {
        const r = results.get(p.id),
          failed =
            mode === "partial" && p.id === "photo-2" && r?.status !== "applied";
        const status = failed
          ? "保存失败 · 原记录保留"
          : mode === "done" || r?.status === "applied"
            ? "调整已保存"
            : "待应用";
        return `<div class="iteration-target">${ctx.photoMarkup("job-thumbnail", p.name)}<div><strong>${p.name}</strong><small>${p.location}</small><span class="${failed ? "error-text" : "muted"}">${status}${r?.skipped ? " · " + r.skipped : ""}</span></div>${failed ? ctx.icon("warning") : status === "调整已保存" ? ctx.icon("check") : ""}</div>`;
      })
      .join("")}</div>`;
  }
  function draftChoices(source = true) {
    return `${sourceSummary()}${error(source ? "来源有未应用草稿" : "目标仍有未应用草稿", source ? "先决定几何或镜头草稿，再冻结要复用的调整。" : "林间.ARW 正在另一个编辑会话中修改；不能直接覆盖。")}${source ? button("draft:apply", "应用草稿并继续", "primary") + button("draft:discard", "放弃草稿并继续") + button("draft:cancel", "继续编辑") : `<div class="iteration-choice-list">${button("target-draft:apply", "应用并保存目标草稿")}${button("target-draft:discard", "放弃目标草稿")}${button("target-draft:skip", "跳过这张照片")}${button("close", "取消整次粘贴")}</div>`}`;
  }
  function presetList(empty = false, inPanel = false) {
    return `${inPanel ? "" : note("调整预设独立于照片保存；删除源照片后仍可复用。")}${button("open:preset-save", "保存当前调整", "primary")}${!presets.length || empty ? '<div class="iteration-empty"><h3>还没有调整预设</h3><p>把常用调整保存起来，在其他照片上复用。</p></div>' : `<div class="preset-list">${presets.map((p) => `<div class="preset-row"><button data-iter="preset:apply:${p.id}"><strong>${esc(p.name)}</strong><small>${p.summary}</small></button><button class="icon" data-iter="preset:manage:${p.id}" aria-label="管理${esc(p.name)}">${ctx.icon("more")}</button></div>`).join("")}</div>`}${inPanel ? button("open:user-presets", "管理全部预设", "quiet") : ""}`;
  }
  function content(id) {
    let body = "",
      footer = "",
      sub = "";
    if (["copy-scope", "batch-sync-scope"].includes(id)) {
      body =
        sourceSummary() +
        scopePicker() +
        note(
          "拍摄时白平衡等自动项会在每张目标上解析；照片信息和查看状态不会复制。",
        );
      footer = button(
        id === "copy-scope" ? "capture" : "sync-preflight",
        id === "copy-scope"
          ? "复制所选调整"
          : `继续 · ${currentTargets().length} 张目标`,
        "primary",
        !scope.size,
      );
    } else if (
      ["copy-source-draft", "paste-draft", "batch-sync-preflight"].includes(id)
    ) {
      body = draftChoices(id === "copy-source-draft");
      if (id === "batch-sync-preflight")
        body += note(
          "草稿应用是独立编辑；之后取消同步不会撤销已经明确保存的草稿。",
        );
    } else if (id === "target-draft-save-error") {
      body = error(
        "目标草稿未保存",
        "林间.ARW 的草稿和原提交均保留，尚未应用复制内容。请重试保存、明确跳过这张照片或取消操作。",
      );
      footer =
        button("close", "取消") +
        button("target-draft:skip", "跳过这张照片") +
        button("target-draft:apply", "重试保存草稿", "primary");
    } else if (id === "copy-source-save-error") {
      body =
        error(
          "来源调整未保存",
          "草稿和原提交状态均已保留。保存成功后才能复制或保存预设。",
        ) + sourceSummary();
      footer =
        button("draft:cancel", "继续编辑") +
        button("draft:apply", "重试保存并继续", "primary");
    } else if (id === "copy-ready") {
      body =
        success(
          "调整已复制",
          `${clipboard?.fields.length || scope.size} 项调整已冻结，继续修改来源不会改变复制内容。`,
        ) +
        sourceSummary() +
        link("paste-result", "粘贴到其他照片", "保留未选项，不累加强度") +
        link("preset-save", "保存为命名预设");
      footer = button("close", "完成", "primary");
    } else if (id === "paste-empty") {
      body = error(
        "还没有复制调整",
        "先从一张照片复制已提交的调整，再粘贴到其他照片。未修改任何目标。",
      );
      footer = button("open:copy-scope", "选择要复制的调整", "primary");
    } else if (id === "paste-targets") {
      body = sourceSummary() + collection();
      footer = button(
        "paste:targets-done",
        `确认 ${currentTargets().length} 张目标`,
        "primary",
        !currentTargets().length,
      );
    } else if (id === "paste-result") {
      body =
        sourceSummary() +
        `<h3>${currentTargets().length} 张目标照片</h3>` +
        targetRows() +
        (targetDraftOutcome ? note(targetDraftOutcome) : "") +
        note("仅替换所选调整；相同内容重复粘贴不累加。") +
        (presetTarget
          ? ""
          : link(
              "paste-targets",
              "选择目标照片",
              "可选择一张或多张，来源不会被覆盖",
            ));
      footer =
        button("open:paste-draft", "检查目标草稿", "quiet leading") +
        button(
          "paste:apply",
          `应用并保存 ${currentTargets().length} 张`,
          "primary",
          !currentTargets().length,
        );
    } else if (id === "paste-incompatible") {
      body =
        error("部分调整无法应用", "先选择处理方式，尚未修改任何目标。") +
        `<div class="flow-static"><span>晨光.JPG</span><strong>拍摄时白平衡：RAW 专属</strong></div><div class="flow-static"><span>瀑布.ARW · 第二天</span><strong>外观“暖日胶片”未找到</strong></div><div class="flow-static"><span>导入调整</span><strong>含当前版本不支持的字段</strong></div>` +
        note("取消保留全部原值；明确跳过仅应用兼容项，结果会标记跳过范围。");
      footer =
        button("close", "取消") +
        button("paste:skip-incompatible", "跳过不兼容项后应用", "primary");
    } else if (["paste-partial", "paste-done"].includes(id)) {
      const partial = id === "paste-partial";
      body = partial
        ? error("部分照片未保存", "已成功的目标保持；失败照片仍保留原记录。")
        : success(
            "调整已保存到目标",
            lastOutcome || "复制内容不变，可继续粘贴或撤销本次操作。",
          );
      body += targetRows(partial ? "partial" : "done");
      footer =
        button("open:history-batch", "查看/撤销本次操作", "quiet leading") +
        (partial
          ? button("paste:retry", "只重试失败照片", "primary")
          : button("close", "完成", "primary"));
    } else if (id.startsWith("history-")) {
      const conflict = id === "history-conflict",
        failure = id === "history-save-error";
      body = conflict
        ? error(
            "有照片在此后被单独修改",
            "林间.ARW 的新编辑不会被覆盖。默认取消；可明确只撤销无冲突目标。",
          )
        : failure
          ? error(
              "部分撤销未保存",
              "已恢复目标不会重复撤销；失败照片仍可重试。",
            )
          : id === "history-recovered"
            ? success(
                "已恢复无冲突目标",
                "成功子集已更新，冲突照片和复制内容保持。",
              )
            : `<p class="flow-lead">${id === "history-single" ? "当前照片" : "本次批量操作"} · 当前会话</p>`;
      body +=
        `<div class="history-row"><span>${historyUndone ? "已撤销" : "已应用"}</span><strong>${id === "history-single" ? "当前照片的最近一次调整" : `粘贴调整 · ${[...results.values()].filter((r) => r.status === "applied").length} 张成功目标`}</strong><small>光线、颜色、效果 · ${historyUndone ? "可重做" : "可撤销"}</small></div>${conflict ? '<div class="flow-static"><span>林间.ARW</span><strong>保留后续单张编辑</strong></div>' : ""}` +
        (id === "history-single"
          ? ""
          : `<div class="iteration-targets">${[...results]
              .filter(([, r]) => r.status === "applied")
              .map(
                ([photoId, r]) =>
                  `<div class="flow-static"><span>${photos.find((p) => p.id === photoId)?.name}</span><strong>${r.historyState === "undone" ? "已撤销 · 不重复处理" : JSON.stringify(edits.get(photoId)) !== JSON.stringify(r.after) ? "冲突 · 保留后续编辑" : "已应用 · 可撤销"}</strong></div>`,
              )
              .join("")}</div>`) +
        note(
          "单张撤销只处理当前照片；整批撤销只处理本次实际成功目标。文本输入优先使用文本撤销。",
        );
      footer = conflict
        ? button("close", "取消") +
          button("history:skip", "只撤销无冲突目标", "primary")
        : failure
          ? button("history:retry", "重试失败目标", "primary")
          : button(
              historyUndone ? "history:redo" : "history:undo",
              historyUndone ? "重做" : "撤销",
              "primary",
            );
    } else if (
      ["user-presets", "presets-empty", "preset-restored"].includes(id)
    ) {
      body =
        (id === "preset-restored"
          ? success("预设库已恢复", "原损坏文件副本仍保留；照片编辑不受影响。")
          : "") + presetList(id === "presets-empty");
      footer = button("close", "完成");
    } else if (["preset-save", "preset-name-error"].includes(id)) {
      body =
        `<label class="flow-field">预设名称<input data-preset-name value="${esc(presetName)}" aria-describedby="preset-name-error" autocomplete="off"></label><p id="preset-name-error" class="error-text" role="status">${presetError || (id === "preset-name-error" ? "请输入名称，不能只包含空白。" : "")}</p>` +
        scopePicker();
      footer = button("preset:save", "保存预设", "primary", !scope.size);
    } else if (["preset-duplicate", "preset-overwrite"].includes(id)) {
      body = error(
        id === "preset-duplicate" ? "已有同名预设" : "覆盖这个预设？",
        `“${esc(presetName)}”已保存光线、颜色与 HSL。覆盖会替换预设内容，已应用的照片不受影响。`,
      );
      footer =
        button("preset:save-as", "另存一个名称") +
        button(
          id === "preset-duplicate"
            ? "open:preset-overwrite"
            : "preset:overwrite",
          id === "preset-duplicate" ? "查看覆盖确认" : "确认覆盖",
          "primary",
        );
    } else if (["preset-manage", "preset-delete"].includes(id)) {
      const p = currentPreset();
      body =
        id === "preset-delete"
          ? error(
              `删除“${esc(p?.name || presetName)}”？`,
              "只删除这个预设，已应用照片的调整保持。",
            )
          : `<label class="flow-field">预设名称<input data-preset-rename value="${esc(renameDraft ?? p?.name ?? presetName)}"></label><p id="preset-name-error" class="error-text" role="status">${presetError}</p>${note(p?.summary || "命名调整预设")}${link("preset-delete", "删除预设")}`;
      footer =
        id === "preset-delete"
          ? button("open:preset-manage", "取消") +
            button("preset:delete", "删除", "destructive")
          : button("preset:rename", "保存名称", "primary");
    } else if (
      [
        "preset-write-error",
        "preset-corrupt",
        "preset-future",
        "preset-missing-look",
      ].includes(id)
    ) {
      const copy = {
        "preset-write-error": [
          "预设未保存",
          "原预设未被替换，输入内容仍保留。",
        ],
        "preset-corrupt": [
          "无法读取预设库",
          "原文件已保留；可恢复可读取的预设或保留副本重新开始。",
        ],
        "preset-future": [
          "此预设需要更新版本",
          "不会删除未知字段或降级覆盖原预设。可选择其他预设。",
        ],
        "preset-missing-look": [
          "缺少预设使用的外观",
          "“暖日胶片”未找到；不会自动换成中性或伪装完整应用。",
        ],
      }[id];
      body = error(...copy);
      footer =
        id === "preset-corrupt"
          ? button("preset:restore", "保留副本并恢复", "primary")
          : id === "preset-future"
            ? button("open:user-presets", "选择其他预设", "primary")
            : id === "preset-missing-look"
              ? button("open:paste-incompatible", "查看可跳过范围", "primary")
              : button("preset:retry-save", "重试保存", "primary");
    } else if (id.startsWith("batch-")) return batchContent(id);
    else if (id.startsWith("update-")) return updateContent(id);
    else if (id === "curve-mode-confirm" || id === "curve-mode-conflict") {
      body = error(
        id === "curve-mode-conflict"
          ? "曲线数据包含冲突模式"
          : "切换曲线模式？",
        id === "curve-mode-conflict"
          ? "旧 S 曲线和多点曲线同时激活，尚未覆盖当前合法调整。"
          : T.mode() === "legacy"
            ? "多点曲线将从直线开始；当前 S 曲线不会自动转换。取消会完整保留原效果。"
            : "返回旧 S 曲线将放弃本次多点编辑；取消保留当前控制点。",
      );
      footer =
        button("close", "取消") +
        button(
          "curve:confirm-mode",
          id === "curve-mode-conflict" ? "保留当前合法模式" : "确认切换",
          "primary",
        );
    }
    return { body, footer, sub };
  }
  function collection() {
    return `<div class="iteration-photo-grid">${photos.map((p) => `<div class="iteration-photo ${selectedPhotos.has(p.id) ? "selected" : ""}"><button data-iter="${p.source ? "source-info" : "select:" + p.id}" ${p.source ? "disabled" : ""}>${ctx.photoMarkup("flow-thumbnail", p.name)}<strong>${p.name}</strong><small>${p.location}</small></button>${p.source ? '<span class="photo-source">来源 · 不作为目标</span>' : `<label><input type="checkbox" data-iter-photo="${p.id}" ${selectedPhotos.has(p.id) ? "checked" : ""}>选择</label>${edits.get(p.id)?.tweaked ? '<span class="photo-source">已单张微调</span>' : ""}`}</div>`).join("")}</div>`;
  }
  function frozenRows() {
    return `<div class="iteration-targets">${frozenItems.map((item) => `<div class="iteration-target">${ctx.photoMarkup("job-thumbnail", item.photo.name)}<div><strong>${item.photo.name}</strong><small>${item.photo.location} · 曝光 ${item.snapshot.values.exposure > 0 ? "+" : ""}${item.snapshot.values.exposure} EV</small><span class="${item.status === "failed" ? "error-text" : "muted"}">${{ waiting: "等待中", running: "处理中", succeeded: "已导出 · 不会重复", failed: "失败 · 无法保存输出", cancelled: "未处理", discarded: "已放弃 · 不再恢复", "ready-to-save": "已渲染 · 待保存文件" }[item.status]}</span></div>${item.status === "succeeded" ? ctx.icon("check") : ""}</div>`).join("")}</div>`;
  }
  function batchContent(id) {
    let body = "",
      footer = "";
    if (["batch-sync", "batch-sync-empty", "batch-sync-return"].includes(id)) {
      body =
        id === "batch-sync-return"
          ? success("已返回原照片集合", "顺序、选择和其他照片的调整均保留。")
          : `<p class="flow-lead">应用调整并保存到所选照片</p>`;
      body +=
        sourceSummary() +
        `<div class="iteration-inline">${button("batch:all", "选择全部目标", "quiet")}${button("batch:none", "全不选", "quiet")}<span aria-live="polite">${currentTargets().length} 张目标</span></div>` +
        collection() +
        note("同名照片按各自身份处理；来源始终排除。单张微调只改那一张。");
      footer =
        button("batch:old-export", "仅用于本次批量导出", "quiet leading") +
        button(
          "open:batch-per-target-export",
          "按各张调整导出",
          "secondary",
          !currentTargets().length,
        ) +
        button("batch:scope", "同步调整…", "primary", !currentTargets().length);
      if (id === "batch-sync-return")
        body += `<div class="iteration-inline">${currentTargets()
          .map((p) => button("edit:" + p.id, "微调 " + p.name))
          .join("")}</div>`;
    } else if (["batch-sync-partial", "batch-sync-success"].includes(id)) {
      const partial = id === "batch-sync-partial";
      body = partial
        ? error(
            "部分目标未保存",
            "成功目标保留；林间.ARW 仍使用原编辑记录，可单独重试。",
          )
        : success("调整已逐张保存", "现在可以单独微调，再返回同一集合。");
      body +=
        (targetDraftOutcome
          ? note(
              targetDraftOutcome +
                "；本次同步按所选范围替换，撤销同步回到草稿处理之后。",
            )
          : "") +
        targetRows(partial ? "partial" : "done") +
        `<div class="iteration-inline">${currentTargets()
          .map((p) => button("edit:" + p.id, "微调 " + p.name))
          .join("")}</div>`;
      footer =
        button("open:history-batch", "撤销成功目标", "quiet leading") +
        (partial
          ? button("batch:retry", "只重试失败目标", "primary")
          : button(
              "open:batch-per-target-export",
              "按各张调整导出",
              "primary",
            ));
    } else if (id === "batch-sync-unavailable") {
      body =
        error(
          "部分照片无法访问",
          "林间.ARW 的文件夹授权已失效；尚未覆盖原编辑记录。",
        ) +
        targetRows() +
        note("如果来源文件已移除，请重新选择来源后再同步，不按同名文件替代。");
      footer =
        button("batch:remove-unavailable", "移除失效目标") +
        button("batch:reauthorize", "重新授权后继续", "primary");
    } else if (id === "batch-edit-save-error") {
      body =
        error(
          "单张调整未保存",
          "当前微调保留在此照片，不会写到其他目标。保存成功前不能返回集合或冻结导出。",
        ) +
        `<div class="flow-static"><span>当前照片</span><strong>${photos.find((p) => p.id === editPhotoId)?.name || "山谷.ARW"}</strong></div>`;
      footer =
        button("batch:continue-edit", "继续编辑") +
        button("batch:save-return", "重试保存并返回", "primary");
    } else if (id === "batch-per-target-export") {
      body =
        `<p class="flow-lead">使用每张照片自己的最终调整</p>` +
        `<div class="iteration-freeze-list">${currentTargets()
          .map((p) => {
            const edit = edits.get(p.id) || snapshot();
            return `<div class="flow-static"><span>${p.name}<small>${p.location}</small></span><strong>${edit.values.exposure > 0 ? "+" : ""}${edit.values.exposure} EV${edit.tweaked ? " · 已单张微调" : ""}</strong></div>`;
          })
          .join(
            "",
          )}</div><label class="flow-field">格式<select data-iter-option="format">${(ctx.platform === "ios" ? ["JPEG", "DNG"] : ["JPEG", "PNG 16-bit", "DNG"]).map((f) => `<option ${outputFormat === f ? "selected" : ""}>${f}</option>`).join("")}</select></label><label class="flow-field">尺寸<select data-iter-option="size"><option ${outputSize === "原始分辨率" ? "selected" : ""}>原始分辨率</option><option ${outputSize !== "原始分辨率" ? "selected" : ""}>长边 3000 像素</option></select></label>` +
        (ctx.platform === "ios"
          ? `<div class="flow-static"><span>保存位置</span><strong>${outputFormat === "DNG" ? "文件 · 渲染完成后选择" : "照片图库"}</strong></div>`
          : `<label class="flow-field">保存位置<select data-iter-option="destination">${(ctx.mobile && outputFormat !== "DNG" ? ["照片图库", "文件夹"] : ["文件夹"]).map((d) => `<option ${outputDestination === d ? "selected" : ""}>${d}</option>`).join("")}</select></label>${!ctx.mobile || outputDestination === "文件夹" ? `<button class="flow-row" data-flow="destination"><span>选择输出文件夹<small>导出照片 · 系统位置选择器</small></span>${ctx.icon("folder")}</button>` : ""}`) +
        note(
          "开始时逐张冻结参数、外观、输出设置和顺序。之后再编辑照片，不会改变已启动任务。",
        );
      footer = button(
        "batch:freeze",
        `冻结并导出 ${currentTargets().length} 张`,
        "primary",
        !currentTargets().length,
      );
    } else if (id === "batch-per-target-save-files") {
      body =
        success(
          "DNG 已渲染，尚未保存到文件",
          "选择保存位置后才计为输出成功；取消会保留可恢复任务。",
        ) + frozenRows();
      footer =
        button("open:batch-per-target-cancelled", "稍后保存") +
        `<button class="primary" data-flow="destination">保存 DNG 文件…</button>`;
    } else if (id === "batch-per-target-discard") {
      body =
        error(
          "放弃未处理照片？",
          "已经成功保存的输出保留；未处理照片不再继续。各照片的编辑记录不受影响。",
        ) + frozenRows();
      footer =
        button("open:batch-per-target-interrupted", "保留任务") +
        button("batch:discard-task", "放弃未处理项", "destructive");
    } else {
      const done = [
          "batch-per-target-done",
          "batch-per-target-discarded",
        ].includes(id),
        running = id === "batch-per-target-running",
        uncertain = id === "batch-per-target-uncertain";
      const messages = {
        "batch-per-target-running": [
          "正在按逐张调整导出",
          "使用任务启动时冻结的快照。",
        ],
        "batch-per-target-partial": [
          "部分照片导出失败",
          "已成功输出不重做；只重试失败和未处理项。",
        ],
        "batch-per-target-cancelled": [
          "批量导出已取消",
          "成功输出保留，未处理项可以继续或放弃。",
        ],
        "batch-per-target-interrupted": [
          "发现未完成任务",
          "使用原来的逐张快照恢复，不读取当前编辑状态。",
        ],
        "batch-per-target-permission": [
          "无法访问输出位置",
          "重新授权后只继续未成功项。",
        ],
        "batch-per-target-uncertain": [
          "先核对图库保存结果",
          "移动端返回的保存结果不确定。请核对已生成照片，避免重复导出。",
        ],
        "batch-per-target-discarded": [
          "未处理项已放弃",
          `保留已成功输出；${discardedCount} 张未处理项已明确放弃，未显示为导出成功。`,
        ],
        "batch-per-target-done": [
          "批量导出完成",
          "各张输出保留独立调整；照片原文件没有改写。",
        ],
      };
      const [title, copy] =
        messages[id] || messages["batch-per-target-interrupted"];
      body = done
        ? success(title, copy)
        : running
          ? `<p class="flow-lead">${title}</p>${note(copy)}<div class="flow-job-progress"><i style="width:38%"></i></div>`
          : error(title, copy);
      body += frozenRows();
      if (uncertain)
        body += `<label class="scope-item"><input type="checkbox" data-iter-verified>我已核对已保存的照片</label>`;
      footer = done
        ? button("open:batch-sync-return", "返回原集合", "primary")
        : running
          ? button("batch:cancel-task", "取消导出")
          : button("open:batch-per-target-discard", "放弃未处理项") +
            button(
              "batch:resume-task",
              id === "batch-per-target-permission"
                ? "重新授权后继续"
                : "只继续未成功项",
              "primary",
              uncertain,
            );
    }
    return {
      body,
      footer,
      sub: id.startsWith("batch-per-target")
        ? "逐张快照 · 不修改目标编辑记录"
        : "同步会保存各照片调整 · 原文件只读",
    };
  }
  function updateContent(id) {
    const mac = ctx.platform === "macos",
      arch = mac
        ? id === "update-install-support-intel"
          ? "Intel · x86_64"
          : "Apple Silicon · arm64"
        : "Windows · x64";
    let body = "",
      footer = "";
    if (
      id === "update-install-support" ||
      id === "update-install-support-intel"
    ) {
      body =
        `<div class="flow-static"><span>当前设备</span><strong>${arch}</strong></div><div class="flow-static"><span>安装方式</span><strong>${mac ? "签名应用 · 同架构更新" : "当前用户 Setup 安装版"}</strong></div>` +
        success(
          "支持应用内更新",
          "自动安装默认关闭，可在软件更新设置中启用。",
        ) +
        link("update-install-unsupported", "其他安装方式的限制") +
        link("update-seed-migration", "从旧版手动迁移");
      footer = button("open:update-settings", "软件更新设置", "primary");
    } else if (
      [
        "update-install-unsupported",
        "update-seed-migration",
        "update-migration-blocked",
      ].includes(id)
    ) {
      body = error(
        id === "update-migration-blocked"
          ? "请先退出旧版 RawLab"
          : "当前版本需要先手动迁移",
        mac
          ? "旧版应用不能自行安装更新。先获取与当前 Mac 架构匹配的签名种子版，之后才可使用应用内更新。"
          : "ZIP / portable 仅支持手动更新。先退出旧版，再安装 x64 当前用户 Setup；旧目录不会自动删除。",
      );
      body +=
        `<ol class="iteration-steps"><li>从官方发布页获取${mac ? "同架构签名 .app" : "x64 Setup"}</li><li>${mac ? "退出旧版，按安装引导替换应用；只读位置需先处理权限" : "退出旧 ZIP 版，再运行当前用户安装程序"}</li><li>启动后核对照片编辑、外观、预设和未完成任务</li></ol>` +
        note(
          mac
            ? "Apple Silicon 使用 arm64，Intel 使用 x86_64；用户数据容器保持。"
            : "安装版继续读取原用户数据；不支持旧 ZIP 与安装版同时写入同一份记录。",
        );
      footer =
        button("close", "稍后") +
        button(
          id === "update-migration-blocked"
            ? "open:update-migration-done"
            : "open:update-migration-blocked",
          id === "update-migration-blocked"
            ? "已退出旧版，继续核对"
            : "查看迁移与核对步骤",
          "primary",
        );
    } else if (id === "update-migration-done") {
      body =
        success(
          "迁移后的数据已核对",
          "照片原文件、编辑记录、导入外观、调整预设和可恢复任务都保留。",
        ) +
        `<div class="flow-static"><span>当前安装</span><strong>${mac ? "签名种子版 · " + arch : "x64 当前用户 Setup"}</strong></div>` +
        note("之后的版本才可使用应用内自动更新；自动安装仍由你在设置中开启。");
      footer = button(
        "update:migration-complete",
        "前往软件更新设置",
        "primary",
      );
    } else if (id === "update-draft-review") {
      body = error(
        "瀑布.ARW 有未应用的几何草稿",
        "先决定草稿，再处理其他照片的保存与进行中的任务；关闭窗口会保留草稿，稍后安装。",
      );
      footer =
        button("update:draft-continue", "继续编辑，稍后安装") +
        button("update:draft-discard", "放弃草稿") +
        button("update:draft-apply", "应用并保存草稿", "primary");
    } else if (id === "update-save-blocked") {
      body = error(
        "林间.ARW 的编辑记录尚未保存",
        "当前调整保留，安装仍被阻挡。重试保存成功后，还需等待正在运行的导出完成。",
      );
      footer =
        button("close", "稍后安装") +
        button("update:retry-save", "重试保存并检查任务", "primary");
    } else if (id === "update-install-gate") {
      body =
        error(
          "安装前还有未完成事项",
          "先完成保存和任务，再选择退出或重启安装。不会强制关闭编辑。",
        ) +
        `<div class="flow-static"><span>瀑布.ARW</span><strong>几何草稿未应用</strong></div><div class="flow-static"><span>林间.ARW</span><strong>编辑记录保存失败</strong></div><div class="flow-static"><span>批量导出</span><strong>3 / 12 张 · 进行中</strong></div>`;
      footer =
        button("close", "稍后") +
        button("update:resolve-gate", "处理草稿与重试保存", "primary");
    } else if (
      [
        "update-restart-failed",
        "update-restored",
        "update-new-edits",
        "update-manual-recovery",
      ].includes(id)
    ) {
      const newer = id === "update-new-edits",
        restored = id === "update-restored";
      body = restored
        ? success(
            "已恢复可启动的可信版本",
            "旧版及对应数据已恢复，新版数据副本继续保留。",
          )
        : error(
            newer
              ? "新版中已有新的编辑"
              : id === "update-manual-recovery"
                ? "保留数据后手动恢复"
                : "新版本未能正常启动",
            newer
              ? "不会自动降级，以免覆盖新格式记录。请先备份，再查看手动恢复步骤。"
              : "原始照片不受影响；恢复应用与数据时，保留新版格式文件副本。",
          );
      body += `<ul class="iteration-checklist"><li>原始照片：保持只读</li><li>旧版编辑记录、外观和预设：对应备份可恢复</li><li>新版格式数据：副本保留，不由旧程序覆盖</li></ul>`;
      if (id === "update-manual-recovery")
        body += `<ol class="iteration-steps"><li>退出 RawLab，保留新版数据副本</li><li>从官方来源获取可信旧版</li><li>使用对应旧版备份，核对记录后再继续编辑</li></ol>`;
      footer = newer
        ? button("close", "继续使用新版") +
          button("open:update-manual-recovery", "查看手动恢复步骤", "primary")
        : restored
          ? button("open:update-manual-recovery", "查看数据副本说明") +
            button("close", "继续使用已恢复版本", "primary")
          : id === "update-manual-recovery"
            ? button("close", "保留当前版本", "primary")
            : button("open:update-manual-recovery", "手动恢复说明") +
              button(
                "open:update-restored",
                "恢复可信旧版与对应备份",
                "primary",
              );
    } else {
      const messages = {
        "update-wrong-arch": [
          "更新包与当前设备不匹配",
          `当前设备：${arch}。没有安装此更新包，请选择匹配的官方版本。`,
        ],
        "update-signature-error": [
          "无法验证更新包",
          "下载内容未通过完整性或发行身份校验，未安装任何内容，现有版本仍可使用。",
        ],
        "update-permission-error": [
          "当前安装位置无法写入",
          mac
            ? "请检查应用所在位置与权限，或移至可写的应用位置后重试。"
            : "请检查当前用户安装目录权限；不要求结束正在运行的导出。",
        ],
        "update-install-recovery": [
          "更新安装未完成",
          "安装已中断，当前可启动版本仍保留。可以重试或继续使用当前版本。",
        ],
      };
      body = error(...(messages[id] || messages["update-install-recovery"]));
      footer =
        button("open:update-manual-recovery", "官方手动更新与恢复") +
        button(
          id === "update-wrong-arch"
            ? "open:update-install-support"
            : "update:retry",
          id === "update-wrong-arch" ? "查看匹配版本" : "处理后重试",
          "primary",
        );
    }
    return { body, footer, sub: "软件更新 · 原文件与用户数据保留" };
  }
  const parents = {
    "copy-source-draft": "copy-scope",
    "copy-source-save-error": "copy-source-draft",
    "copy-ready": "copy-scope",
    "paste-result": "copy-ready",
    "paste-targets": "paste-result",
    "paste-draft": "paste-result",
    "paste-incompatible": "paste-result",
    "paste-partial": "paste-result",
    "paste-done": "paste-result",
    "history-conflict": "history-batch",
    "history-save-error": "history-batch",
    "history-recovered": "history-batch",
    "preset-save": "user-presets",
    "preset-name-error": "user-presets",
    "preset-manage": "user-presets",
    "preset-delete": "preset-manage",
    "preset-duplicate": "preset-save",
    "preset-overwrite": "preset-duplicate",
    "preset-write-error": "preset-save",
    "preset-corrupt": "user-presets",
    "preset-future": "user-presets",
    "preset-missing-look": "user-presets",
    "preset-restored": "user-presets",
    "presets-empty": "user-presets",
    "batch-sync-scope": "batch-sync",
    "batch-sync-preflight": "batch-sync-scope",
    "batch-sync-partial": "batch-sync",
    "batch-sync-success": "batch-sync",
    "batch-sync-return": "batch-sync",
    "batch-sync-unavailable": "batch-sync",
    "batch-edit-save-error": "batch-sync-return",
    "batch-per-target-export": "batch-sync-return",
    "batch-per-target-partial": "batch-per-target-interrupted",
    "batch-per-target-discard": "batch-per-target-interrupted",
    "update-install-support": "update-settings",
    "update-install-support-intel": "update-settings",
    "update-install-unsupported": "update-settings",
    "update-seed-migration": "update-install-unsupported",
    "update-migration-blocked": "update-seed-migration",
    "update-migration-done": "update-settings",
    "update-manual-recovery": "update-install-recovery",
  };
  function rememberExpanded() {
    scopeExpanded = new Set(
      [...document.querySelectorAll("[data-scope-section][open]")].map(
        (el) => el.dataset.scopeSection,
      ),
    );
  }
  function isModified(id) {
    const current = snapshot();
    if (id.startsWith("hsl.")) {
      const [, i, a] = id.split(".").map(Number);
      return current.hsl[i][a] !== 0;
    }
    if (id === "look") return current.film !== "中性" || !!current.recipe;
    if (id === "whiteBalance") return current.whiteBalance !== "拍摄时设置";
    if (id === "curve") return T.isChanged("curve");
    if (id === "lens")
      return (
        !current.lens.autoMatch ||
        current.lens.distortion ||
        current.lens.tca ||
        !current.lens.autoCrop
      );
    return (expandedFields[id] || [id]).some(
      (key) => current.values[key] !== D.defaults[key],
    );
  }
  function savePreset(overwrite = false) {
    const name = presetName.trim();
    if (!name) {
      presetError = "请输入名称，不能只包含空白。";
      open("preset-name-error");
      return;
    }
    const duplicate = presets.find((p) => p.name === name);
    if (duplicate && !overwrite) {
      open("preset-duplicate");
      return;
    }
    const item = {
      id: duplicate?.id || "preset-" + (presets.length + 1),
      name,
      summary: `${scope.size} 项调整 · 不依赖原照片`,
      payload: capture(),
    };
    if (duplicate) Object.assign(duplicate, item);
    else presets.push(item);
    presetError = "";
    selectedPreset = item.id;
    lastOutcome = "预设已保存";
    open("user-presets");
  }
  function beginEdit(id) {
    if (!batchEditing) editReturnSnapshot = snapshot();
    editPhotoId = id;
    batchEditing = true;
    editTemporary = structuredClone(edits.get(id) || snapshot());
    ctx.restore(editTemporary);
    T.restore(editTemporary.curve);
    RawLabDesignFlows.close();
    ctx.gotoTool("light", "exposure");
  }
  function saveReturn() {
    if (ctx.hasDraft()) {
      scopePurpose = "return";
      open("copy-source-draft");
      return;
    }
    const current = snapshot();
    current.tweaked = true;
    edits.set(editPhotoId, current);
    batchEditing = false;
    if (editReturnSnapshot) {
      ctx.restore(editReturnSnapshot);
      T.restore(editReturnSnapshot.curve);
    }
    open("batch-sync-return");
  }
  let outputDestination = "照片图库";
  let outputFormat = "JPEG",
    outputSize = "原始分辨率",
    timer;
  function freezeTask() {
    frozenItems = currentTargets().map((photo, ordinal) => ({
      photo: { ...photo },
      ordinal,
      snapshot: structuredClone(edits.get(photo.id) || snapshot()),
      format: outputFormat,
      size: outputSize,
      destination:
        ctx.platform === "ios"
          ? outputFormat === "DNG"
            ? "文件"
            : "照片图库"
          : ctx.mobile
            ? outputDestination
            : "文件夹",
      status: "waiting",
    }));
  }
  function runTask() {
    if (!frozenItems.length) freezeTask();
    frozenItems.forEach((item) => {
      if (item.status !== "succeeded") item.status = "running";
    });
    open("batch-per-target-running");
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (RawLabDesignFlows.active !== "batch-per-target-running") return;
      if (
        ctx.platform === "ios" &&
        frozenItems.some((item) => item.format === "DNG")
      ) {
        frozenItems.forEach((item) => {
          if (item.status !== "succeeded") item.status = "ready-to-save";
        });
        open("batch-per-target-save-files");
      } else {
        frozenItems.forEach((item) => (item.status = "succeeded"));
        open("batch-per-target-done");
      }
    }, 4500);
  }
  function action(id) {
    if (T.action(id)) return true;
    if (id.startsWith("open:")) {
      const next = id.slice(5);
      if (next === "copy-scope") {
        scopePurpose = "copy";
        presetTarget = false;
      }
      open(next);
      return true;
    }
    if (id === "close") {
      close();
      return true;
    }
    if (id.startsWith("scope:")) {
      scopeMode = id.slice(6);
      if (scopeMode === "all") scope = new Set(allFields.map(([key]) => key));
      else if (scopeMode === "modified")
        scope = new Set(
          allFields
            .map(([key]) => key)
            .filter(
              (key) => !["geometry", "lens"].includes(key) && isModified(key),
            ),
        );
    } else if (id === "capture") {
      if (ctx.hasDraft()) {
        scopePurpose = "copy";
        open("copy-source-draft");
        return true;
      }
      clipboard = capture();
      open("copy-ready");
      return true;
    } else if (id === "draft:cancel") {
      close();
      return true;
    } else if (id === "draft:apply" || id === "draft:discard") {
      ctx.resolveDraft(id === "draft:apply");
      if (scopePurpose === "return") saveReturn();
      else if (scopePurpose === "preset") open("preset-save");
      else {
        clipboard = capture();
        open("copy-ready");
      }
      return true;
    } else if (id === "paste:targets-done") {
      open("paste-result");
      return true;
    } else if (id.startsWith("target-draft:")) {
      if (id.endsWith("skip")) {
        selectedPhotos.delete("photo-2");
        targetDraftOutcome = "林间.ARW 已明确跳过";
      } else {
        if (id.endsWith("apply")) {
          const saved = structuredClone(edits.get("photo-2"));
          saved.values.grain = 15;
          edits.set("photo-2", saved);
        }
        targetDraftOutcome = id.endsWith("apply")
          ? "林间.ARW 草稿已独立保存"
          : "林间.ARW 草稿已放弃，原提交保留";
      }
      if (RawLabDesignFlows.active === "batch-sync-preflight") {
        applyTargets(false);
        open("batch-sync-success");
      } else open("paste-result");
      return true;
    } else if (
      ["paste:apply", "paste:retry", "paste:skip-incompatible"].includes(id)
    ) {
      if (
        id === "paste:apply" &&
        currentTargets().some((p) => p.raster) &&
        (presetTarget ? activePresetPayload : clipboard)?.fields.includes(
          "whiteBalance",
        )
      ) {
        open("paste-incompatible");
        return true;
      }
      applyTargets(
        false,
        id === "paste:retry",
        id === "paste:skip-incompatible",
      );
      lastOutcome =
        id === "paste:skip-incompatible"
          ? "已按确认跳过不兼容范围；其余调整已保存。"
          : `${currentTargets().length} 张目标已保存；未选项保留。`;
      open("paste-done");
      return true;
    } else if (id.startsWith("history:")) {
      const redo = id === "history:redo";
      if (RawLabDesignFlows.active === "history-single") {
        restoreSingle(redo);
        ctx.repaint();
        return true;
      }
      const conflicts = [...results]
        .filter(
          ([photoId, result]) =>
            result.status === "applied" &&
            result.historyState === "applied" &&
            JSON.stringify(edits.get(photoId)) !== JSON.stringify(result.after),
        )
        .map(([photoId]) => photoId);
      if (
        !redo &&
        conflicts.length &&
        id !== "history:skip" &&
        id !== "history:retry"
      ) {
        open("history-conflict");
        return true;
      }
      for (const [photoId, result] of results) {
        if (result.status !== "applied" || conflicts.includes(photoId))
          continue;
        if (
          redo
            ? result.historyState !== "undone"
            : result.historyState !== "applied"
        )
          continue;
        if (result.before && result.after)
          edits.set(
            photoId,
            structuredClone(redo ? result.after : result.before),
          );
        result.historyState = redo ? "applied" : "undone";
      }
      historyUndone = [...results.values()]
        .filter((r) => r.status === "applied")
        .every((r) => r.historyState === "undone");
      if (id === "history:skip" || id === "history:retry")
        open("history-recovered");
      else ctx.repaint();
      return true;
    } else if (id.startsWith("preset:apply:")) {
      const p = presets.find((p) => p.id === id.slice(13));
      if (!p) return true;
      activePresetPayload = structuredClone(p.payload || capture());
      activePresetName = p.name;
      presetTarget = true;
      open("paste-result");
      return true;
    } else if (id.startsWith("preset:manage:")) {
      selectedPreset = id.slice(14);
      renameDraft = null;
      presetError = "";
      open("preset-manage");
      return true;
    } else if (
      ["preset:save", "preset:overwrite", "preset:retry-save"].includes(id)
    ) {
      if (ctx.hasDraft()) {
        scopePurpose = "preset";
        open("copy-source-draft");
        return true;
      }
      savePreset(id === "preset:overwrite");
      return true;
    } else if (id === "preset:save-as") {
      presetName = presetName + " 副本";
      open("preset-save");
      return true;
    } else if (id === "preset:rename") {
      const input = document.querySelector("[data-preset-rename]");
      renameDraft = input.value;
      const name = renameDraft.trim();
      if (
        !name ||
        presets.some((p) => p.id !== selectedPreset && p.name === name)
      )
        presetError = !name ? "名称不能为空。" : "名称已存在，请选择其他名称。";
      else {
        currentPreset().name = name;
        presetError = "";
        open("user-presets");
        return true;
      }
    } else if (id === "preset:delete") {
      const index = presets.findIndex((p) => p.id === selectedPreset);
      if (index >= 0) presets.splice(index, 1);
      open("user-presets");
      return true;
    } else if (id === "preset:restore") {
      open("preset-restored");
      return true;
    } else if (id.startsWith("select:")) {
      const key = id.slice(7);
      selectedPhotos.has(key)
        ? selectedPhotos.delete(key)
        : selectedPhotos.add(key);
    } else if (id === "batch:all")
      selectedPhotos = new Set(
        photos.filter((p) => !p.source).map((p) => p.id),
      );
    else if (id === "batch:none") selectedPhotos.clear();
    else if (id === "batch:scope") {
      clipboard = capture();
      scopePurpose = "batch";
      open("batch-sync-scope");
      return true;
    } else if (id === "sync-preflight") {
      clipboard = capture();
      open("batch-sync-preflight");
      return true;
    } else if (id === "batch:retry") {
      applyTargets(false, true);
      open("batch-sync-success");
      return true;
    } else if (id === "batch:reauthorize") {
      open("batch-sync-scope");
      return true;
    } else if (id === "batch:remove-unavailable") {
      selectedPhotos.delete("photo-2");
      open("batch-sync");
      return true;
    } else if (id.startsWith("edit:")) {
      beginEdit(id.slice(5));
      return true;
    } else if (id === "batch:continue-edit") {
      RawLabDesignFlows.close();
      ctx.repaint();
      return true;
    } else if (id === "batch:save-return") {
      saveReturn();
      return true;
    } else if (id === "batch:old-export") {
      RawLabDesignFlows.open("batch-select");
      ctx.repaint();
      return true;
    } else if (id === "batch:freeze") {
      freezeTask();
      runTask();
      return true;
    } else if (id === "batch:resume-task") {
      if (RawLabDesignFlows.active === "batch-per-target-permission") {
        open("destination");
        return true;
      }
      runTask();
      return true;
    } else if (id === "batch:cancel-task") {
      clearTimeout(timer);
      frozenItems.forEach((item) => {
        if (item.status !== "succeeded") item.status = "cancelled";
      });
      open("batch-per-target-cancelled");
      return true;
    } else if (id === "batch:discard-task") {
      clearTimeout(timer);
      discardedCount = frozenItems.filter(
        (item) => item.status !== "succeeded",
      ).length;
      frozenItems.forEach((item) => {
        if (item.status !== "succeeded") item.status = "discarded";
      });
      open("batch-per-target-discarded");
      return true;
    } else if (id === "update:migration-complete") {
      migrationDone = true;
      installKind = "supported";
      open("update-settings");
      return true;
    } else if (id === "update:resolve-gate") {
      open("update-draft-review");
      return true;
    } else if (id.startsWith("update:draft-")) {
      if (id === "update:draft-continue") {
        close();
        return true;
      }
      ctx.resolveDraft(id === "update:draft-apply");
      open("update-save-blocked");
      return true;
    } else if (id === "update:retry-save") {
      RawLabDesignFlows.close();
      ctx.gotoScene("updating-wait");
      return true;
    } else if (id === "update:retry") {
      RawLabDesignFlows.close();
      ctx.gotoScene("update");
      ctx.startUpdateRetry();
      return true;
    } else return false;
    ctx.repaint();
    return true;
  }
  function onOpen(id, options = {}) {
    if (id === "copy-scope") {
      scopePurpose = "copy";
      presetTarget = false;
    }
    if (id.startsWith("batch-sync")) presetTarget = false;
    if (id === "update-install-unsupported" || id === "update-seed-migration")
      installKind = "legacy";
    if (id === "update-install-support") installKind = "supported";
    if (!options.seed) return;
    if (id === "presets-empty") presets.splice(0);
    if (["copy-source-draft", "copy-source-save-error"].includes(id))
      scopePurpose = "copy";
    if (id === "preset-name-error") {
      presetName = "";
      presetError = "请输入名称，不能只包含空白。";
    }
    if (id === "preset-duplicate" || id === "preset-overwrite")
      presetName = "森林柔光";
    if (id.startsWith("paste-")) {
      clipboard = capture();
      if (id === "paste-incompatible") selectedPhotos.add("photo-4");
    }
    if (id === "paste-partial" || id === "batch-sync-partial")
      applyTargets(true);
    if (id === "paste-done" || id === "batch-sync-success") applyTargets(false);
    if (
      ["history-batch", "history-conflict", "history-save-error"].includes(id)
    )
      applyTargets(false);
    if (id === "history-conflict") {
      const changed = structuredClone(edits.get("photo-2"));
      changed.values.exposure = 1.7;
      edits.set("photo-2", changed);
    }
    if (id === "history-save-error")
      for (const [photoId, result] of results)
        if (photoId !== "photo-2" && result.before) {
          edits.set(photoId, structuredClone(result.before));
          result.historyState = "undone";
        }
    if (id === "batch-sync-empty") selectedPhotos.clear();
    if (id.startsWith("batch-per-target")) {
      if (id === "batch-per-target-save-files") outputFormat = "DNG";
      freezeTask();
      frozenItems.forEach(
        (item, i) =>
          (item.status =
            id === "batch-per-target-done" || i === 0
              ? "succeeded"
              : id === "batch-per-target-partial" && i === 1
                ? "failed"
                : "waiting"),
      );
    }
    if (id === "batch-per-target-discarded") {
      discardedCount = frozenItems.filter(
        (item) => item.status !== "succeeded",
      ).length;
      frozenItems.forEach((item) => {
        if (item.status !== "succeeded") item.status = "discarded";
      });
    }
    if (id === "batch-per-target-save-files")
      frozenItems.forEach((item) => (item.status = "ready-to-save"));
    if (id === "batch-edit-save-error") batchEditing = true;
  }
  function attach(context) {
    ctx = context;
    T.attach(context);
    if (!edits.size) {
      for (const [i, p] of photos.entries()) {
        const base = snapshot();
        base.values.exposure =
          i === 0 ? base.values.exposure : [0, 0.1, -0.15, 0.3, 0][i];
        edits.set(p.id, base);
      }
      presets.forEach((p) => (p.payload = capture()));
      if (presets[0]) {
        presets[0].payload.fields = [
          "exposure",
          "contrast",
          "saturation",
          "vibrance",
          ...hslFields.map(([id]) => id),
        ];
        presets[0].payload.snapshot.values.vibrance = 8;
      }
      if (presets[1])
        presets[1].payload.fields = ["whiteBalance", "vibrance", "grading"];
      if (presets[2])
        presets[2].payload.fields = [
          "exposure",
          "contrast",
          "saturation",
          "grain",
        ];
      if (presets[1])
        Object.assign(presets[1].payload.snapshot.values, {
          highHue: 45,
          highSat: 18,
          vibrance: 12,
        });
      if (presets[2])
        Object.assign(presets[2].payload.snapshot.values, {
          saturation: -100,
          grain: 20,
        });
      singleAfter = snapshot();
      singleBefore = structuredClone(singleAfter);
      singleBefore.hsl = D.palettes.map(() => [0, 0, 0]);
    }
  }
  function beforeEdit() {
    if (!pendingBefore) pendingBefore = snapshot();
  }
  function afterEdit() {
    if (!pendingBefore) return;
    const next = snapshot();
    if (JSON.stringify(pendingBefore) === JSON.stringify(next)) {
      pendingBefore = null;
      return;
    }
    singleBefore = pendingBefore;
    singleAfter = next;
    pendingBefore = null;
    historyUndone = false;
    ctx.setCanRedo(false);
  }
  function restoreSingle(redo) {
    const s = redo ? singleAfter : singleBefore;
    if (s) {
      ctx.restore(s);
      T.restore(s.curve);
    }
    historyUndone = !redo;
    ctx.setCanRedo(!redo);
  }
  function handleInput(e) {
    if (e.target.matches("[data-preset-rename]")) {
      renameDraft = e.target.value;
      return true;
    }
    if (e.target.matches("[data-preset-name]")) {
      presetName = e.target.value;
      presetError = "";
      return true;
    }
    if (e.target.dataset.iterOption) {
      if (e.target.dataset.iterOption === "format") {
        outputFormat = e.target.value;
        if (outputFormat === "DNG") outputDestination = "文件夹";
      }
      if (e.target.dataset.iterOption === "size") outputSize = e.target.value;
      if (e.target.dataset.iterOption === "destination")
        outputDestination = e.target.value;
      ctx.repaint();
      return true;
    }
    return false;
  }
  function handleChange(e) {
    if (e.target.dataset.scopeField) {
      rememberExpanded();
      scopeMode = "custom";
      e.target.checked
        ? scope.add(e.target.dataset.scopeField)
        : scope.delete(e.target.dataset.scopeField);
      ctx.repaint();
      return true;
    }
    if (e.target.dataset.scopeGroup) {
      rememberExpanded();
      scopeMode = "custom";
      const group = fieldGroups.find(
        ([id]) => id === e.target.dataset.scopeGroup,
      );
      group[2].forEach(([key]) =>
        e.target.checked ? scope.add(key) : scope.delete(key),
      );
      ctx.repaint();
      return true;
    }
    if (e.target.dataset.iterPhoto) {
      e.target.checked
        ? selectedPhotos.add(e.target.dataset.iterPhoto)
        : selectedPhotos.delete(e.target.dataset.iterPhoto);
      ctx.repaint();
      return true;
    }
    if (e.target.matches("[data-iter-verified]")) {
      document.querySelector('[data-iter="batch:resume-task"]').disabled =
        !e.target.checked;
      return true;
    }
    return handleInput(e);
  }
  function updateFrame(id, context) {
    const result = content(id);
    return `<div class="update-backdrop"></div><section data-flow-view="${id}" class="update-window iteration-update-window" role="dialog" aria-modal="true" aria-label="${D.iterationFlowTitles[id]}" tabindex="-1">${context.windowTitlebar(D.iterationFlowTitles[id], "iteration-close")}<div class="flow-body">${result.body}</div><div class="update-actions">${result.footer}</div></section>`;
  }
  return {
    attach,
    content,
    onOpen,
    updateFrame,
    destinationSelected(returnId) {
      if (returnId === "batch-per-target-save-files") {
        frozenItems.forEach((item) => {
          if (item.status !== "discarded") item.status = "succeeded";
        });
        open("batch-per-target-done");
      } else if (returnId === "batch-per-target-permission") runTask();
      else open(returnId);
    },
    handleInput,
    handleChange,
    beforeEdit,
    afterEdit,
    cancelEdit: () => {
      pendingBefore = null;
    },
    hasFlow: (id) => !!D.iterationFlowTitles[id],
    parentOf: (id) =>
      id === "paste-result" && presetTarget
        ? "user-presets"
        : parents[id] || null,
    handleClick(e) {
      const button = e.target.closest("[data-iter]");
      return button ? action(button.dataset.iter) : false;
    },
    handleAction(id) {
      if (id === "iteration-close") {
        close();
        return true;
      }
      if (id === "undo" || id === "redo") {
        restoreSingle(id === "redo");
        ctx.repaint();
        return true;
      }
      return false;
    },
    onScene(id) {
      T.onScene(id);
      if (id === "batch-edit-photo") beginEdit("photo-1");
    },
    tools: T,
    activeTarget: T.activeTarget,
    panel(tool) {
      return tool === "user-presets"
        ? presetList(false, true)
        : T.renderPanel(tool);
    },
    handlesTool: (tool) => tool === "user-presets" || T.handlesTool(tool),
    canvasOverlay() {
      return batchEditing
        ? `<div class="batch-edit-return"><span><strong>${photos.find((p) => p.id === editPhotoId)?.name}</strong><small>集合选择与其他照片保持</small></span>${button("batch:save-return", "保存并返回集合", "primary")}</div>`
        : "";
    },
    currentName: () =>
      batchEditing ? photos.find((p) => p.id === editPhotoId)?.name : null,
    canPaste: () => !!clipboard,
    installSupport: () => installKind === "supported" || migrationDone,
    prepareCopy() {
      presetTarget = false;
      scopePurpose = "copy";
      open("copy-scope");
    },
    inspect: () => ({
      selected: [...selectedPhotos],
      targets: currentTargets().map((p) => p.id),
      results: [...results],
      edits: [...edits],
      clipboard: structuredClone(clipboard),
      frozenItems: structuredClone(frozenItems),
      presets: structuredClone(presets),
      batchEditing,
    }),
  };
})();
