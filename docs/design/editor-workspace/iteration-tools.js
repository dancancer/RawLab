// 调色控件的交互示意。曲线图与色轮仅表达输入，不渲染照片。
window.RawLabIterationTools = (() => {
  const D = RawLabDesign;
  let ctx,
    zone = "mid",
    mode = "legacy",
    selected = 1,
    previousScalar = 0;
  let points = [
      [0, 0],
      [0.5, 0.5],
      [1, 1],
    ],
    status = "normal",
    statusTool = null,
    drag = null;
  let target = false,
    axis = 0,
    sampleStatus = "ready",
    sample = { x: 0.52, y: 0.48 };
  const zones = [
    ["shadow", "阴影"],
    ["mid", "中间调"],
    ["high", "高光"],
  ];
  const fields = {
    "black-white": ["blackPoint", "whitePoint"],
    vibrance: ["vibrance"],
    clarity: ["clarity"],
    dehaze: ["dehaze"],
    "color-grading": zones.flatMap(([z]) => [z + "Hue", z + "Sat"]),
  };
  const button = (action, text, style = "secondary", disabled = false) =>
    `<button class="${style}" data-iter="${action}" ${disabled ? "disabled" : ""}>${text}</button>`;
  const show = () => ctx.repaint();
  const openFlow = (id) => {
    RawLabDesignFlows.open(id);
    show();
  };
  function syncPoint() {
    ctx.values.curveX = Math.round(points[selected][0] * 100);
    ctx.values.curveY = Math.round(points[selected][1] * 100);
  }
  function errorStatus(tool) {
    if (statusTool && statusTool !== tool) return "";
    const map = {
      "input-error": [
        "输入未提交",
        "数值不合法，原参数保持。请使用合法范围与步进重新输入。",
        "tool:correct-input",
        "重新输入",
      ],
      "preview-error": [
        "预览更新失败",
        "保留上一次有效照片和当前参数；调整尚未丢失。",
        "tool:retry",
        "重试预览",
      ],
      "save-error": [
        "调整未保存",
        "预览完成不代表保存成功，当前参数保留，可重试。",
        "tool:retry",
        "重试保存",
      ],
      "gpu-error": [
        "当前处理后端不可用",
        "此强制后端没有完成处理，未伪装为成功；可明确切换 Auto 后重试。",
        "tool:auto",
        "切换 Auto 并重试",
      ],
    };
    const e = map[status];
    if (e)
      return `<div class="tool-status error" role="status"><strong>${e[0]}</strong><p>${e[1]}</p>${button(e[2], e[3], "quiet")}</div>`;
    return status === "recovered"
      ? '<p class="tool-status" role="status">已完成重试，参数和当前工具保持。</p>'
      : "";
  }
  function wheel() {
    const hue = ctx.values[zone + "Hue"],
      sat = ctx.values[zone + "Sat"];
    const angle = (hue / 180) * Math.PI,
      x = 50 + Math.cos(angle) * sat * 0.45,
      y = 50 + Math.sin(angle) * sat * 0.45;
    return `<div class="grading-wheel" data-grade-wheel tabindex="0" role="slider" aria-label="${zones.find(([z]) => z === zone)[1]}色轮" aria-valuetext="色相 ${hue} 度，饱和度 ${sat}"><span class="grading-handle" style="left:${x}%;top:${y}%"></span></div>`;
  }
  function curveGraph() {
    const coords = points.map(([x, y]) => [x * 300, (1 - y) * 140]);
    let path = `M${coords[0].join(" ")}`;
    for (let i = 1; i < coords.length; i++) {
      const a = coords[i - 1],
        b = coords[i],
        dx = (b[0] - a[0]) / 3;
      path += `C${a[0] + dx} ${a[1]} ${b[0] - dx} ${b[1]} ${b[0]} ${b[1]}`;
    }
    return `<div class="curve-plot"><svg viewBox="0 0 300 140" preserveAspectRatio="none" aria-hidden="true"><path class="curve-grid" d="M75 0V140M150 0V140M225 0V140M0 35H300M0 70H300M0 105H300"/><path class="curve-identity" d="M0 140L300 0"/><path class="curve-line" d="${path}"/></svg>${points.map(([x, y], i) => `<button class="curve-point ${i === selected ? "selected" : ""}" style="left:${x * 100}%;top:${(1 - y) * 100}%" data-curve-point="${i}" aria-label="控制点 ${i + 1}，输入 ${Math.round(x * 100)}，输出 ${Math.round(y * 100)}${i === 0 || i === points.length - 1 ? "，固定端点" : ""}" aria-pressed="${i === selected}"><i></i></button>`).join("")}</div>`;
  }
  function renderPanel(tool) {
    if (tool === "hsl") return "";
    let body = "";
    if (tool === "black-white")
      body = `<div class="scalar-layout">${ctx.axis("黑场", ctx.values.blackPoint, "blackPoint")}${ctx.axis("白场", ctx.values.whitePoint, "whitePoint")}</div>`;
    else if (["vibrance", "clarity", "dehaze"].includes(tool))
      body = `<div class="scalar-layout">${ctx.axis({ vibrance: "鲜艳度", clarity: "清晰度", dehaze: "去朦胧" }[tool], ctx.values[tool], tool)}<p class="tool-hint">${{ vibrance: "与饱和度独立；正向优先增强较低饱和颜色。", clarity: "正向增加中尺度层次，负向柔化；与锐化独立。", dehaze: "正向减雾、负向增雾；与全局对比独立。" }[tool]}</p></div>`;
    else if (tool === "color-grading") {
      body = `<div class="iteration-segments grading-zones" role="group" aria-label="颜色分级明暗分区">${zones.map(([id, name]) => `<button data-iter="tool:zone:${id}" aria-pressed="${zone === id}">${name}${ctx.values[id + "Hue"] || ctx.values[id + "Sat"] ? '<i class="tab-dot"></i>' : ""}</button>`).join("")}</div><div class="grading-layout">${wheel()}<div>${ctx.axis("色相", ctx.values[zone + "Hue"], zone + "Hue", 0, 360, 1)}${ctx.axis("饱和度", ctx.values[zone + "Sat"], zone + "Sat", 0, 100, 1)}</div></div><button class="quiet" data-iter="tool:reset-zone">重置当前${zones.find(([z]) => z === zone)[1]}</button>`;
    } else if (tool === "curve") {
      body = `<div class="iteration-segments" role="group" aria-label="曲线模式"><button data-iter="tool:mode:legacy" aria-pressed="${mode === "legacy"}">S 曲线</button><button data-iter="tool:mode:custom" aria-pressed="${mode === "custom"}">多点曲线</button></div>`;
      if (mode === "legacy")
        body += `<div class="scalar-layout">${ctx.axis("S 曲线", ctx.values.curve, "curve")}<p class="tool-hint">沿用旧照片和配方的 S 曲线；切换模式需单独确认。</p></div>`;
      else {
        syncPoint();
        const locked = selected === 0 || selected === points.length - 1;
        body += `<div class="custom-curve-layout">${curveGraph()}<div class="curve-coordinates">${locked ? '<p class="tool-hint">固定端点：' + (selected === 0 ? "(0, 0)" : "(100, 100)") + "</p>" : ctx.axis("输入", ctx.values.curveX, "curveX", Math.round(points[selected - 1][0] * 100) + 1, Math.round(points[selected + 1][0] * 100) - 1, 1) + ctx.axis("输出", ctx.values.curveY, "curveY", Math.round(points[selected - 1][1] * 100), Math.round(points[selected + 1][1] * 100), 1)}<div class="iteration-inline">${button("tool:add-point", "增加控制点", "secondary", points.length >= 33)}${button("tool:delete-point", "删除当前点", "secondary", locked)}${button("tool:reset-curve", "恢复直线", "quiet")}</div></div></div>`;
      }
    }
    return errorStatus(tool) + body;
  }
  function targetToolbar() {
    if (!target) return "";
    return `<div class="target-tools"><div class="iteration-segments" aria-label="目标调整轴">${["色相", "饱和度", "明度"].map((n, i) => `<button data-iter="tool:target-axis:${i}" aria-pressed="${axis === i}">${n}</button>`).join("")}</div>${button("tool:target", "退出取色", "quiet")}</div>`;
  }
  function overlay() {
    if (!target) return "";
    const text = {
      ready: "在照片中取样，拖动调整选中轴",
      dragging: "取色示例 · 绿色 80% / 青色 20%",
      invalid: "此位置近灰或不在照片内，未改动参数",
      stale: "预览已过期，等待更新后重新取样",
      cancelled: "已取消，手势前参数已恢复",
    }[sampleStatus];
    return `<div class="target-overlay" aria-live="polite"><div class="target-message">${text}${sampleStatus === "stale" ? button("tool:refresh-target", "更新后重新取样", "quiet") : ""}</div>${["ready", "dragging"].includes(sampleStatus) ? `<div class="target-reticle" data-target-sample tabindex="0" role="slider" aria-label="取色示例，方向键调整所选轴，Escape 退出" aria-valuetext="绿色80%，青色20%" style="left:${sample.x * 100}%;top:${sample.y * 100}%"><i></i><span>取色示例</span></div>` : ""}</div>`;
  }
  function cancelGesture() {
    if (!drag) return false;
    if (drag.kind === "target") {
      ctx.setHsl(structuredClone(drag.before));
      sampleStatus = "cancelled";
    } else if (drag.kind === "curve") points = structuredClone(drag.before);
    else if (drag.kind === "wheel") {
      ctx.values[zone + "Hue"] = drag.before[0];
      ctx.values[zone + "Sat"] = drag.before[1];
    }
    drag = null;
    ctx.cancelEdit();
    return true;
  }
  function pointerDown(e) {
    if (drag && !e.isPrimary) {
      cancelGesture();
      show();
      return true;
    }
    const wheelEl = e.target.closest("[data-grade-wheel]"),
      point = e.target.closest("[data-curve-point]");
    if (wheelEl)
      drag = {
        kind: "wheel",
        id: e.pointerId,
        rect: wheelEl.getBoundingClientRect(),
        before: [ctx.values[zone + "Hue"], ctx.values[zone + "Sat"]],
      };
    else if (point) {
      selected = Number(point.dataset.curvePoint);
      if (selected === 0 || selected === points.length - 1) {
        show();
        return true;
      }
      drag = {
        kind: "curve",
        id: e.pointerId,
        rect: point.closest(".curve-plot").getBoundingClientRect(),
        before: structuredClone(points),
      };
    } else if (
      target &&
      e.target.closest(".canvas") &&
      !e.target.closest("button,input,.histogram,.photo-info")
    ) {
      if (!e.isPrimary) {
        cancelGesture();
        show();
        return true;
      }
      const rect = document
        .querySelector("[data-photo-frame]")
        ?.getBoundingClientRect();
      if (
        !rect ||
        e.clientX < rect.left ||
        e.clientX > rect.right ||
        e.clientY < rect.top ||
        e.clientY > rect.bottom
      ) {
        sampleStatus = "invalid";
        show();
        return true;
      }
      sample = {
        x: (e.clientX - rect.left) / rect.width,
        y: (e.clientY - rect.top) / rect.height,
      };
      if (sampleStatus === "stale") {
        show();
        return true;
      }
      drag = {
        kind: "target",
        id: e.pointerId,
        y: e.clientY,
        before: structuredClone(ctx.getHsl()),
        axis,
      };
      sampleStatus = "dragging";
    } else return false;
    e.preventDefault();
    ctx.beginEdit();
    if (e.isTrusted)
      document.querySelector("#app").setPointerCapture(e.pointerId);
    if (drag.kind !== "curve") pointerMove(e);
    return true;
  }
  function pointerMove(e) {
    if (!drag || drag.id !== e.pointerId) return false;
    if (drag.kind === "wheel") {
      const x = (e.clientX - drag.rect.left) / drag.rect.width - 0.5,
        y = (e.clientY - drag.rect.top) / drag.rect.height - 0.5;
      ctx.values[zone + "Hue"] = Math.round(
        ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360,
      );
      ctx.values[zone + "Sat"] = Math.min(
        100,
        Math.round((Math.hypot(x, y) / 0.45) * 100),
      );
    } else if (drag.kind === "curve") {
      const x =
        Math.round(((e.clientX - drag.rect.left) / drag.rect.width) * 100) /
        100;
      const y =
        Math.round((1 - (e.clientY - drag.rect.top) / drag.rect.height) * 100) /
        100;
      points[selected] = [
        Math.min(
          points[selected + 1][0] - 0.01,
          Math.max(points[selected - 1][0] + 0.01, x),
        ),
        Math.min(points[selected + 1][1], Math.max(points[selected - 1][1], y)),
      ];
    } else {
      const delta = (drag.y - e.clientY) / 2,
        next = structuredClone(drag.before);
      [3, 4].forEach(
        (band, i) =>
          (next[band][drag.axis] = Math.max(
            -100,
            Math.min(
              100,
              Math.round(
                (drag.before[band][drag.axis] + delta * [0.8, 0.2][i]) * 10,
              ) / 10,
            ),
          )),
      );
      ctx.setHsl(next);
    }
    show();
    return true;
  }
  function pointerUp(e) {
    if (!drag || drag.id !== e.pointerId) return false;
    drag = null;
    show();
    return true;
  }
  function action(id) {
    if (!id.startsWith("tool:") && id !== "curve:confirm-mode") return false;
    const edits = [
      "tool:reset-zone",
      "tool:add-point",
      "tool:delete-point",
      "tool:reset-curve",
      "curve:confirm-mode",
    ];
    if (edits.includes(id)) ctx.beginEdit();
    if (id.startsWith("tool:zone:")) zone = id.split(":")[2];
    else if (id === "tool:reset-zone") {
      ctx.values[zone + "Hue"] = 0;
      ctx.values[zone + "Sat"] = 0;
    } else if (id.startsWith("tool:mode:")) {
      if (id.split(":")[2] !== mode) openFlow("curve-mode-confirm");
      return true;
    } else if (id === "curve:confirm-mode") {
      if (RawLabDesignFlows.active !== "curve-mode-conflict") {
        previousScalar = mode === "legacy" ? ctx.values.curve : previousScalar;
        mode = mode === "legacy" ? "custom" : "legacy";
        if (mode === "custom") {
          points = [
            [0, 0],
            [0.5, 0.5],
            [1, 1],
          ];
          ctx.values.curve = 0;
        } else ctx.values.curve = previousScalar;
      }
      RawLabDesignFlows.close();
    } else if (id === "tool:add-point") {
      if (points.length >= 33) return true;
      let index = 0;
      for (let i = 1; i < points.length - 1; i++)
        if (
          points[i + 1][0] - points[i][0] >
          points[index + 1][0] - points[index][0]
        )
          index = i;
      points.splice(index + 1, 0, [
        Math.round((points[index][0] + points[index + 1][0]) * 50) / 100,
        Math.round((points[index][1] + points[index + 1][1]) * 50) / 100,
      ]);
      selected = index + 1;
    } else if (id === "tool:delete-point") {
      if (selected > 0 && selected < points.length - 1) {
        points.splice(selected, 1);
        selected = Math.min(selected, points.length - 1);
      }
    } else if (id === "tool:reset-curve") {
      points = [
        [0, 0],
        [1, 1],
      ];
      selected = 0;
    } else if (id === "tool:target") {
      cancelGesture();
      target = !target;
      sampleStatus = "ready";
    } else if (id.startsWith("tool:target-axis:")) {
      cancelGesture();
      axis = Number(id.split(":")[2]);
    } else if (id === "tool:refresh-target") sampleStatus = "ready";
    else if (id === "tool:auto") {
      status = "recovered";
    } else if (id === "tool:correct-input") {
      status = "normal";
      show();
      const row = document.querySelector("[data-axis-row]");
      const input = row?.querySelector("[data-number], [data-inline-field]");
      if (input?.matches("[data-number]")) input.click();
      else {
        input?.focus();
        input?.select();
      }
      return true;
    } else if (id === "tool:retry") status = "recovered";
    if (edits.includes(id)) ctx.endEdit();
    show();
    return true;
  }
  function onScene(id) {
    cancelGesture();
    target = false;
    status = "normal";
    const state = D.iterationWorkspace[id];
    statusTool = state?.tool || null;
    if (!state) return;
    status = state.status;
    if (state.customCurve) {
      mode = "custom";
      points = [
        [0, 0],
        [0.28, 0.18],
        [0.68, 0.8],
        [1, 1],
      ];
      selected = 1;
    }
    if (state.tool === "color-grading")
      Object.assign(ctx.values, {
        shadowHue: 220,
        shadowSat: 12,
        midHue: 35,
        midSat: 8,
        highHue: 45,
        highSat: 10,
      });
    if (state.target) {
      target = true;
      sampleStatus =
        {
          "hsl-target-drag": "dragging",
          "hsl-target-invalid": "invalid",
          "hsl-target-stale": "stale",
          "hsl-target-cancelled": "cancelled",
        }[id] || "ready";
    }
  }
  function resetTool(tool) {
    if (tool === "curve") {
      if (mode === "custom") {
        points = [
          [0, 0],
          [1, 1],
        ];
        selected = 0;
      } else ctx.values.curve = 0;
      return true;
    }
    if (!fields[tool]) return false;
    fields[tool].forEach((field) => (ctx.values[field] = 0));
    return true;
  }
  return {
    attach(context) {
      ctx = context;
    },
    renderPanel,
    targetToolbar,
    overlay,
    action,
    onScene,
    pointerDown,
    pointerMove,
    pointerUp,
    cancelGesture,
    resetTool,
    handlesTool: (tool) => tool === "curve" || !!fields[tool],
    activeTarget: () => target,
    onNavigate() {
      const changed = cancelGesture();
      target = false;
      return changed;
    },
    onParameter(field, value) {
      if (mode === "custom" && ["curveX", "curveY"].includes(field))
        points[selected][field === "curveX" ? 0 : 1] = value / 100;
    },
    isChanged(tool) {
      return tool === "curve"
        ? (mode === "custom" && points.some(([x, y]) => x !== y)) ||
            ctx.values.curve !== 0
        : (fields[tool] || []).some((field) => ctx.values[field] !== 0);
    },
    mode: () => mode,
    status: () => status,
    snapshot: () => ({ mode, points: structuredClone(points) }),
    restore(curve) {
      if (curve) {
        mode = curve.mode;
        points = structuredClone(curve.points);
        selected = Math.min(selected, points.length - 1);
      }
    },
    pointKey(e) {
      if (e.key === "Escape" && (drag || target)) {
        cancelGesture();
        target = false;
        show();
        e.preventDefault();
        return true;
      }
      if (e.target.matches("[data-grade-wheel]") && e.key.startsWith("Arrow")) {
        ctx.beginEdit();
        const hue = zone + "Hue",
          sat = zone + "Sat";
        if (e.key === "ArrowLeft")
          ctx.values[hue] = (ctx.values[hue] + 359) % 360;
        if (e.key === "ArrowRight")
          ctx.values[hue] = (ctx.values[hue] + 1) % 360;
        if (e.key === "ArrowUp")
          ctx.values[sat] = Math.min(100, ctx.values[sat] + 1);
        if (e.key === "ArrowDown")
          ctx.values[sat] = Math.max(0, ctx.values[sat] - 1);
        ctx.endEdit();
        e.preventDefault();
        show();
        return true;
      }
      if (
        target &&
        e.target.hasAttribute("data-target-sample") &&
        e.key.startsWith("Arrow")
      ) {
        ctx.beginEdit();
        const next = structuredClone(ctx.getHsl()),
          delta = ["ArrowUp", "ArrowRight"].includes(e.key) ? 1 : -1;
        [3, 4].forEach(
          (band, i) =>
            (next[band][axis] =
              Math.round(
                Math.max(
                  -100,
                  Math.min(100, next[band][axis] + delta * [0.8, 0.2][i]),
                ) * 10,
              ) / 10),
        );
        ctx.setHsl(next);
        ctx.endEdit();
        sampleStatus = "dragging";
        e.preventDefault();
        show();
        return true;
      }
      const index = e.target.dataset?.curvePoint;
      if (index != null && ["Delete", "Backspace"].includes(e.key)) {
        selected = Number(index);
        action("tool:delete-point");
        e.preventDefault();
        return true;
      }
      if (index == null || !e.key.startsWith("Arrow")) return false;
      selected = Number(index);
      ctx.beginEdit();
      if (selected > 0 && selected < points.length - 1) {
        const p = points[selected];
        if (e.key === "ArrowLeft")
          p[0] = Math.max(points[selected - 1][0] + 0.01, p[0] - 0.01);
        if (e.key === "ArrowRight")
          p[0] = Math.min(points[selected + 1][0] - 0.01, p[0] + 0.01);
        if (e.key === "ArrowUp")
          p[1] = Math.min(points[selected + 1][1], p[1] + 0.01);
        if (e.key === "ArrowDown")
          p[1] = Math.max(points[selected - 1][1], p[1] - 0.01);
      }
      ctx.endEdit();
      e.preventDefault();
      show();
      return true;
    },
  };
})();
