// 连续操作回归；只验证浏览器内存中的设计状态，不连接原生应用。
const assert = require("node:assert/strict");
async function reviewFollowup(browser, base) {
  const checks = [];
  for (const platform of ["ios", "android", "macos", "windows"]) {
    const page = await browser.newPage({
      viewport: ["ios", "android"].includes(platform)
        ? { width: 390, height: 844 }
        : { width: 1440, height: 1000 },
    });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    const goto = async (scene) => {
      await page.goto(
        `${base}preview.html?platform=${platform}&scene=${scene}`,
      );
      // 初始化完成后再读全局模型；load 返回不替代可操作画面的就绪条件。
      await page.locator(".native-app").waitFor({ state: "attached" });
    };
    const click = (id) => page.locator(`[data-iter="${id}"]`).click();
    const inspect = () => page.evaluate(() => RawLabIteration.inspect());
    const flow = async (id) =>
      assert.equal(await page.locator(`[data-flow-view="${id}"]`).count(), 1);
    const more = async (id) => {
      if (platform === "windows") {
        await page
          .locator('[data-action="win-menu"][data-menu="编辑"]')
          .click();
        await page
          .locator(
            `[data-menu-action="${{ "user-presets": "iteration-presets", "batch-sync": "iteration-batch", "copy-scope": "iteration-copy" }[id]}"]`,
          )
          .click();
      } else {
        await page.locator('[data-action="more"]').click();
        await page.locator(`[data-flow="${id}"]`).click();
      }
    };
    const check = async (id, run) => {
      try {
        await run();
        checks.push({ platform, id });
      } catch (e) {
        e.message = `${platform}/${id}: ${e.message}`;
        throw e;
      }
    };
    const edit = (state, id) => state.edits.find(([key]) => key === id)[1];
    try {
      await check("preset-uses-current-photo-identity", async () => {
        await goto("batch-sync-return");
        const before = await inspect();
        await click("edit:photo-1");
        await more("user-presets");
        await click("preset:apply:p2");
        await click("paste:apply");
        const after = await inspect();
        assert.deepEqual(after.targets, ["photo-1"]);
        assert.deepEqual(edit(after, "source"), edit(before, "source"));
        assert.equal(edit(after, "photo-1").values.vibrance, 12);
      });
      await check("undo-return-does-not-cross-photo-identities", async () => {
        await goto("batch-sync-return");
        const source = await page.evaluate(() => values.exposure);
        await click("edit:photo-1");
        await page.locator('[data-axis="exposure"]').fill("1.4");
        await click("batch:save-return");
        await page.locator('[data-flow-action="back"]').click();
        await page.locator('[data-flow-action="close"]').click();
        await page.locator('[data-action="undo"]').click();
        assert.equal(await page.evaluate(() => values.exposure), source);
        assert.equal(edit(await inspect(), "photo-1").values.exposure, 1.4);
      });
      await check("copy-in-microedit-excludes-frozen-source", async () => {
        await goto("batch-sync-return");
        await click("edit:photo-1");
        await more("copy-scope");
        await click("capture");
        const state = await inspect();
        assert.equal(state.clipboard.sourceInfo.id, "photo-1");
        assert(!state.targets.includes("photo-1"));
      });
      await check("preset-draft-cancel-and-discard-resume", async () => {
        await goto("draft");
        await more("user-presets");
        await click("preset:apply:p2");
        await flow("copy-source-draft");
        assert.equal((await inspect()).results.length, 0);
        await click("draft:cancel");
        assert.equal(await page.evaluate(() => draft), true);
        await more("user-presets");
        await click("preset:apply:p2");
        await click("draft:discard");
        await flow("paste-result");
        assert.equal(await page.evaluate(() => draft), false);
        await click("paste:apply");
        await flow("paste-done");
      });
      await check("sync-draft-apply-before-capture", async () => {
        await goto("draft");
        await more("batch-sync");
        await click("batch:scope");
        await flow("copy-source-draft");
        assert.equal((await inspect()).clipboard, null);
        await click("draft:apply");
        await flow("batch-sync-scope");
        assert.equal(await page.evaluate(() => draft), false);
        assert.equal(
          (await inspect()).clipboard.snapshot.values.straighten,
          1.2,
        );
      });
      await check("sync-incompatible-requires-explicit-skip", async () => {
        await goto("batch-sync");
        await click("batch:all");
        await click("batch:scope");
        await click("sync-preflight");
        await flow("batch-sync-preflight");
        await click("target-draft:discard");
        await flow("paste-incompatible");
        assert.equal((await inspect()).results.length, 0);
        await click("paste:skip-incompatible");
        await flow("batch-sync-success");
        const jpg = (await inspect()).results.find(
          ([id]) => id === "photo-4",
        )[1];
        assert(jpg.skipped.includes("白平衡"));
        assert.equal(jpg.before.whiteBalance, jpg.after.whiteBalance);
      });
      await check(
        "return-retains-batch-history-and-conflict-recovery",
        async () => {
          await goto("batch-sync-success");
          await click("edit:photo-1");
          await page.locator('[data-axis="exposure"]').fill("1.4");
          await click("batch:save-return");
          await click("open:history-batch");
          await click("history:undo");
          await flow("history-conflict");
          await click("history:skip");
          await flow("history-recovered");
          const state = await inspect();
          assert.equal(edit(state, "photo-1").values.exposure, 1.4);
          assert.equal(
            state.results.find(([id]) => id === "photo-2")[1].historyState,
            "undone",
          );
        },
      );
      await check(
        "skip-keeps-collection-and-export-rechecks-draft",
        async () => {
          await goto("batch-sync");
          const selected = (await inspect()).selected;
          await click("batch:scope");
          await click("sync-preflight");
          await click("target-draft:skip");
          assert.deepEqual((await inspect()).selected, selected);
          assert(!(await inspect()).targets.includes("photo-2"));
          await click("open:batch-per-target-export");
          await click("batch:freeze");
          await flow("batch-export-preflight");
          assert.equal((await inspect()).frozenItems.length, 0);
          await click("target-draft:apply");
          await flow("batch-per-target-export");
          assert.deepEqual((await inspect()).selected, selected);
          await click("batch:freeze");
          assert.equal(
            (await inspect()).frozenItems.find((p) => p.photo.id === "photo-2")
              .snapshot.values.grain,
            15,
          );
        },
      );
      await check("batch-redo-keeps-unmodified-subset", async () => {
        await goto("batch-sync-success");
        await click("edit:photo-1");
        await click("batch:save-return");
        await click("open:history-batch");
        await click("history:undo");
        await click("open:batch-sync-return");
        await click("edit:photo-2");
        await page.locator('[data-axis="exposure"]').fill("1.8");
        await click("batch:save-return");
        await click("open:history-batch");
        await click("history:redo");
        const state = await inspect();
        assert.equal(edit(state, "photo-2").values.exposure, 1.8);
        assert.equal(
          state.results.find(([id]) => id === "photo-2")[1].historyState,
          "redo-invalidated",
        );
        for (const id of ["photo-1", "photo-3"])
          assert.equal(
            state.results.find(([key]) => key === id)[1].historyState,
            "applied",
          );
      });
      await check("hsl-color-reset-is-undoable", async () => {
        await goto("hsl");
        const before = await page.evaluate(() => structuredClone(hsl));
        await page.locator('[data-action="reset-menu"]').click();
        await page.locator('[data-menu-action="reset-color"]').click();
        await page.locator('[data-action="undo"]').click();
        assert.deepEqual(await page.evaluate(() => hsl), before);
      });
      await check("doubleclick-reset-is-undoable", async () => {
        await goto("light");
        await page.locator('[data-axis="exposure"]').fill("1.2");
        await page.locator('[data-axis-row="exposure"] .axis-name').dblclick();
        assert.equal(await page.evaluate(() => values.exposure), 0);
        await page.locator('[data-action="undo"]').click();
        assert.equal(await page.evaluate(() => values.exposure), 1.2);
      });
      assert.deepEqual(errors, []);
    } finally {
      await page.close();
    }
  }
  return checks;
}
module.exports = { reviewFollowup };
