// 桌面更新的状态演示，不下载、校验或安装真实应用。
const assert = require("node:assert/strict");
async function reviewUpdate(browser, base) {
  const checks = [];
  for (const platform of ["macos", "windows"]) {
    const page = await browser.newPage({
        viewport: { width: 1440, height: 1000 },
      }),
      errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    const goto = async (scene) => {
      await page.goto(
        `${base}preview.html?platform=${platform}&scene=${scene}`,
      );
      // 初始化完成后再读全局模型；load 返回不替代可操作画面的就绪条件。
      await page.locator(".native-app").waitFor({ state: "attached" });
    };
    const action = (id) => page.locator(`[data-action="${id}"]`).last().click();
    const iter = (id) => page.locator(`[data-iter="${id}"]`).click();
    const phase = () => page.evaluate(() => download);
    const settings = async () => {
      if (platform === "macos") {
        await action("more");
        await page.locator('[data-flow="settings"]').click();
      } else await action("settings");
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
    const resolveGate = async () => {
      await iter("update:resolve-gate");
      await iter("update:draft-apply");
      await iter("update:retry-save");
    };
    try {
      await check("download-verify-cancel-and-retry", async () => {
        await goto("update");
        await action("download-update");
        await page.waitForFunction(() => download === "verifying");
        assert(
          (await page.locator(".update-window").innerText()).includes(
            "正在校验",
          ),
        );
        await action("cancel-download");
        assert.equal(await phase(), "available");
        await action("download-update");
        await page.waitForFunction(() => download === "verifying");
        await action("verify-failure");
        assert.equal(
          await page
            .locator('[data-flow-view="update-signature-error"]')
            .count(),
          1,
        );
        await iter("update:retry");
        await page.waitForFunction(() => download === "ready");
      });
      await check("install-gate-save-retry-wait-complete", async () => {
        await goto("update-ready");
        await action("install-update");
        assert.equal(
          await page.locator('[data-flow-view="update-install-gate"]').count(),
          1,
        );
        assert.equal(
          await page
            .locator(".update-window:not(.iteration-update-window)")
            .count(),
          0,
        );
        await iter("update:resolve-gate");
        await iter("update:draft-apply");
        assert.equal(
          await page.locator('[data-flow-view="update-save-blocked"]').count(),
          1,
        );
        await iter("update:retry-save");
        assert.equal(await phase(), "waiting");
        await action("close-update");
        await settings();
        await page.locator('[data-flow="update-settings"]').click();
        await page.locator('[data-flow-action="check-now"]').click();
        assert.equal(await phase(), "waiting");
        await iter("update:task-complete");
        assert.equal(await phase(), "installing");
        await action("simulate-install-complete");
        assert.equal(await phase(), "complete");
      });
      await check("install-error-retains-recovery-path", async () => {
        await goto("update-ready");
        await action("install-update");
        await resolveGate();
        await iter("update:task-complete");
        await action("simulate-install-failed");
        assert.equal(
          await page
            .locator('[data-flow-view="update-install-recovery"]')
            .count(),
          1,
        );
        assert((await page.locator(".flow-body").innerText()).includes("保留"));
      });
      await check("exit-install-remains-explicit-and-cancellable", async () => {
        await goto("update-ready");
        await action("install-later");
        await resolveGate();
        await iter("update:task-complete");
        assert.equal(await phase(), "pending");
        await action("cancel-install");
        assert.equal(await phase(), "ready");
      });
      await check(
        "support-info-is-read-only-migration-changes-eligibility",
        async () => {
          await goto("update-install-unsupported");
          assert.equal(
            await page.evaluate(() => RawLabIteration.installSupport()),
            false,
          );
          await page.locator('[data-action="iteration-close"]').click();
          await settings();
          await page.locator('[data-flow="update-settings"]').click();
          await page.locator('[data-flow="update-install-support"]').click();
          await iter("open:update-settings");
          assert.equal(
            await page.evaluate(() => RawLabIteration.installSupport()),
            false,
          );
          assert.equal(
            await page.locator('[data-flow-field="auto-install"]').count(),
            0,
          );
          await page.locator('[data-flow="update-seed-migration"]').click();
          await iter("open:update-migration-blocked");
          await iter("open:update-migration-done");
          await iter("update:migration-complete");
          assert.equal(
            await page.evaluate(() => RawLabIteration.installSupport()),
            true,
          );
          assert.equal(
            await page.locator('[data-flow-field="auto-install"]').count(),
            1,
          );
        },
      );
      assert.deepEqual(errors, []);
    } finally {
      await page.close();
    }
  }
  return checks;
}
module.exports = { reviewUpdate };
