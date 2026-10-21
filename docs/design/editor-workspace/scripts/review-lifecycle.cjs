// 操作生命周期与恢复回归；仅操作四端浏览器设计稿。
const assert = require("node:assert/strict");
async function reviewLifecycle(browser, base) {
  const checks = [],
    failures = [];
  for (const platform of ["ios", "android", "macos", "windows"]) {
    const page = await browser.newPage({
      viewport: ["ios", "android"].includes(platform)
        ? { width: 390, height: 844 }
        : { width: 1440, height: 1000 },
    });
    page.setDefaultTimeout(4000);
    const errors = [];
    let currentCase = "setup";
    page.on("pageerror", (e) =>
      errors.push({
        platform,
        case: currentCase,
        url: page.url(),
        stack: e.stack,
      }),
    );
    const goto = async (scene) => {
      await page.goto(
        `${base}preview.html?platform=${platform}&scene=${scene}`,
      );
      // 初始化完成后再读全局模型；load 返回不替代可操作画面的就绪条件。
      await page.locator(".native-app").waitFor({ state: "attached" });
    };
    const iter = (id) => page.locator(`[data-iter="${id}"]`).click();
    const action = (id) => page.locator(`[data-action="${id}"]`).last().click();
    const inspect = () => page.evaluate(() => RawLabIteration.inspect());
    const snapshot = () => page.evaluate(() => prototypeContext().snapshot());
    const flow = async (id) =>
      assert.equal(await page.locator(`[data-flow-view="${id}"]`).count(), 1);
    const more = async (id) => {
      if (platform === "windows") {
        await page
          .locator('[data-action="win-menu"][data-menu="编辑"]')
          .click();
        await page
          .locator(
            `[data-menu-action="${{ "user-presets": "iteration-presets", "batch-sync": "iteration-batch", "copy-scope": "iteration-copy", "paste-result": "iteration-paste" }[id]}"]`,
          )
          .click();
      } else {
        await action("more");
        await page.locator(`[data-flow="${id}"]`).click();
      }
    };
    const close = () => page.locator('[data-flow-action="close"]').click();
    const check = async (id, run) => {
      currentCase = id;
      try {
        await run();
        checks.push({ platform, id });
      } catch (e) {
        failures.push(`${platform}/${id}: ${e.message}`);
      }
    };
    const edit = (s, id) => s.edits.find(([key]) => key === id)[1];
    const dirty = async () => {
      await page.locator('[data-group="geometry"]').click();
      await page.locator('[data-axis="straighten"]').fill("2");
    };
    const settings = async () => {
      if (platform === "macos") {
        await action("more");
        await page.locator('[data-flow="settings"]').click();
      } else await action("settings");
      await page.locator('[data-flow="update-settings"]').click();
      await page.locator('[data-flow-action="check-now"]').click();
    };
    try {
      for (const finish of ["cancel", "submit"])
        await check(`sync-${finish}-preserves-copied-payload`, async () => {
          await goto("light");
          await more("copy-scope");
          await iter("capture");
          const copied = (await inspect()).clipboard;
          await iter("close");
          await action("auto-exposure");
          const changed = await snapshot();
          assert.notEqual(
            changed.values.exposure,
            copied.snapshot.values.exposure,
          );
          await more("batch-sync");
          await iter("batch:scope");
          if (finish === "submit") {
            await iter("sync-preflight");
            await iter("target-draft:discard");
            assert.equal(
              edit(await inspect(), "photo-1").values.exposure,
              changed.values.exposure,
            );
          }
          await page.locator('[data-flow-action="back"]').click();
          await close();
          assert.deepEqual((await inspect()).clipboard, copied);
          await more("paste-result");
          await iter("paste:apply");
          if (finish === "cancel") await iter("target-draft:discard");
          await flow("paste-done");
          assert.equal(
            edit(await inspect(), "photo-1").values.exposure,
            copied.snapshot.values.exposure,
          );
        });
      await check("sync-without-copy-keeps-clipboard-empty", async () => {
        await goto("groups");
        await more("batch-sync");
        await iter("batch:scope");
        await iter("sync-preflight");
        await iter("target-draft:discard");
        await flow("batch-sync-success");
        assert.equal((await inspect()).clipboard, null);
        assert.equal(
          await page.evaluate(() => RawLabIteration.canPaste()),
          false,
        );
      });
      await check(
        "preset-in-single-edit-retains-collection-transaction",
        async () => {
          await goto("groups");
          const before = await inspect();
          await more("batch-sync");
          await iter("batch:scope");
          await iter("sync-preflight");
          await iter("target-draft:discard");
          const synced = await inspect();
          await iter("edit:photo-1");
          await more("user-presets");
          await iter("preset:apply:p2");
          await iter("paste:apply");
          // 预设结果页仍定位本次单张操作；集合入口应定位原同步事务。
          await iter("open:history-batch");
          assert(
            (await page.locator(".history-row").innerText()).includes(
              "1 张成功目标",
            ),
          );
          await iter("history:undo");
          assert.equal(edit(await inspect(), "photo-1").values.vibrance, 0);
          await iter("history:redo");
          await close();
          await iter("batch:save-return");
          const tweaked = await inspect();
          await iter("open:history-batch");
          assert(
            (await page.locator(".history-row").innerText()).includes(
              "3 张成功目标",
            ),
          );
          await iter("history:undo");
          await flow("history-conflict");
          await iter("history:skip");
          await flow("history-recovered");
          const undone = await inspect();
          assert.deepEqual(edit(undone, "photo-1"), edit(tweaked, "photo-1"));
          for (const id of ["photo-2", "photo-3"])
            assert.deepEqual(edit(undone, id), edit(before, id));
          await iter("history:redo");
          const redone = await inspect();
          assert.deepEqual(edit(redone, "photo-1"), edit(tweaked, "photo-1"));
          for (const id of ["photo-2", "photo-3"])
            assert.deepEqual(edit(redone, id), edit(synced, id));
        },
      );
      await check("unchanged-preset-keeps-redo-enabled", async () => {
        await goto("tool-film");
        await more("user-presets");
        await iter("open:preset-save");
        await page.locator("[data-preset-name]").fill("未变化调整");
        await iter("preset:save");
        const preset = (await inspect()).presets.find(
          (p) => p.name === "未变化调整",
        );
        await iter("close");
        await page.locator('[data-film="VELVIA"]').click();
        const changed = await snapshot();
        await action("undo");
        const before = await inspect();
        await more("user-presets");
        await iter(`preset:apply:${preset.id}`);
        await iter("paste:apply");
        assert.equal(
          await page.locator('[data-iter="open:history-batch"]').count(),
          0,
        );
        assert(
          (await page.locator(".flow-body").innerText()).includes(
            "目标调整未变化",
          ),
        );
        await iter("close");
        assert.deepEqual((await inspect()).history, before.history);
        assert.equal(
          await page.locator('[data-action="redo"]').last().isEnabled(),
          true,
        );
        await action("redo");
        assert.deepEqual(await snapshot(), changed);
      });
      await check("unchanged-sync-retains-last-transaction", async () => {
        await goto("groups");
        const before = await inspect();
        await more("batch-sync");
        await iter("batch:scope");
        await iter("sync-preflight");
        await iter("target-draft:discard");
        const synced = await inspect();
        await page.locator('[data-flow-action="back"]').click();
        await iter("batch:scope");
        await iter("sync-preflight");
        assert.deepEqual((await inspect()).history, synced.history);
        assert.equal(
          await page.locator('[data-iter="open:history-batch"]').count(),
          0,
        );
        assert(
          (await page.locator(".flow-body").innerText()).includes(
            "目标调整未变化",
          ),
        );
        await page.locator('[data-flow-action="back"]').click();
        await iter("open:history-batch");
        await iter("history:undo");
        for (const id of ["photo-1", "photo-2", "photo-3"])
          assert.deepEqual(edit(await inspect(), id), edit(before, id));
      });
      for (const exit of ["header", "escape"])
        await check(`preset-exit-${exit}-starts-fresh-paste`, async () => {
          await goto("copy-scope");
          await iter("capture");
          await iter("close");
          await more("user-presets");
          await iter("preset:apply:p2");
          await page.locator('[data-flow-action="back"]').click();
          if (exit === "header") await close();
          else await page.keyboard.press("Escape");
          await more("paste-result");
          const s = await inspect();
          assert.deepEqual(s.targets, ["photo-1", "photo-2", "photo-3"]);
          await iter("paste:apply");
          await iter("target-draft:discard");
          assert.equal(edit(await inspect(), "photo-1").values.vibrance, 0);
          assert.equal(edit(await inspect(), "source").values.vibrance, 0);
        });
      await check("skip-is-local-to-one-paste", async () => {
        await goto("paste-result");
        await iter("paste:apply");
        await iter("target-draft:skip");
        await iter("close");
        await more("paste-result");
        assert((await inspect()).targets.includes("photo-2"));
        await iter("paste:apply");
        await flow("paste-draft");
      });
      await check("inspection-does-not-submit-and-can-recover", async () => {
        await goto("paste-result");
        const before = await inspect();
        await iter("open:paste-draft");
        await iter("target-draft:apply");
        await flow("paste-result");
        assert.equal((await inspect()).results.length, 0);
        assert.deepEqual(
          edit(await inspect(), "photo-1"),
          edit(before, "photo-1"),
        );
        await iter("paste:apply");
        await flow("paste-done");
      });
      await check(
        "skip-last-target-blocks-and-reselection-recovers",
        async () => {
          await goto("paste-result");
          await iter("open:paste-targets");
          await page.locator('[data-iter-photo="photo-1"]').uncheck();
          await page.locator('[data-iter-photo="photo-3"]').uncheck();
          await iter("paste:targets-done");
          await iter("paste:apply");
          await iter("target-draft:skip");
          await flow("paste-no-targets");
          assert.equal((await inspect()).results.length, 0);
          await iter("open:paste-targets");
          await page.locator('[data-iter-photo="photo-1"]').check();
          await iter("paste:targets-done");
          await iter("paste:apply");
          await flow("paste-done");
          assert.deepEqual((await inspect()).targets, ["photo-1"]);
        },
      );
      for (const choice of ["apply", "discard", "skip"])
        await check(`export-current-draft-${choice}-reconfirms`, async () => {
          await goto("batch-sync-success");
          await iter("edit:photo-1");
          await dirty();
          await more("batch-sync");
          await iter("open:batch-per-target-export");
          await iter("batch:freeze");
          await flow("batch-export-preflight");
          assert.equal((await inspect()).frozenItems.length, 0);
          await iter(`target-draft:${choice}`);
          await flow("batch-per-target-export");
          assert.equal((await inspect()).frozenItems.length, 0);
          if (choice === "skip")
            assert.equal(await page.evaluate(() => draft), true);
          await iter("batch:freeze");
          const item = (await inspect()).frozenItems.find(
            (x) => x.photo.id === "photo-1",
          );
          if (choice === "skip") assert.equal(item, undefined);
          else
            assert.equal(
              item.snapshot.values.straighten,
              choice === "apply" ? 2 : 0,
            );
        });
      await check("collection-source-is-not-stale-clipboard", async () => {
        await goto("batch-sync-return");
        await iter("edit:photo-1");
        await more("copy-scope");
        await iter("capture");
        await iter("close");
        await iter("batch:save-return");
        assert((await inspect()).targets.includes("photo-1"));
        assert(!(await inspect()).targets.includes("source"));
      });
      await check(
        "inspection-cancel-preserves-draft-history-and-records",
        async () => {
          await goto("paste-result");
          const before = await inspect();
          await iter("open:paste-draft");
          await iter("close");
          const after = await inspect();
          assert.deepEqual(after.edits, before.edits);
          assert.deepEqual(after.targetDrafts, before.targetDrafts);
          assert.deepEqual(after.history, before.history);
          assert.deepEqual(after.results, before.results);
        },
      );
      await check("target-save-failure-retries-before-paste", async () => {
        await goto("target-draft-save-error");
        assert.equal((await inspect()).results.length, 0);
        await iter("target-draft:apply");
        await flow("paste-done");
        assert.equal(
          (await inspect()).results.find(([id]) => id === "photo-2")[1].before
            .values.grain,
          15,
        );
      });
      await check(
        "export-cancel-keeps-current-draft-and-can-retry",
        async () => {
          await goto("batch-sync-success");
          await iter("edit:photo-1");
          await dirty();
          const before = await inspect();
          await more("batch-sync");
          await iter("open:batch-per-target-export");
          await iter("batch:freeze");
          await iter("close");
          assert.equal(
            await page.evaluate(() => prototypeContext().hasDraft()),
            true,
          );
          assert.deepEqual((await inspect()).edits, before.edits);
          assert.equal((await inspect()).frozenItems.length, 0);
          await more("batch-sync");
          await iter("open:batch-per-target-export");
          await iter("batch:freeze");
          await iter("target-draft:apply");
          await iter("batch:freeze");
          assert.equal(
            (await inspect()).frozenItems.find((x) => x.photo.id === "photo-1")
              .snapshot.values.straighten,
            2,
          );
        },
      );
      await check("no-op-and-draft-discard-preserve-history", async () => {
        await goto("tool-film");
        const before = await inspect();
        await page.locator('[data-film="中性"]').click();
        assert.deepEqual((await inspect()).history, before.history);
        await dirty();
        await action("discard-draft");
        assert.deepEqual((await inspect()).history, before.history);
      });
      await check(
        "paste-back-to-copy-ready-clears-pending-decisions",
        async () => {
          await goto("paste-result");
          await iter("paste:apply");
          await iter("target-draft:skip");
          await page.locator('[data-flow-action="back"]').click();
          await page.locator('[data-flow-action="back"]').click();
          await flow("copy-ready");
          assert.deepEqual((await inspect()).skipped, []);
          assert.equal((await inspect()).targetIntent, "inspect");
          await iter("open:preset-save");
          assert.equal((await inspect()).operation.mode, "preset-save");
        },
      );
      await check(
        "export-empty-targets-return-and-reselect-remain-export",
        async () => {
          await goto("batch-sync-success");
          await iter("edit:photo-1");
          await dirty();
          await more("batch-sync");
          await iter("batch:none");
          await page.locator('[data-iter-photo="photo-1"]').check();
          await iter("open:batch-per-target-export");
          await iter("batch:freeze");
          await iter("target-draft:skip");
          await flow("paste-no-targets");
          await page.locator('[data-flow-action="back"]').click();
          await flow("batch-per-target-export");
          assert(await page.locator('[data-iter="batch:freeze"]').isDisabled());
          // 空目标确认页提供同一导出操作中的重新选择入口。
          await iter("open:batch-export-targets");
          await page.locator('[data-iter-photo="photo-3"]').check();
          await iter("paste:targets-done");
          await iter("batch:freeze");
          assert.deepEqual(
            (await inspect()).frozenItems.map((x) => x.photo.id),
            ["photo-3"],
          );
          assert.equal(
            await page.evaluate(() => prototypeContext().hasDraft()),
            true,
          );
        },
      );
      await check("repeated-paste-preview-and-no-op-history", async () => {
        await goto("paste-result");
        await iter("paste:apply");
        await iter("target-draft:discard");
        const before = await inspect();
        await iter("close");
        await more("paste-result");
        assert(
          !(await page.locator(".iteration-targets").innerText()).includes(
            "调整已保存",
          ),
        );
        await iter("paste:apply");
        await flow("paste-done");
        assert.deepEqual((await inspect()).history, before.history);
      });
      const mutations = [
        [
          "film",
          "tool-film",
          () => page.locator('[data-film="VELVIA"]').click(),
        ],
        [
          "recipe",
          "tool-recipe",
          () =>
            page.locator('[data-recipe]:not([data-recipe=""])').first().click(),
        ],
        [
          "denoise-preset",
          "tool-denoise",
          () => page.locator('[data-denoise-preset="clean"]').click(),
        ],
        [
          "denoise-toggle",
          "tool-denoise",
          () => page.locator("#denoise-enabled").check(),
        ],
        ["auto-exposure", "light", () => action("auto-exposure")],
        ["white-balance", "tool-wb", () => action("wb-mode")],
        [
          "geometry-apply",
          "tool-geometry",
          async () => {
            await page.locator('[data-axis="straighten"]').fill("2");
            await action("apply-draft");
          },
        ],
        [
          "geometry-leave",
          "tool-geometry",
          async () => {
            await page.locator('[data-axis="straighten"]').fill("2");
            await page.locator('[data-group="light"]').click();
            await action("apply-leave");
          },
        ],
        [
          "lens-apply",
          "tool-lens",
          async () => {
            await page.locator('[data-lens-option="distortion"]').check();
            await action("apply-draft");
          },
        ],
      ];
      for (const [name, scene, mutate] of mutations)
        await check(`committed-${name}-undo-redo`, async () => {
          await goto(scene);
          const before = await snapshot();
          const h = (await inspect()).history.find(([id]) => id === "source")[1]
            .undo.length;
          await mutate();
          const after = await snapshot();
          assert.notDeepEqual(after, before);
          assert.equal(
            (await inspect()).history.find(([id]) => id === "source")[1].undo
              .length,
            h + 1,
          );
          await action("undo");
          assert.deepEqual(await snapshot(), before);
          await action("redo");
          assert.deepEqual(await snapshot(), after);
        });
      await check("preset-ids-survive-delete-create-and-manage", async () => {
        await goto("user-presets");
        const save = async (name) => {
          await iter("open:preset-save");
          await page.locator("[data-preset-name]").fill(name);
          await iter("preset:save");
        };
        await save("第一个新增预设");
        const first = (await inspect()).presets.find(
          (p) => p.name === "第一个新增预设",
        );
        await iter("preset:manage:p1");
        await iter("open:preset-delete");
        await iter("preset:delete");
        await save("第二个新增预设");
        const second = (await inspect()).presets.find(
          (p) => p.name === "第二个新增预设",
        );
        assert.notEqual(first.id, second.id);
        await iter(`preset:manage:${second.id}`);
        await page.locator("[data-preset-rename]").fill("第二个改名");
        await iter("preset:rename");
        assert.equal(
          (await inspect()).presets.find((p) => p.id === first.id).name,
          first.name,
        );
        await iter(`preset:apply:${second.id}`);
        assert(
          (await page.locator(".flow-body").innerText()).includes("第二个改名"),
        );
        await page.locator('[data-flow-action="back"]').click();
        await iter(`preset:manage:${second.id}`);
        await iter("open:preset-delete");
        await iter("preset:delete");
        assert((await inspect()).presets.some((p) => p.id === first.id));
      });
      if (["macos", "windows"].includes(platform)) {
        for (const phase of ["downloading", "verifying"])
          await check(`update-${phase}-survives-photo-import`, async () => {
            await goto("update");
            await action("download-update");
            await page.waitForFunction(
              (expected) => download === expected,
              phase,
            );
            await action("close-update");
            await action("import");
            await page.locator('[data-flow="system-picker"]').click();
            await page.locator('[data-flow-action="import-selected"]').click();
            await page.waitForFunction(() => download === "ready", null, {
              timeout: 6000,
            });
            await settings();
            assert.equal(
              await page.locator('[data-action="install-update"]').count(),
              1,
            );
          });
        await check("restored-version-completes-failure-recovery", async () => {
          await goto("update-installing");
          await action("simulate-install-failed");
          await iter("open:update-manual-recovery");
          await action("iteration-close");
          await settings();
          await flow("update-install-recovery");
          // 首次启动失败才提供恢复旧版动作，安装中断保持重试入口。
          await goto("update-restart-failed");
          await iter("open:update-restored");
          await iter("close");
          await settings();
          assert.equal(await page.evaluate(() => download), "available");
        });
        for (const choice of ["apply", "discard", "continue"])
          await check(`update-preserves-editor-draft-${choice}`, async () => {
            await goto("tool-geometry");
            await page.locator('[data-axis="straighten"]').fill("2");
            await settings();
            assert.equal(
              await page.evaluate(() => prototypeContext().hasDraft()),
              true,
            );
            await action("download-update");
            await page.waitForFunction(() => download === "ready", null, {
              timeout: 6000,
            });
            await action("install-update");
            await iter("update:resolve-gate");
            await iter(`update:draft-${choice}`);
            assert.equal(
              await page.evaluate(() => values.straighten),
              choice === "discard" ? 0 : 2,
            );
            assert.equal(
              await page.evaluate(() => prototypeContext().hasDraft()),
              choice === "continue",
            );
            if (choice === "apply")
              assert.equal(
                edit(await inspect(), "source").values.straighten,
                2,
              );
            if (choice === "continue") {
              await action("apply-draft");
              assert.equal(
                edit(await inspect(), "source").values.straighten,
                2,
              );
            }
          });
        await check(
          "verification-failure-survives-close-reopen-and-old-timer",
          async () => {
            await goto("update");
            await action("download-update");
            await page.waitForFunction(() => download === "verifying");
            await action("verify-failure");
            await action("iteration-close");
            await settings();
            await page.waitForTimeout(1800);
            await flow("update-signature-error");
            assert.equal(
              await page.locator('[data-action="install-update"]').count(),
              0,
            );
            assert.equal(
              await page.evaluate(() => download),
              "verification-failed",
            );
            await iter("update:retry");
            await page.waitForFunction(() => download === "ready", null, {
              timeout: 6000,
            });
          },
        );
        await check("installation-failure-survives-close-reopen", async () => {
          await goto("update-installing");
          await action("simulate-install-failed");
          await action("iteration-close");
          await settings();
          await flow("update-install-recovery");
          assert.equal(
            await page.evaluate(() => download),
            "installation-failed",
          );
          await iter("update:retry");
          await page.waitForFunction(() => download === "ready", null, {
            timeout: 6000,
          });
        });
      }
      assert.deepEqual(errors, []);
    } finally {
      await page.close();
    }
  }
  if (failures.length) throw new Error(failures.join("\n"));
  return checks;
}
module.exports = { reviewLifecycle };
