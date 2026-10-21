// 本轮新增设计的场景目录；只登记可实际打开的稿件，不代表原生实现。
(() => {
  const D = RawLabDesign;
  D.tools.looks.push(["user-presets", "我的预设"]);
  D.tools.light.splice(4, 0, ["black-white", "黑场与白场"]);
  D.tools.light.find(([id]) => id === "curve")[1] = "曲线";
  D.tools.color.splice(2, 0, ["vibrance", "鲜艳度"]);
  D.tools.color.push(["color-grading", "颜色分级"]);
  D.tools.effects.unshift(["clarity", "清晰度"], ["dehaze", "去朦胧"]);
  const fields = {
    blackPoint: 0,
    whitePoint: 0,
    vibrance: 0,
    clarity: 0,
    dehaze: 0,
    shadowHue: 0,
    shadowSat: 0,
    midHue: 0,
    midSat: 0,
    highHue: 0,
    highSat: 0,
    curveX: 50,
    curveY: 50,
  };
  Object.assign(D.defaults, fields);
  Object.assign(D.fixture, fields);
  D.iterationToolIds = [
    "user-presets",
    "black-white",
    "vibrance",
    "color-grading",
    "clarity",
    "dehaze",
  ];
  D.iterationFlowTitles = {};
  D.iterationWorkspace = {};
  D.iterationScenes = [];
  D.iterationStateKinds = {};
  const all = ["ios", "android", "macos", "windows"];
  const catalog = [
    [
      "ITER-03",
      "调整复制与粘贴",
      "调整复用",
      [
        ["copy-scope", "复制调整 · 选择范围", "normal"],
        ["copy-source-draft", "复制前 · 处理来源草稿", "error"],
        ["copy-source-save-error", "来源调整保存失败", "error"],
        ["copy-ready", "调整已复制", "recovery"],
        ["paste-empty", "粘贴 · 尚未复制调整", "error"],
        ["paste-result", "粘贴调整 · 预检", "normal"],
        ["paste-targets", "粘贴调整 · 选择目标", "normal"],
        ["paste-draft", "粘贴前 · 目标草稿", "error"],
        ["target-draft-save-error", "目标草稿 · 保存失败", "error"],
        ["paste-incompatible", "粘贴 · 不兼容项", "error"],
        ["paste-partial", "粘贴 · 部分保存失败", "error"],
        ["paste-done", "粘贴 · 保存完成", "recovery"],
        ["history-single", "当前照片 · 撤销与重做", "normal"],
        ["history-batch", "整批操作历史", "normal"],
        ["history-conflict", "撤销 · 后续编辑冲突", "error"],
        ["history-save-error", "撤销 · 保存失败", "error"],
        ["history-recovered", "撤销 · 成功子集已恢复", "recovery"],
      ],
    ],
    [
      "ITER-04",
      "我的调整预设",
      "调整复用",
      [
        ["user-presets", "我的预设 · 列表", "normal"],
        ["presets-empty", "我的预设 · 空列表", "normal"],
        ["preset-save", "保存调整预设", "normal"],
        ["preset-name-error", "预设 · 名称不能为空", "error"],
        ["preset-duplicate", "预设 · 名称已存在", "error"],
        ["preset-overwrite", "预设 · 覆盖确认", "normal"],
        ["preset-manage", "预设 · 管理", "normal"],
        ["preset-delete", "预设 · 删除确认", "normal"],
        ["preset-write-error", "预设 · 保存失败", "error"],
        ["preset-corrupt", "预设库 · 损坏与恢复", "error"],
        ["preset-future", "预设 · 来自更新版本", "error"],
        ["preset-missing-look", "预设 · 外观缺失", "error"],
        ["preset-restored", "预设库 · 恢复完成", "recovery"],
      ],
    ],
    [
      "ITER-08",
      "批量同步与逐张微调",
      "批量编辑",
      [
        ["batch-sync", "批量编辑 · 照片集合", "normal"],
        ["batch-sync-empty", "批量编辑 · 尚无目标", "normal"],
        ["batch-sync-scope", "同步调整 · 选择范围", "normal"],
        ["batch-sync-preflight", "同步前 · 草稿与保存", "error"],
        ["batch-sync-unavailable", "同步 · 照片访问失效", "error"],
        ["batch-sync-partial", "同步 · 部分保存失败", "error"],
        ["batch-sync-success", "同步 · 保存完成", "recovery"],
        ["batch-edit-photo", "批量集合 · 单张微调", "normal"],
        ["batch-edit-save-error", "单张微调 · 保存失败", "error"],
        ["batch-sync-return", "返回集合 · 保留逐张调整", "recovery"],
        ["batch-per-target-export", "逐张参数 · 导出确认", "normal"],
        ["batch-per-target-running", "逐张参数 · 正在导出", "normal"],
        [
          "batch-per-target-save-files",
          "逐张 DNG · 保存文件",
          "normal",
          ["ios"],
        ],
        ["batch-per-target-partial", "逐张导出 · 部分失败", "error"],
        ["batch-per-target-cancelled", "逐张导出 · 已取消", "error"],
        ["batch-per-target-interrupted", "逐张导出 · 恢复任务", "recovery"],
        ["batch-per-target-permission", "逐张导出 · 输出权限失效", "error"],
        [
          "batch-per-target-uncertain",
          "逐张导出 · 核对保存结果",
          "error",
          ["ios", "android"],
        ],
        ["batch-per-target-discard", "放弃未处理照片", "normal"],
        ["batch-per-target-discarded", "未处理项已放弃", "recovery"],
        ["batch-per-target-done", "逐张导出 · 完成", "recovery"],
      ],
    ],
    [
      "ITER-09",
      "曲线模式确认",
      "编辑工具",
      [
        ["curve-mode-confirm", "曲线 · 切换模式确认", "normal"],
        ["curve-mode-conflict", "曲线 · 模式冲突", "error"],
      ],
    ],
    [
      "ITER-11",
      "桌面更新 · 安装与恢复",
      "桌面更新",
      [
        ["update-install-support", "更新 · 当前安装支持", "normal"],
        [
          "update-install-support-intel",
          "更新 · Intel Mac 安装支持",
          "normal",
          ["macos"],
        ],
        ["update-install-unsupported", "更新 · 当前安装仅支持手动", "error"],
        ["update-seed-migration", "更新 · 手动迁移种子版", "normal"],
        ["update-migration-blocked", "迁移 · 旧版仍在运行", "error"],
        ["update-migration-done", "迁移 · 数据核对完成", "recovery"],
        ["update-wrong-arch", "更新 · 架构不匹配", "error"],
        ["update-signature-error", "更新 · 无法验证安装包", "error"],
        ["update-permission-error", "更新 · 安装权限不足", "error"],
        ["update-install-gate", "更新 · 处理草稿与保存", "error"],
        ["update-draft-review", "安装前 · 处理未应用草稿", "normal"],
        ["update-save-blocked", "安装前 · 编辑保存失败", "error"],
        ["update-install-recovery", "更新 · 安装中断", "error"],
        ["update-restart-failed", "更新 · 新版启动失败", "error"],
        ["update-restored", "更新 · 旧版与数据已恢复", "recovery"],
        ["update-new-edits", "更新 · 新版已有编辑", "error"],
        ["update-manual-recovery", "更新 · 保留数据手动恢复", "recovery"],
      ],
    ],
  ];
  for (const [iteration, title, area, entries] of catalog) {
    const platforms = iteration === "ITER-11" ? ["macos", "windows"] : all;
    const statePlatforms = {};
    for (const [id, label, kind, only] of entries) {
      D.iterationFlowTitles[id] = label;
      D.iterationStateKinds[id] = kind;
      if (only) statePlatforms[id] = only;
      D.descriptions[id] = [
        label,
        `${title}的${kind === "error" ? "异常" : kind === "recovery" ? "恢复" : "正常"}状态。设计交互使用本地示例，未连接照片处理、持久化或安装。`,
        [
          "从主动作走到下一步，也可返回原状态",
          "取消不覆盖已保存调整；失败目标与成功目标分别呈现",
          "四端共用语义，按平台使用原有布局和输入控件",
        ],
      ];
    }
    D.iterationScenes.push({
      id: iteration.toLowerCase(),
      iteration,
      title,
      area,
      platforms,
      states: entries.map(([id]) => id),
      statePlatforms,
      scope: "proposed",
      source: "本次迭代总需求 · " + iteration,
    });
  }
  for (const [iteration, tool, group] of [
    ["ITER-05", "black-white", "light"],
    ["ITER-05", "vibrance", "color"],
    ["ITER-06", "color-grading", "color"],
    ["ITER-09", "custom-curve", "light"],
    ["ITER-10", "clarity", "effects"],
    ["ITER-10", "dehaze", "effects"],
  ]) {
    const name =
      tool === "custom-curve"
        ? "多点曲线"
        : D.tools[group].find(([id]) => id === tool)[1];
    const states = [];
    for (const [suffix, label, status] of [
      ["", "", "normal"],
      ["-input-error", " · 非法输入", "input-error"],
      ["-preview-error", " · 预览失败", "preview-error"],
      ["-save-error", " · 调整未保存", "save-error"],
      ["-recovered", " · 重试完成", "recovered"],
    ]) {
      const id = suffix ? tool + suffix : "tool-" + tool;
      states.push(id);
      D.iterationStateKinds[id] =
        status === "normal"
          ? "normal"
          : status === "recovered"
            ? "recovery"
            : "error";
      D.iterationWorkspace[id] = {
        tool: tool === "custom-curve" ? "curve" : tool,
        group,
        status,
        customCurve: tool === "custom-curve",
      };
      D.descriptions[id] = [
        name + label,
        "在现有固定调整区内操作，照片和面板高度保持。参数只用于交互评审，不证明新算法或画质已经实现。",
        [
          "复用平台精确输入、范围重置和已有保存提示",
          "预览失败保留参数和最后有效照片，保存失败单独提示",
          "重试回到原工具，不跳到 HSL 或其他分组",
        ],
      ];
    }
    if (["clarity", "dehaze"].includes(tool)) {
      const id = tool + "-gpu-error";
      states.push(id);
      D.iterationStateKinds[id] = "error";
      D.iterationWorkspace[id] = { tool, group, status: "gpu-error" };
      D.descriptions[id] = [
        name + " · 后端不可用",
        "保留参数和最后有效预览；Force 不伪装成功，可明确选择 Auto 后重试。",
        [
          "切到 Auto 后才显示 CPU 回退结果",
          "iOS/macOS 此页为错误注入稿，不新增 Force 设置",
        ],
      ];
    }
    D.iterationScenes.push({
      id: "new-" + tool,
      iteration,
      title: name + " · 状态",
      area: "新增调色",
      platforms: all,
      states,
      scope: "proposed",
      source: "本次迭代总需求 · " + iteration,
    });
  }
  const targetStates = [
    "hsl-target",
    "hsl-target-drag",
    "hsl-target-invalid",
    "hsl-target-stale",
    "hsl-target-cancelled",
  ];
  for (const id of targetStates) {
    D.iterationStateKinds[id] =
      id === "hsl-target-cancelled"
        ? "recovery"
        : ["hsl-target-invalid", "hsl-target-stale"].includes(id)
          ? "error"
          : "normal";
    D.iterationWorkspace[id] = {
      group: "color",
      tool: "hsl",
      status: id,
      target: true,
    };
    D.descriptions[id] = [
      {
        "hsl-target": "HSL · 图片目标调整",
        "hsl-target-drag": "HSL · 拖动与相邻色域",
        "hsl-target-invalid": "HSL · 近灰/边界不可取样",
        "hsl-target-stale": "HSL · 预览过期",
        "hsl-target-cancelled": "HSL · 手势已取消",
      }[id],
      "取色和受影响色域在原型中是明确的示例反馈，不能用于评价实际像素取样或 HSL 算法。",
      [
        "选轴后在照片区域取样、拖动；多指/后台/切图取消",
        "一次手势从冻结起点计算，取消恢复原值",
        "目标模式优先于按住对比和移动端纯预览",
      ],
    ];
  }
  D.iterationScenes.push({
    id: "target-hsl",
    iteration: "ITER-07",
    title: "HSL 目标调整",
    area: "新增调色",
    platforms: all,
    states: targetStates,
    scope: "proposed",
    source: "本次迭代总需求 · ITER-07",
  });
  delete D.iterationFlowTitles["batch-edit-photo"];
  D.iterationWorkspace["batch-edit-photo"] = {
    group: "light",
    tool: "exposure",
    status: "normal",
    batchEdit: true,
  };
})();
