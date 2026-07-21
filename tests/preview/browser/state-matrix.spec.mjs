// Copyright 2026 Symphony Studio contributors
// SPDX-License-Identifier: Apache-2.0

import AxeBuilder from "@axe-core/playwright";
import { captureEvidence, readHandoff, readProbe } from "./preview-contract.mjs";
import { expect, test } from "./preview-fixtures.mjs";

test("Setup exposes real repository, Linear, Codex, model, and readiness state", async ({ page }, testInfo) => {
  await page.goto("/setup");
  await expect(page.getByRole("heading", { name: /Setup/, level: 1 })).toBeVisible();
  for (const testId of [
    "setup-repository",
    "setup-linear-project",
    "setup-codex-auth",
    "setup-codex-compatibility",
    "setup-model-policy",
    "setup-readiness",
  ]) {
    await expect(page.getByTestId(testId), `${testId} is visible`).toBeVisible();
  }
  const probe = await readProbe(page);
  expect(probe.dependencies).toMatchObject({ codex: "ready", linear: "ready", store: "ready" });
  const axe = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag22aa"]).analyze();
  expect(axe.violations).toEqual([]);
  await captureEvidence(page, testInfo, "setup-readiness", {
    acceptanceCriterion: "Setup truthfully shows every preview dependency",
    assertions: ["authoritative probe", "axe WCAG A/AA scan"],
  });
});

test("Mission Control and Run Detail preserve keyboard and responsive task order", async ({ page }, testInfo) => {
  const handoff = readHandoff();
  test.skip(!handoff, "BLOCKED: no authoritative preview run handoff exists");
  await page.goto("/mission-control");
  const row = page.getByTestId("mission-run").filter({ hasText: handoff.issueIdentifier });
  await expect(row).toBeVisible();
  await page.keyboard.press("Tab");
  const focused = page.locator(":focus");
  await expect(focused).not.toHaveCount(0);
  await expect(focused).not.toHaveJSProperty("tagName", "BODY");
  await row.getByRole("link", { name: "View run" }).focus();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(new RegExp(`/runs/${handoff.runId}(?:$|[/?#])`));
  await expect(page.getByTestId("run-objective")).toBeVisible();
  await expect(page.getByTestId("run-next-action")).toBeVisible();
  const axe = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag22aa"]).analyze();
  expect(axe.violations).toEqual([]);
  await captureEvidence(page, testInfo, "run-detail-responsive", {
    acceptanceCriterion: "The primary run task precedes secondary chrome at each viewport",
    assertions: ["keyboard activation", "Run Detail", "axe WCAG A/AA scan"],
    fixture: handoff.issueIdentifier,
    interactions: ["focused View run", "activated with Enter"],
  });
});

test("browser disconnect shows reconnecting and replays authoritative state", async ({ page, context, browserAudit }) => {
  const handoff = readHandoff();
  test.skip(!handoff, "BLOCKED: no authoritative preview run handoff exists");
  browserAudit.allowExpectedNetworkFailures();
  await page.goto("/mission-control");
  await expect(page.getByTestId("connection-state").locator(".status-badge-live")).toBeVisible();
  const before = await readProbe(page);
  await context.setOffline(true);
  await expect(page.getByTestId("connection-state").locator(".status-badge-offline")).toBeVisible();
  await context.setOffline(false);
  await expect(page.getByTestId("connection-state").locator(".status-badge-live")).toBeVisible({ timeout: 30_000 });
  const after = await readProbe(page);
  expect(after.sequence).toBeGreaterThanOrEqual(before.sequence);
  expect(after.run.runId).toBe(handoff.runId);
});

test("current run states are derived from authoritative projection truth", async ({ page }, testInfo) => {
  const handoff = readHandoff();
  test.skip(!handoff, "BLOCKED: no authoritative preview run handoff exists");
  const entries = Object.entries(handoff.stateRunIds ?? {});
  expect(entries.length).toBeGreaterThan(0);
  expect(handoff.stateRunIds.completed).toBe(handoff.runId);

  for (const [state, runId] of entries) {
    expect(["active", "queued", "blocked", "validating", "reviewing", "completed", "incomplete"]).toContain(state);
    await page.goto(`/runs/${runId}`);
    const probe = await readProbe(page);
    expect(probe.run.runId).toBe(runId);
    expect(probe.run.state).toBe(state);
    if (state === "completed") {
      expect(probe.run.completion).toMatchObject({ status: "completed" });
      expect(probe.run.trackerHandoff).toMatchObject({ status: "confirmed" });
    } else {
      expect(probe.run.completion?.status).not.toBe("completed");
      await expect(page.getByText("Completed", { exact: true })).toHaveCount(0);
    }
    await expect(page.getByTestId("run-truth-state")).toHaveAttribute("data-state", state);
    await captureEvidence(page, testInfo, `truth-${state}`, {
      acceptanceCriterion: `${state} is not inferred from client progress`,
      assertions: ["probe run ID matches", "completion truth is fail-closed"],
      fixture: runId,
    });
  }
});

test("an unavailable run renders a clear failure without manufactured completion", async ({ page }, testInfo) => {
  const runId = "00000000-0000-4000-8000-000000000000";
  await page.goto(`/runs/${runId}`);
  await expect(page.getByRole("heading", { name: "Snapshot unavailable", level: 1 })).toBeVisible();
  await expect(page.getByText("Completed", { exact: true })).toHaveCount(0);
  const probe = await readProbe(page);
  expect(probe.run).toBeNull();
  await captureEvidence(page, testInfo, "truth-unavailable", {
    acceptanceCriterion: "An unknown run remains an explicit failure state",
    assertions: ["production route unavailable state", "no manufactured completion"],
    fixture: runId,
  });
});
