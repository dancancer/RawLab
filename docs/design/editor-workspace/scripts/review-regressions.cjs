// 原型行为检查；与可直达界面的截图矩阵分别计数，不证明原生功能。
const assert = require("node:assert/strict");

async function reviewRegressions(browser, base) {
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
    const goto = (scene, suffix = "") =>
      page.goto(
        `${base}preview.html?platform=${platform}&scene=${scene}${suffix}`,
      );
    const check = async (id, run) => {
      try {
        await run();
      } catch (e) {
        e.message = `${platform}/${id}: ${e.message}`;
        throw e;
      }
      coverage.push({ platform, id });
    };
    const reset = async (scope) => {
      await page.locator('[data-action="reset-menu"]').click();
      await page.locator(`[data-menu-action="reset-scope:${scope}"]`).click();
    };
    const pointer = (type, init = {}, target = "document") =>
      page.evaluate(
        ({ type, init, target }) => {
          const el =
            target === "document"
              ? document
              : document.querySelector("[data-photo-frame]");
          el.dispatchEvent(
            new PointerEvent(type, {
              bubbles: true,
              cancelable: true,
              pointerId: 1,
              pointerType: "touch",
              isPrimary: true,
              clientX: 100,
              clientY: 100,
              ...init,
            }),
          );
        },
        { type, init, target },
      );
    try {
      await check("reset-neutral-and-navigation", async () => {
        await goto("groups");
        await page.locator('[data-group="looks"]').click();
        assert.equal(
          await page.locator('.look[data-film="中性"].active').count(),
          1,
        );
        assert.equal(await page.evaluate(() => selectedFilm), "中性");
        await goto("hsl");
        await page.locator('[data-tool="saturation"]').click();
        await reset("group");
        await page.locator('[data-action="confirm-reset"]').click();
        assert.equal(
          await page
            .locator('[data-tool="saturation"][aria-pressed=true]')
            .count(),
          1,
        );
        await reset("all");
        await page.locator('[data-action="confirm-reset"]').click();
        assert.equal(await page.evaluate(() => selectedFilm), "中性");
        assert.equal(
          await page
            .locator('[data-tool="saturation"][aria-pressed=true]')
            .count(),
          1,
        );
        assert.equal(
          await page.evaluate(() => hsl.flat().every((v) => v === 0)),
          true,
        );
      });
      if (mobile || platform === "windows")
        await check("alternate-all-reset-entry", async () => {
          for (const scene of ["hsl", "draft"]) {
            await goto(scene);
            const entry = scene === "draft" ? "geometry" : "hsl";
            if (mobile) {
              await page.locator('[data-action="more"]').click();
              await page.locator('[data-flow-action="reset-all"]').click();
            } else {
              await page
                .locator('[data-action="win-menu"][data-menu="编辑"]')
                .click();
              await page.locator('[data-menu-action="reset-all"]').click();
            }
            if (scene === "draft") {
              assert.equal(
                await page.locator('[data-action="confirm-reset"]').count(),
                0,
              );
              await page.locator('[data-action="discard-leave"]').click();
            }
            await page.locator('[data-action="confirm-reset"]').click();
            assert.equal(
              await page
                .locator(`[data-tool="${entry}"][aria-pressed=true]`)
                .count(),
              1,
            );
            assert.equal(await page.evaluate(() => selectedFilm), "中性");
          }
        });
      await check("dirty-draft-before-all-reset", async () => {
        await goto("draft");
        const before = await page.evaluate(() => ({ ...values }));
        await reset("all");
        assert.equal(
          await page.locator('[data-action="confirm-reset"]').count(),
          0,
        );
        await page.locator('[data-action="cancel-modal"]').click();
        assert.deepEqual(await page.evaluate(() => ({ ...values })), before);
        assert.equal(await page.locator(".draft-actions").count(), 1);
        await page.evaluate(() => setPreviewBusy(true));
        await reset("all");
        assert.equal(
          await page.locator('[data-action="apply-leave"]').isDisabled(),
          true,
        );
        await page.locator('[data-action="cancel-modal"]').click();
        await page.evaluate(() => setPreviewBusy(false));
        await reset("all");
        await page.locator('[data-action="apply-leave"]').click();
        assert.equal(
          await page.locator('[data-action="confirm-reset"]').count(),
          1,
        );
        await page.keyboard.press("Escape");
        assert.deepEqual(await page.evaluate(() => ({ ...values })), before);
        assert.equal(await page.evaluate(() => isDraftChanged()), false);
        await goto("draft");
        await reset("all");
        await page.locator('[data-action="discard-leave"]').click();
        await page.locator('[data-action="confirm-reset"]').click();
        assert.equal(await page.evaluate(() => values.straighten), 0);
        assert.equal(await page.evaluate(() => selectedFilm), "中性");
        assert.equal(
          await page
            .locator('[data-tool="geometry"][aria-pressed=true]')
            .count(),
          1,
        );
      });
      await check("hsl-step-and-legacy-decimal", async () => {
        await goto("hsl");
        assert.equal(
          await page.locator('[data-axis="hsl-0"]').getAttribute("step"),
          mobile ? "1" : "0.1",
        );
        await page.evaluate(() => {
          hsl[3][0] = 0.05;
          render();
        });
        if (mobile) {
          await page.locator('[data-number="hsl-0"]').click();
          assert.equal(
            await page.locator("#number-field").inputValue(),
            "0.05",
          );
          await page.locator('[data-action="apply-number"]').click();
        } else await page.locator('[data-inline-field="hsl-0"]').press("Enter");
        assert.equal(await page.evaluate(() => hsl[3][0]), 0.05);
      });
      if (!mobile)
        await check("numeric-full-parse-and-step", async () => {
          await goto("hsl");
          const old = await page.evaluate(() => hsl[3][0]);
          for (const text of [
            "",
            " ",
            "+",
            "1.",
            "12junk",
            "NaN",
            "Infinity",
            "0x10",
            "0.05",
            "101",
          ]) {
            const input = page.locator('[data-inline-field="hsl-0"]');
            await input.fill(text);
            await input.press("Enter");
            assert.equal(await page.evaluate(() => hsl[3][0]), old, text);
            assert.equal(
              await input.evaluate((el) => el.validity.customError),
              true,
              text,
            );
          }
          await page.locator('[data-inline-field="hsl-0"]').fill("0.1");
          await page.locator('[data-inline-field="hsl-0"]').press("Enter");
          assert.equal(await page.evaluate(() => hsl[3][0]), 0.1);
        });
      if (platform === "android")
        await check("numeric-dialog-empty-and-step", async () => {
          await goto("hsl");
          await page.locator('[data-number="hsl-0"]').click();
          for (const text of ["", "0.5", "101"]) {
            await page.locator("#number-field").fill(text);
            await page.locator('[data-action="apply-number"]').click();
            assert.equal(await page.locator(".number-dialog").count(), 1);
            assert.equal(await page.evaluate(() => hsl[3][0]), -12);
          }
          await page.locator("#number-field").fill("1");
          await page.locator('[data-action="apply-number"]').click();
          assert.equal(await page.evaluate(() => hsl[3][0]), 1);
        });
      if (mobile)
        await check("hsl-320-touch-targets-and-scroll", async () => {
          await page.setViewportSize({ width: 320, height: 700 });
          for (const large of [false, true]) {
            await goto("hsl", `&largeText=${large}`);
            const boxes = await page.locator(".swatch").evaluateAll((els) =>
              els.map((el) => {
                const r = el.getBoundingClientRect();
                return { width: r.width, height: r.height, top: r.top };
              }),
            );
            const min = platform === "ios" ? 44 : 48;
            assert.equal(new Set(boxes.map((b) => Math.round(b.top))).size, 1);
            assert(boxes.every((b) => b.width >= min && b.height >= min));
            assert.equal(
              await page
                .locator(".swatches")
                .evaluate((el) => el.scrollWidth > el.clientWidth),
              true,
            );
            await page.locator('[data-channel="7"]').click();
            assert.equal(
              await page
                .locator('[data-channel="7"]')
                .getAttribute("aria-checked"),
              "true",
            );
            assert.equal(
              await page
                .locator(".swatches")
                .evaluate((el) => el.scrollLeft > 0),
              true,
            );
            assert.equal(
              await page.evaluate(() => document.body.scrollWidth > innerWidth),
              false,
            );
          }
          await page.setViewportSize({ width: 390, height: 844 });
        });
      for (const reason of [
        "move",
        "multi",
        "pointercancel",
        "lostpointercapture",
        "blur",
        "visibilitychange",
        "pagehide",
        "scene",
      ]) {
        await check("hold-cancel-" + reason, async () => {
          await goto("groups");
          await pointer("pointerdown", {}, "photo");
          if (reason === "move") await pointer("pointermove", { clientX: 120 });
          else if (reason === "multi")
            await pointer(
              "pointerdown",
              { pointerId: 2, isPrimary: false },
              "photo",
            );
          else {
            await page.waitForTimeout(230);
            assert.equal(await page.locator(".before-badge").count(), 1);
            if (["blur", "pagehide"].includes(reason))
              await page.evaluate(
                (name) => window.dispatchEvent(new Event(name)),
                reason,
              );
            else if (reason === "visibilitychange")
              await page.evaluate(() =>
                document.dispatchEvent(new Event("visibilitychange")),
              );
            else if (reason === "scene")
              await page.evaluate(() => setScene("hsl"));
            else if (reason === "lostpointercapture")
              await page.locator("#app").dispatchEvent(reason);
            else await pointer(reason);
          }
          await page.waitForTimeout(230);
          assert.equal(await page.locator(".before-badge").count(), 0);
          await pointer("pointerup");
          await pointer("pointerup", { pointerId: 2 });
          await pointer("pointerdown", {}, "photo");
          await page.waitForTimeout(230);
          assert.equal(
            await page.locator(".before-badge").count(),
            1,
            "fresh hold after cancellation",
          );
          await pointer("pointermove", { clientX: 120 });
          assert.equal(
            await page.locator(".before-badge").count(),
            0,
            "move ends an active hold",
          );
          await pointer("pointerup");
        });
      }
      await check("trusted-pointer-hold-move-and-release", async () => {
        await goto("groups");
        const box = await page.locator("[data-photo-frame]").boundingBox();
        const x = box.x + box.width / 2,
          y = box.y + box.height / 2;
        await page.mouse.move(x, y);
        await page.mouse.down();
        await page.waitForTimeout(230);
        assert.equal(await page.locator(".before-badge").count(), 1);
        await page.mouse.move(x + 20, y);
        assert.equal(await page.locator(".before-badge").count(), 0);
        await page.mouse.up();
        await page.mouse.move(x, y);
        await page.mouse.down();
        await page.waitForTimeout(230);
        assert.equal(await page.locator(".before-badge").count(), 1);
        await page.mouse.up();
        assert.equal(await page.locator(".before-badge").count(), 0);
      });
      if (!mobile)
        await check("keyboard-before-gates-and-update-settings", async () => {
          await goto("groups");
          await page.keyboard.down("Backslash");
          assert.equal(await page.locator(".before-badge").count(), 1);
          await page.keyboard.up("Backslash");
          assert.equal(await page.locator(".before-badge").count(), 0);
          await page.keyboard.press("i");
          assert.equal(
            await page.locator(".info-layer").count(),
            1,
            "normal info shortcut",
          );
          for (const scene of ["draft", "update", "settings", "reset-menu"]) {
            await goto(scene);
            await page.keyboard.down("Backslash");
            assert.equal(await page.locator(".before-badge").count(), 0, scene);
            await page.keyboard.up("Backslash");
            await page.keyboard.press("i");
            assert.equal(await page.locator(".info-layer").count(), 0, scene);
          }
          await goto("hsl");
          await reset("all");
          await page.keyboard.down("Backslash");
          assert.equal(await page.locator(".before-badge").count(), 0, "modal");
          await page.keyboard.up("Backslash");
          await page.keyboard.press("i");
          assert.equal(await page.locator(".info-layer").count(), 0, "modal");
          await goto("update");
          assert.equal(await page.locator(".update-window input").count(), 0);
          assert.equal(
            (await page.locator(".update-window").innerText()).includes(
              "以后自动",
            ),
            false,
          );
          await goto("update-settings");
          assert.equal(
            await page.locator('[data-flow-field="auto-install"]').count(),
            1,
          );
        });
      await check("pending-designs-are-not-drawn-scenes", async () => {
        await page.goto(base + "coverage.html");
        await page.selectOption("#platform", platform);
        const iterations = await page
          .locator("#pending-screens tr")
          .evaluateAll((els) => els.map((e) => e.dataset.pendingIteration));
        assert.deepEqual(
          iterations,
          Array.from(
            { length: mobile ? 8 : 9 },
            (_, i) => "ITER-" + String(i + 3).padStart(2, "0"),
          ),
        );
        assert.equal(
          await page.locator("#pending-screens a[href*='scene=']").count(),
          0,
        );
        assert.equal(
          (await page.locator("#out-of-iteration").innerText()).includes(
            "复制",
          ),
          false,
        );
        assert.equal(
          (await page.locator("#out-of-iteration").innerText()).includes("HDR"),
          true,
        );
      });
      assert.deepEqual(errors, []);
    } finally {
      await page.close();
    }
  }
  return {
    count: coverage.length,
    coverage,
    limitations: [
      "Chromium headless 的视口和合成 pointer/生命周期事件；不替代物理设备、原生手势/后台或读屏验证。",
      "旧小数以原型内存 fixture 注入；不证明真实照片记录保存与恢复。",
      "待补设计清单只核对范围与状态登记，不计为已有稿或原生功能通过。",
    ],
  };
}
module.exports = { reviewRegressions };
