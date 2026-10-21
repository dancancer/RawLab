// 检查本轮新增原型的关键路径；不连接原生处理、存储或安装。
const assert = require("node:assert/strict");

async function reviewIteration(browser, base) {
  const coverage = [];
  for (const platform of ["ios", "android", "macos", "windows"]) {
    const mobile = ["ios", "android"].includes(platform);
    const page = await browser.newPage({
      viewport: mobile
        ? { width: 390, height: 844 }
        : { width: 1440, height: 1000 },
    });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    const goto = (scene) =>
      page.goto(`${base}preview.html?platform=${platform}&scene=${scene}`);
    const click = (id) => page.locator(`[data-iter="${id}"]`).click();
    const inspect = () => page.evaluate(() => RawLabIteration.inspect());
    const check = async (id, run) => {
      try {
        await run();
      } catch (e) {
        e.message = platform + "/" + id + ": " + e.message;
        throw e;
      }
      coverage.push({ platform, id });
    };
    try {
      await check("copy-freezes-fields-and-source", async () => {
        await goto("copy-scope");
        await page.locator('[data-scope-field="exposure"]').uncheck();
        await click("capture");
        const frozen = (await inspect()).clipboard;
        assert(!frozen.fields.includes("exposure"));
        await click("close");
        await page.locator('[data-group="light"]').click();
        await page.locator('[data-axis="exposure"]').fill("1.2");
        assert.deepEqual((await inspect()).clipboard, frozen);
      });
      await check("paste-can-select-one-and-excludes-source", async () => {
        await goto("paste-targets");
        assert.equal(
          await page.locator('[data-iter="source-info"]').isDisabled(),
          true,
        );
        await page.locator('[data-iter-photo="photo-2"]').uncheck();
        await page.locator('[data-iter-photo="photo-3"]').uncheck();
        await click("paste:targets-done");
        await click("paste:apply");
        assert.deepEqual(
          (await inspect()).results.map(([id]) => id),
          ["photo-1"],
        );
      });
      await check("partial-save-retries-only-failures", async () => {
        await goto("paste-partial");
        const first = await inspect();
        const succeeded = first.results.find(([id]) => id === "photo-1")[1];
        assert.equal(
          first.results.find(([id]) => id === "photo-2")[1].status,
          "failed",
        );
        await click("paste:retry");
        const next = await inspect();
        assert.deepEqual(
          next.results.find(([id]) => id === "photo-1")[1],
          succeeded,
        );
        assert(next.results.every(([, r]) => r.status === "applied"));
        assert.deepEqual(next.clipboard, first.clipboard);
      });
      await check("incompatible-items-require-explicit-choice", async () => {
        await goto("paste-incompatible");
        assert.equal((await inspect()).results.length, 0);
        await click("paste:skip-incompatible");
        const result = (await inspect()).results.find(
          ([id]) => id === "photo-4",
        )[1];
        assert(result.skipped.includes("白平衡"));
        assert.equal(result.before.whiteBalance, result.after.whiteBalance);
      });
      await check(
        "preset-validation-overwrite-and-stable-identity",
        async () => {
          await goto("preset-save");
          await page.locator("[data-preset-name]").fill("   ");
          await click("preset:save");
          assert(
            (await page.locator("#preset-name-error").innerText()).includes(
              "名称",
            ),
          );
          await page.locator("[data-preset-name]").fill("森林柔光");
          await click("preset:save");
          assert.equal(
            await page.locator('[data-flow-view="preset-duplicate"]').count(),
            1,
          );
          await click("open:preset-overwrite");
          await click("preset:overwrite");
          const before = (await inspect()).presets;
          assert.equal(before.length, 3);
          await click("preset:manage:p1");
          await page.locator("[data-preset-rename]").fill("日落暖调");
          await click("preset:rename");
          assert.equal(
            await page.locator("[data-preset-rename]").inputValue(),
            "日落暖调",
          );
          await page.locator("[data-preset-rename]").fill("森林新名称");
          await click("preset:rename");
          const after = (await inspect()).presets;
          assert.equal(after.find((p) => p.id === "p1").name, "森林新名称");
          assert.deepEqual(
            after.find((p) => p.id === "p1").payload,
            before.find((p) => p.id === "p1").payload,
          );
        },
      );
      await check("preset-application-keeps-clipboard", async () => {
        await goto("copy-scope");
        await click("capture");
        const clipboard = (await inspect()).clipboard;
        await click("open:preset-save");
        await page.locator('[data-flow-action="back"]').click();
        await click("preset:apply:p2");
        await click("paste:apply");
        const state = await inspect();
        assert.deepEqual(state.clipboard, clipboard);
        assert.deepEqual(state.targets, ["source"]);
        assert.equal(await page.evaluate(() => values.vibrance), 12);
      });
      await check("grading-wheel-and-zone-reset", async () => {
        await goto("tool-color-grading");
        const before = await page.evaluate(() => ({ ...values }));
        await page.locator("[data-grade-wheel]").focus();
        await page.keyboard.press("ArrowUp");
        assert.equal(
          await page.evaluate(() => values.midSat),
          before.midSat + 1,
        );
        await click("tool:zone:shadow");
        await click("tool:reset-zone");
        assert.equal(await page.evaluate(() => values.shadowSat), 0);
        assert.equal(
          await page.evaluate(() => values.midSat),
          before.midSat + 1,
        );
      });
      await check(
        "curve-fixed-endpoints-ordered-points-and-mode-confirm",
        async () => {
          await goto("tool-custom-curve");
          await click("tool:add-point");
          const count = await page.locator("[data-curve-point]").count();
          assert.equal(count, 5);
          await page.locator('[data-curve-point="1"]').focus();
          for (let i = 0; i < 40; i++) await page.keyboard.press("ArrowRight");
          const curve = await page.evaluate(() =>
            RawLabIteration.tools.snapshot(),
          );
          assert.deepEqual(curve.points[0], [0, 0]);
          assert.deepEqual(curve.points.at(-1), [1, 1]);
          assert(
            curve.points.every((p, i) => !i || p[0] > curve.points[i - 1][0]),
          );
          await click("tool:mode:legacy");
          assert.equal(
            await page.locator('[data-flow-view="curve-mode-confirm"]').count(),
            1,
          );
          await click("curve:confirm-mode");
          assert.equal(
            await page.evaluate(() => RawLabIteration.tools.mode()),
            "legacy",
          );
        },
      );
      await check(
        "tool-errors-recover-without-changing-layout-or-group",
        async () => {
          for (const tool of [
            "black-white",
            "vibrance",
            "color-grading",
            "custom-curve",
            "clarity",
            "dehaze",
          ]) {
            await goto(tool + "-save-error");
            const before = await page.locator(".canvas").boundingBox();
            assert(
              (await page.locator(".tool-status").innerText()).includes(
                "未保存",
              ),
            );
            await click("tool:retry");
            assert.deepEqual(
              await page.locator(".canvas").boundingBox(),
              before,
            );
            assert.equal(
              await page
                .locator(
                  `[data-tool="${tool === "custom-curve" ? "curve" : tool}"][aria-pressed="true"]`,
                )
                .count(),
              1,
            );
          }
        },
      );
      await check("hsl-target-cancel-restores-gesture-start", async () => {
        await goto("hsl-target");
        const initial = await page.evaluate(() => structuredClone(hsl));
        const r = await page.locator("[data-photo-frame]").boundingBox();
        await page.mouse.move(r.x + r.width * 0.5, r.y + r.height * 0.65);
        await page.mouse.down();
        await page.mouse.move(r.x + r.width * 0.5, r.y + r.height * 0.45);
        assert.notDeepEqual(
          await page.evaluate(() => structuredClone(hsl)),
          initial,
        );
        await page.keyboard.press("Escape");
        await page.mouse.up();
        assert.deepEqual(
          await page.evaluate(() => structuredClone(hsl)),
          initial,
        );
        assert.equal(
          await page.evaluate(() => RawLabIteration.activeTarget()),
          false,
        );
      });
      await check("hsl-target-has-keyboard-adjustment", async () => {
        await goto("hsl-target");
        const initial = await page.evaluate(() => structuredClone(hsl));
        await page.locator("[data-target-sample]").focus();
        await page.keyboard.press("ArrowUp");
        const next = await page.evaluate(() => structuredClone(hsl));
        assert.equal(next[3][0], Math.round((initial[3][0] + 0.8) * 10) / 10);
        assert.equal(next[4][0], Math.round((initial[4][0] + 0.2) * 10) / 10);
      });
      await check("batch-edit-return-freezes-independent-targets", async () => {
        await goto("batch-sync-return");
        const before = await inspect();
        await click("edit:photo-1");
        await page.locator('[data-axis="exposure"]').fill("1.4");
        await click("batch:save-return");
        const edited = await inspect();
        assert.deepEqual(edited.selected, before.selected);
        assert.equal(
          edited.edits.find(([id]) => id === "photo-1")[1].values.exposure,
          1.4,
        );
        assert.deepEqual(
          edited.edits.find(([id]) => id === "photo-2"),
          before.edits.find(([id]) => id === "photo-2"),
        );
        await click("open:batch-per-target-export");
        await click("batch:freeze");
        await click("target-draft:discard");
        await click("batch:freeze");
        const frozen = (await inspect()).frozenItems;
        assert.equal(
          frozen.find((p) => p.photo.id === "photo-1").snapshot.values.exposure,
          1.4,
        );
        await click("batch:cancel-task");
        const cancelled = (await inspect()).frozenItems;
        assert.deepEqual(
          cancelled.map((p) => p.snapshot),
          frozen.map((p) => p.snapshot),
        );
        await click("batch:resume-task");
        assert.deepEqual(
          (await inspect()).frozenItems.map((p) => p.snapshot),
          frozen.map((p) => p.snapshot),
        );
      });
      await check(
        "batch-recovery-preserves-success-and-frozen-snapshot",
        async () => {
          await goto("batch-per-target-partial");
          const before = (await inspect()).frozenItems;
          await click("batch:resume-task");
          const after = (await inspect()).frozenItems;
          assert.equal(after[0].status, "succeeded");
          assert.deepEqual(
            before.map((p) => p.snapshot),
            after.map((p) => p.snapshot),
          );
        },
      );
      await check(
        "target-draft-is-independent-of-paste-transaction",
        async () => {
          await goto("batch-sync-preflight");
          await click("target-draft:apply");
          let result = (await inspect()).results.find(
            ([id]) => id === "photo-2",
          )[1];
          assert.equal(result.before.values.grain, 15);
          assert(
            (await page.locator(".flow-body").innerText()).includes(
              "草稿已独立保存",
            ),
          );
          await goto("batch-sync-preflight");
          const before = (await inspect()).edits.find(
            ([id]) => id === "photo-2",
          )[1];
          await click("target-draft:discard");
          result = (await inspect()).results.find(
            ([id]) => id === "photo-2",
          )[1];
          assert.deepEqual(result.before, before);
        },
      );
      await check(
        "batch-undo-keeps-transaction-and-conflict-boundaries",
        async () => {
          await goto("paste-done");
          await click("close");
          await page.evaluate(() => {
            RawLabDesignFlows.open("paste-targets");
            render();
          });
          await page.locator('[data-iter-photo="photo-2"]').uncheck();
          await page.locator('[data-iter-photo="photo-3"]').uncheck();
          const preserved = (await inspect()).edits.find(
            ([id]) => id === "photo-2",
          )[1];
          await click("paste:targets-done");
          await click("paste:apply");
          await click("open:history-batch");
          await click("history:undo");
          assert.deepEqual(
            (await inspect()).edits.find(([id]) => id === "photo-2")[1],
            preserved,
          );
          await goto("history-conflict");
          const conflict = (await inspect()).edits.find(
            ([id]) => id === "photo-2",
          )[1];
          await click("history:skip");
          assert.deepEqual(
            (await inspect()).edits.find(([id]) => id === "photo-2")[1],
            conflict,
          );
        },
      );
      await check("discard-has-explicit-result-and-keeps-success", async () => {
        await goto("batch-per-target-partial");
        const first = (await inspect()).frozenItems[0];
        await click("open:batch-per-target-discard");
        await click("batch:discard-task");
        const state = await inspect();
        assert.deepEqual(state.frozenItems[0], first);
        assert.equal(state.frozenItems.length, 3);
        assert(
          state.frozenItems
            .slice(1)
            .every((item) => item.status === "discarded"),
        );
        assert.equal(
          await page
            .locator('[data-flow-view="batch-per-target-discarded"]')
            .count(),
          1,
        );
      });
      await check("new-tool-status-and-touch-targets-stay-scoped", async () => {
        await goto("clarity-save-error");
        const retry = page.locator('[data-iter="tool:retry"]');
        if (mobile)
          assert(
            (await retry.boundingBox()).height >=
              (platform === "ios" ? 44 : 48),
          );
        await click("tool:retry");
        await page.locator('[data-group="color"]').click();
        await page.locator('[data-tool="color-grading"]').click();
        assert.equal(await page.locator(".tool-status").count(), 0);
        if (mobile)
          assert(
            (await page.locator('[data-iter="tool:reset-zone"]').boundingBox())
              .height >= (platform === "ios" ? 44 : 48),
          );
      });
      await check(
        "output-permission-recovery-uses-system-boundary",
        async () => {
          await goto("batch-per-target-permission");
          await click("batch:resume-task");
          assert.equal(
            await page.locator('[data-flow-view="destination"]').count(),
            1,
          );
          await page
            .locator('[data-flow-action="destination-selected"]')
            .click();
          assert.equal(
            await page
              .locator('[data-flow-view="batch-per-target-running"]')
              .count(),
            1,
          );
        },
      );
      if (platform === "ios")
        await check("ios-dng-only-completes-after-file-save", async () => {
          await goto("batch-per-target-save-files");
          assert(
            (await inspect()).frozenItems.every(
              (item) => item.status === "ready-to-save",
            ),
          );
          await page.locator('[data-flow="destination"]').click();
          await page
            .locator('[data-flow-action="destination-selected"]')
            .click();
          assert.equal(
            await page
              .locator('[data-flow-view="batch-per-target-done"]')
              .count(),
            1,
          );
          assert(
            (await inspect()).frozenItems.every(
              (item) => item.status === "succeeded",
            ),
          );
        });
      if (mobile)
        await check("uncertain-output-requires-verification", async () => {
          await goto("batch-per-target-uncertain");
          assert.equal(
            await page.locator('[data-iter="batch:resume-task"]').isDisabled(),
            true,
          );
          await page.locator("[data-iter-verified]").check();
          assert.equal(
            await page.locator('[data-iter="batch:resume-task"]').isDisabled(),
            false,
          );
        });
      else
        await check("legacy-install-and-new-data-recovery-guards", async () => {
          await goto("update-install-unsupported");
          await click("close");
          await page.evaluate(() => {
            RawLabDesignFlows.open("update-settings");
            render();
          });
          assert.equal(
            await page.locator('[data-flow-field="auto-install"]').count(),
            0,
          );
          await goto("update-new-edits");
          assert.equal(
            await page.locator('[data-iter="open:update-restored"]').count(),
            0,
          );
          await click("open:update-manual-recovery");
          assert(
            (await page.locator(".iteration-steps").innerText()).includes(
              "副本",
            ),
          );
        });
      if (!mobile)
        await check(
          "update-install-gate-resolves-draft-before-save-and-tasks",
          async () => {
            await goto("update-install-gate");
            await click("update:resolve-gate");
            assert.equal(
              await page
                .locator('[data-flow-view="update-draft-review"]')
                .count(),
              1,
            );
            await click("update:draft-discard");
            assert.equal(
              await page
                .locator('[data-flow-view="update-save-blocked"]')
                .count(),
              1,
            );
            await click("update:retry-save");
            assert(
              (await page.locator(".update-window").innerText()).includes(
                "等待当前任务完成",
              ),
            );
            await goto("update-signature-error");
            await click("update:retry");
            assert(
              (await page.locator(".update-window").innerText()).includes(
                "正在下载更新",
              ),
            );
          },
        );
      assert.deepEqual(errors, []);
    } finally {
      await page.close();
    }
  }
  return {
    count: coverage.length,
    coverage,
    limitations: [
      "仅验证浏览器内交互示例；不证明真实像素取样、图像处理、磁盘事务、导出或更新安装。",
    ],
  };
}
module.exports = { reviewIteration };
