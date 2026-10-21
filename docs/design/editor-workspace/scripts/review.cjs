// Optional browser QA/export tool for the design asset, not an application test.
// Resolve Playwright from an existing tool installation; no app dependency is added.
const fs = require("node:fs"),
  path = require("node:path"),
  os = require("node:os"),
  vm = require("node:vm"),
  assert = require("node:assert/strict");
const { chromium } = require(
  process.env.RAWLAB_DESIGN_PLAYWRIGHT || "playwright",
);
const root = path.resolve(__dirname, "..");
const base = (
  process.env.RAWLAB_DESIGN_URL ||
  "http://127.0.0.1:8766/docs/design/editor-workspace/"
).replace(/\/?$/, "/");
const out =
  process.env.RAWLAB_DESIGN_OUTPUT ||
  path.join(os.tmpdir(), "rawlab-design-review");
fs.mkdirSync(out, { recursive: true });
const sandbox = {};
sandbox.window = sandbox;
vm.createContext(sandbox);
for (const file of ["manifest.js", "shared/model.js", "shared/screens.js"])
  vm.runInContext(fs.readFileSync(path.join(root, file), "utf8"), sandbox);
const D = sandbox.RawLabDesign,
  S = sandbox.RawLabDesignScreens;
const failures = [],
  checks = [];
let states = 0,
  current = "";
