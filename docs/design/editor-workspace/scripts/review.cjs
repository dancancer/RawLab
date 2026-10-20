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
            "draft-confirm",
            "update-ready",
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
      for (const cls of ["side-by-side", "wipe", null]) {
        await page.locator(".toolbar [data-action=compare]").click();
        assert.equal(
          await page
            .locator(cls ? ".compare-stage." + cls : ".compare-stage")
            .count(),
          cls ? 1 : 0,
          current + " comparison cycle",
        );
        assert.deepEqual(
          await rectangles(),
          rect,
          current + " comparison moved layout",
        );
        if (cls === "wipe") {
          await page.locator("[data-compare-position]").fill("72");
          assert(
            (
              await page.locator(".compare-stage").getAttribute("style")
            ).includes("72%"),
          );
        }
      }
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
      if (["ios", "android"].includes(platform)) {
        await goto("groups");
        const rows = await page
          .locator("[data-group]")
          .evaluateAll(
            (es) =>
              new Set(es.map((e) => Math.round(e.getBoundingClientRect().top)))
                .size,
          );
        assert.equal(rows, 1, current + " groups wrapped");
        assert(
          await page
            .locator(".group-list")
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
          ": registered screens, comparison 3-cycle, no layout shift, batch selection/back, system handoff/back, reauthorization",
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
          if (id === "groups" && ["ios", "android"].includes(platform))
            assert.equal(
              await page
                .locator("[data-group]")
                .evaluateAll(
                  (es) =>
                    new Set(
                      es.map((e) => Math.round(e.getBoundingClientRect().top)),
                    ).size,
                ),
              1,
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
      "Responsive row layout, coverage index and platform deep links",
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
