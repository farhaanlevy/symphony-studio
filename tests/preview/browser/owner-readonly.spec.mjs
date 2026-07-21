// Copyright 2026 Symphony Studio contributors
// SPDX-License-Identifier: Apache-2.0

import AxeBuilder from "@axe-core/playwright";
import { captureEvidence, readProbe } from "./preview-contract.mjs";
import { expect, test } from "./preview-fixtures.mjs";

test("production Setup, Mission Control, and Run Detail expose fail-closed live truth", async ({ page }, testInfo) => {
  await page.goto("/setup");
  await expect(page.getByRole("heading", { name: "Setup", level: 1 })).toBeVisible();
  await expect(page.getByText("Credentials stay private.")).toBeVisible();

  const setupProbe = await readProbe(page);
  expect(setupProbe.authoritative).toBe(true);
  expect(setupProbe.mode).toBe("live");

  await page.goto("/mission-control");
  await expect(page.getByRole("heading", { name: "Mission Control", level: 1 })).toBeVisible();
  await page.keyboard.press("Tab");
  await expect(page.locator(":focus")).not.toHaveJSProperty("tagName", "BODY");

  const runRows = page.getByTestId("mission-run");
  if ((await runRows.count()) > 0) {
    const firstRun = runRows.first();
    await firstRun.getByRole("link", { name: "View run" }).focus();
    await page.keyboard.press("Enter");
    await expect(page.getByTestId("run-truth-state")).toBeVisible();
    await expect(page.getByTestId("run-completion-reason")).toBeVisible();

    const runProbe = await readProbe(page);
    const renderedState = await page.getByTestId("run-truth-state").getAttribute("data-state");
    if (runProbe.run?.completion?.status !== "completed") {
      expect(renderedState).not.toBe("completed");
    }
  }

  const axe = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag22aa"]).analyze();
  expect(axe.violations).toEqual([]);
  await captureEvidence(page, testInfo, "owner-readonly-production-routes", {
    acceptanceCriterion: "Production routes expose authoritative fail-closed state without fixture data",
    assertions: ["read-only runtime probe", "keyboard focus", "axe WCAG A/AA scan"],
  });
});