const shots = new Set([
  "groups",
  "hsl",
  "draft",
  "processing",
  "compare",
  "compare-wipe",
  "compare-hold",
  "reset-menu",
  "update-settings",
  "export-options",
  "batch-confirm",
  "batch-running",
  "batch-partial",
  "settings",
  "looks",
  "update",
  "components",
]);
(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    for (const platform of ["ios", "android", "macos", "windows"]) {
      const [width, height] = D.viewports[platform][0];
      const page = await browser.newPage({ viewport: { width, height } });
      page.on("pageerror", (e) => failures.push(current + ": " + e.message));
      page.on("response", (r) => {
        if (r.status() >= 400) failures.push(r.status() + " " + r.url());
      });
      const goto = async (scene) => {
        current = platform + "/" + scene;
        await page.goto(
          base + "preview.html?platform=" + platform + "&scene=" + scene,
        );
        assert.equal(await page.locator(".native-app").count(), 1, current);
      };
      const ids = [
        ...new Set(
          S.filter((s) => s.platforms.includes(platform)).flatMap((s) =>
            s.states.filter((id) => D.supportsScreen(s, id, platform)),
          ),
        ),
      ];
      for (const id of ids) {
        await goto(id);
        states++;
        assert.equal(
          await page.evaluate(() => document.body.scrollWidth > innerWidth),
          false,
          current + " body overflow",
        );
        if (id.startsWith("tool-"))
          assert.equal(
            await page
              .locator('[data-tool="' + id.slice(5) + '"][aria-pressed=true]')
              .count(),
            1,
            current,
          );
        if (
          D.flowTitles[id] &&
          ![
            "compare",
            "compare-wipe",
            "compare-hold",
            "draft-confirm",
            "update-ready",
            "reset-menu",
          ].includes(id)
        )
          assert.equal(
            await page.locator('[data-flow-view="' + id + '"]').count(),
            1,
            current + " missing screen",
          );
        const bad = await page
          .locator(".flow-body")
          .evaluateAll(
            (es) => es.filter((e) => e.scrollWidth > e.clientWidth + 1).length,
          );
        assert.equal(bad, 0, current + " flow overflow");
        // 流程标题栏有上一级时只给返回，顶层只给关闭，不同时出现。
        assert(
          (await page
            .locator(
              ".flow-header [data-flow-action=back], .flow-header [data-flow-action=close]",
            )
            .count()) <= 1,
          current + " flow header shows both back and close",
        );
        if (shots.has(id))
          await page.screenshot({
            path: path.join(out, platform + "-" + id + ".png"),
          });
      }
      await goto("groups");
      const rectangles = () =>
        page.evaluate(() =>
          Object.fromEntries(
            [".canvas", ".editor", ".toolbar"].map((s) => {
              const r = document.querySelector(s).getBoundingClientRect();
              return [s, [r.x, r.y, r.width, r.height]];
            }),
          ),
        );
      const rect = await rectangles();
      const compareIs = async (cls, label) => {
        assert.equal(
          await page
            .locator(cls ? ".compare-stage." + cls : ".compare-stage")
            .count(),
          cls ? 1 : 0,
          current + " comparison " + label,
        );
        assert.deepEqual(
          await rectangles(),
          rect,
          current + " comparison moved layout",
        );
      };
      const toggle = () =>
        page.locator(".toolbar [data-action=compare]").click();
      // 点按只开关，并回到上次使用的方式；方式在画面内切换或从菜单选择。
      await toggle();
      await compareIs("side-by-side", "opens last mode");
      await toggle();
      await compareIs(null, "tap closes");
      await toggle();
      await page.locator('[data-compare-mode="2"]').click();
      await compareIs("wipe", "in-canvas switch");
      await page.locator("[data-compare-position]").fill("72");
      assert(
        (await page.locator(".compare-stage").getAttribute("style")).includes(
          "72%",
        ),
      );
      const frame = await page
        .locator(".compare-stage .photo-frame")
        .boundingBox();
      const divider = await page.locator(".compare-divider").boundingBox();
      assert(
        divider.y >= frame.y - 1 &&
          divider.y + divider.height <= frame.y + frame.height + 1,
        current + " divider leaves the photo",
      );
      await toggle();
      await compareIs(null, "tap closes wipe");
      await toggle();
      await compareIs("wipe", "remembers last mode");
      if (!["ios", "android"].includes(platform)) {
        await page.locator("[data-action=compare-menu]").click();
        await page.locator('[data-menu-action="compare-set:1"]').click();
        await compareIs("side-by-side", "menu choice");
      }
      await toggle();
      await compareIs(null, "closed");
      // 再点当前分组收起面板；组内工具页签标出已调整的工具。
      await page.locator('[data-group="light"]').click();
      assert.equal(await page.locator(".editor.has-group").count(), 1);
      assert.equal(
        await page.locator('[data-tool="exposure"] .tab-dot').count(),
        1,
        current + " changed tool dot",
      );
      assert.equal(
        await page.locator('[data-tool="contrast"] .tab-dot').count(),
        0,
      );
      await page.locator('[data-group="light"]').click();
      assert.equal(
        await page.locator(".editor.has-group").count(),
        0,
        current + " re-tap collapses panel",
      );
      // 双向参数的填充从中点开始，而不是从最左端。
      await goto("tool-highlights");
      const fill = await page
        .locator('[data-axis="highlights"]')
        .getAttribute("style");
      assert(fill.includes("--hi:50.00%"), current + " bipolar fill " + fill);
      assert.equal(
        await page
          .locator('[data-axis="highlights"]')
          .evaluate((e) =>
            e
              .closest(".axis")
              .querySelector(".number")
              .classList.contains("changed"),
          ),
        true,
      );
      await goto("tool-contrast");
      assert.equal(
        await page.locator(".axis .number.changed").count(),
        0,
        current + " unchanged value styled as changed",
      );
      for (const id of ["tool-exposure", "hsl", "draft"]) {
        await goto(id);
        const r = await rectangles();
        await page.evaluate(() =>
          postMessage({ type: "preview-progress", busy: true }, "*"),
        );
        await page.waitForTimeout(30);
        assert.deepEqual(await rectangles(), r, current + " busy moved layout");
        assert.equal(await page.locator(".preview-progress").isVisible(), true);
        await page.evaluate(() =>
          postMessage({ type: "preview-progress", busy: false }, "*"),
        );
        await page.waitForTimeout(30);
        assert.deepEqual(await rectangles(), r, current + " idle moved layout");
      }
      await goto("draft");
      const footer = await page.locator(".draft-actions").boundingBox();
      await page.locator(".editor > .panel").evaluate((e) => {
        e.scrollTop = e.scrollHeight;
      });
      const lastAxis = await page
        .locator('[data-axis="perspective"]')
        .boundingBox();
      assert(
        lastAxis.y + lastAxis.height <= footer.y,
        current + " final geometry control obscured by footer",
      );
      assert.deepEqual(
        await page.locator(".draft-actions").boundingBox(),
        footer,
        current + " draft footer moved while parameters scrolled",
      );
      // 照片上的裁切框可直接拖动，拖动后草稿变为可应用。
      const handle = await page
        .locator('[data-crop-handle="se"]')
        .boundingBox();
      const before = await page.locator(".crop-frame").boundingBox();
      await page.mouse.move(
        handle.x + handle.width / 2,
        handle.y + handle.height / 2,
      );
      await page.mouse.down();
      await page.mouse.move(handle.x - 30, handle.y - 20, { steps: 4 });
      await page.mouse.up();
      const after = await page.locator(".crop-frame").boundingBox();
      assert(after.width < before.width - 10, current + " crop drag");
      assert.equal(
        await page.locator("[data-action=apply-draft]").isDisabled(),
        false,
      );
      if (["ios", "android"].includes(platform)) {
        await goto("groups");
        const rows = await page
          .locator(".group-nav [data-group]")
          .evaluateAll(
            (es) =>
              new Set(es.map((e) => Math.round(e.getBoundingClientRect().top)))
                .size,
          );
        assert.equal(rows, 1, current + " groups wrapped");
        assert(
          await page
            .locator(".group-nav")
            .evaluate((e) => e.scrollWidth > e.clientWidth),
        );
        if (platform === "android") {
          const density = await page
            .locator(".group")
            .first()
            .evaluate((e) => {
              const glyph = e.querySelector(".glyph");
              const svg = glyph.querySelector("svg");
              return {
                item: e.getBoundingClientRect().width,
                ring: glyph.getBoundingClientRect().width,
                icon: svg.getBoundingClientRect().width,
                gap: getComputedStyle(e.parentElement).gap,
              };
            });
          assert.deepEqual(density, {
            item: 80,
            ring: 48,
            icon: 24,
            gap: "8px",
          });
        }
        await goto("hsl");
        assert.equal(
          await page
            .locator(".swatch[aria-pressed=true] i")
            .evaluate((e) => getComputedStyle(e, "::after").content),
          "none",
        );
        await goto("tool-denoise");
        assert.equal(await page.locator('[aria-label="RAW 降噪"]').count(), 0);
      }
      await goto("batch-select");
      assert.equal(
        await page.locator("[data-flow-action=batch-next]").isDisabled(),
        true,
      );
      await page.locator('[data-flow-select="0"]').check();
      await page.locator("[data-flow-action=batch-next]").click();
      await page.locator("[data-flow-action=back]").click();
      assert.equal(
        await page.locator('[data-flow-select="0"]').isChecked(),
        true,
      );
      await page
        .locator('[data-flow="system-picker"], [data-flow-action=folder-add]')
        .first()
        .click();
      await page.locator("[data-flow-action=back]").click();
      assert.equal(
        await page.locator("[data-flow-view=batch-select]").count(),
        1,
      );
      await goto("look-import");
      await page.locator("[data-flow=system-picker]").click();
      await page.locator("[data-flow-action=back]").click();
      assert.equal(
        await page.locator("[data-flow-view=look-import]").count(),
        1,
      );
      await goto("batch-permission");
      await page.locator("[data-flow-action=reauthorize]").click();
      assert.equal(
        await page.locator("[data-flow-view=destination]").count(),
        1,
      );
      await page.locator("[data-flow-action=destination-selected]").click();
      assert.equal(
        await page.locator("[data-flow-view=batch-running]").count(),
        1,
      );
      if (!["ios", "android"].includes(platform)) {
        await goto("batch-confirm");
        await page.locator("[data-flow=destination]").click();
        await page.locator("[data-flow-action=return-export]").click();
        assert.equal(
          await page.locator("[data-flow-view=batch-confirm]").count(),
          1,
        );
      }
      checks.push(
        platform +
          ": registered screens, comparison toggle/switch/menu, collapsible groups, changed markers, bipolar fill, no layout shift, crop drag, flow exits, batch selection/back, system handoff/back, reauthorization",
      );
      await page.close();
    }
    // Responsive samples include compact windows, phones, tablets and accessibility text.
    for (const [platform, width, height] of [
      ["ios", 320, 700],
      ["ios", 1024, 768],
      ["ios", 844, 390],
      ["android", 320, 700],
      ["android", 960, 640],
      ["android", 892, 412],
      ["macos", 950, 620],
      ["windows", 1024, 720],
    ]) {
      const page = await browser.newPage({ viewport: { width, height } });
      page.on("pageerror", (e) => failures.push(e.message));
      for (const id of ["groups", "hsl", "draft", "batch-confirm", "settings"])
        for (const large of [false, true]) {
          await page.goto(
            base +
              "preview.html?platform=" +
              platform +
              "&scene=" +
              id +
              "&largeText=" +
              large,
          );
          states++;
          assert.equal(
            await page.evaluate(() => document.body.scrollWidth > innerWidth),
            false,
            `${platform} ${width} ${id} ${large}`,
          );
          const side = await page.evaluate(
            (l) =>
              !l &&
              matchMedia("(min-width: 600px) and (orientation: landscape)")
                .matches,
            large,
          );
          if (id === "groups" && ["ios", "android"].includes(platform)) {
            const rowCount = await page
              .locator(".group-nav [data-group]")
              .evaluateAll(
                (es) =>
                  new Set(
                    es.map((e) => Math.round(e.getBoundingClientRect().top)),
                  ).size,
              );
            // 竖屏底部分组栏单行横滑；横屏侧栏六组一次可见，不需要横滑。
            if (side) {
              assert.equal(
                await page
                  .locator(".group-nav")
                  .evaluate((e) => e.scrollWidth <= e.clientWidth + 1),
                true,
                `${platform} ${width} side groups scroll`,
              );
            } else
              assert.equal(rowCount, 1, `${platform} ${width} groups wrapped`);
          }
          if (id === "hsl")
            assert.equal(
              await page
                .locator(".swatch")
                .evaluateAll(
                  (es) =>
                    new Set(
                      es.map((e) => Math.round(e.getBoundingClientRect().top)),
                    ).size,
                ),
              1,
              `${platform} ${width} ${large} swatches wrapped`,
            );
          if (id === "hsl" && !large)
            await page.screenshot({
              path: path.join(out, `${platform}-${width}-hsl.png`),
            });
        }
      await page.close();
    }
    const page = await browser.newPage({
      viewport: { width: 1440, height: 1000 },
    });
    page.on("pageerror", (e) => failures.push(e.message));
    for (const p of ["ios", "android", "macos", "windows"]) {
      await page.goto(
        base + p + "/index.html?scene=compare-wipe&largeText=true",
      );
      assert(
        (await page.locator("iframe").getAttribute("src")).includes(
          "scene=compare-wipe",
        ),
      );
      assert(
        (await page.locator("iframe").getAttribute("src")).includes(
          "largeText=true",
        ),
      );
    }
    await page.goto(base + "coverage.html");
    assert((await page.locator("#summary").innerText()).includes("可直达"));
    checks.push(
      "Responsive group layout, single-row swatches, coverage index and platform deep links",
    );
    assert.deepEqual(failures, []);
    const report = {
      designVersion: sandbox.RawLabDesignManifest.designVersion,
      states,
      failures,
      checks,
    };
    fs.writeFileSync(
      path.join(out, "review-results.json"),
      JSON.stringify(report, null, 2),
    );
    console.log(JSON.stringify(report, null, 2));
    console.log("Review exports: " + out);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(current, e, failures);
  process.exitCode = 1;
});
