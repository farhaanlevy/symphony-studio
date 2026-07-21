// Copyright 2026 Symphony Studio contributors
// SPDX-License-Identifier: Apache-2.0

import { captureEvidence, readOwnerIntent, readProbe, validateDemoIssue, waitForProbe, writeHandoff } from "./preview-contract.mjs";
import { expect, test } from "./preview-fixtures.mjs";

test("owner intent reaches an evidence-backed completed run through real services", async ({ page }, testInfo) => {
  test.skip(process.env.SYMPHONY_PREVIEW_LIVE_WRITE !== "1", "BLOCKED: live-write acknowledgement is absent");

  await page.goto("/work/new");
  await expect(page.getByRole("heading", { name: "New Work", level: 1 })).toBeVisible();
  await page.getByLabel("Work request").fill(readOwnerIntent());
  await page.getByRole("button", { name: "Inspect and plan" }).click();

  const questions = page.getByTestId("clarification-question");
  await expect
    .poll(
      async () => (await page.getByTestId("proposal-task").count()) + (await questions.count()),
      { message: "clarifications or a proposal appear", timeout: 120_000 },
    )
    .toBeGreaterThan(0);
  const questionCount = await questions.count();
  expect(questionCount).toBeLessThanOrEqual(2);
  if (questionCount > 0) {
    await expect(page.locator(".recommended-answer")).toHaveCount(questionCount);
    await page.getByRole("button", { name: "Use recommended defaults" }).click();
  }

  const tasks = page.getByTestId("proposal-task");
  await expect(tasks.first()).toBeVisible({ timeout: 120_000 });
  const taskCount = await tasks.count();
  expect(taskCount).toBeGreaterThanOrEqual(3);
  expect(taskCount).toBeLessThanOrEqual(5);
  await expect(page.getByTestId("proposal-side-effects")).toContainText(/Linear|Backlog/);

  const proposal = await readProbe(page);
  expect(proposal.intent.status).toBe("proposed");
  expect(proposal.intent.publication).toMatchObject({ confirmedWrites: 0, status: "not_started" });
  expect(proposal.intent.mutationAudit).toMatchObject({ linearMutations: 0 });
  await captureEvidence(page, testInfo, "proposal-before-approval", {
    acceptanceCriterion: "The owner sees scope and side effects before external mutation",
    assertions: ["3-5 tasks", "zero confirmed writes", "explicit approval"],
    interactions: ["entered intent", "answered at most two clarifications"],
  });

  await page.getByRole("button", { name: "Review final proposal" }).click();
  await page.getByRole("button", { name: "Approve Backlog publication" }).click();
  const publish = page.getByRole("button", { name: "Publish approved tasks" });
  await publish.click();
  await expect(publish).toBeDisabled();
  const published = await waitForProbe(
    page,
    (value) => value.intent?.publication?.status === "confirmed",
    "idempotent Backlog publication confirmation",
    180_000,
  );
  expect(published.intent.publication.idempotencyStatus).toBe("confirmed");
  expect(published.intent.publication.confirmedWrites).toBe(taskCount);
  expect(published.intent.publication.duplicateIssues).toBe(0);
  expect(published.intent.publication.linearIssues).toHaveLength(taskCount);
  for (const issue of published.intent.publication.linearIssues) {
    validateDemoIssue(issue.identifier);
    expect(issue.state).toBe("Backlog");
  }

  await page.getByRole("button", { name: "Start first ready task" }).click();
  const admitted = await waitForProbe(
    page,
    (value) => Boolean(value.intent?.start?.runId && value.intent?.start?.status === "admitted"),
    "first ready issue admission",
    180_000,
  );
  const issueIdentifier = validateDemoIssue(admitted.intent.start.issueIdentifier);
  const runId = admitted.intent.start.runId;
  expect(admitted.run).toMatchObject({
    issueIdentifier,
    model: "gpt-5.6-sol",
    reasoningEffort: "ultra",
    runId,
    workspace: { isolated: true },
  });
  writeHandoff({ issueIdentifier, runId, stateRunIds: admitted.stateRunIds });

  await page.goto("/mission-control");
  const runRow = page.getByTestId("mission-run").filter({ hasText: issueIdentifier });
  await expect(runRow).toBeVisible();
  await expect(runRow).toContainText("GPT-5.6 Sol");
  await runRow.getByRole("link", { name: "View run" }).click();
  for (const testId of [
    "run-objective",
    "run-acceptance",
    "run-plan",
    "run-phase",
    "run-commands",
    "run-changed-files",
    "run-checks",
    "run-independent-review",
    "run-evidence",
    "run-outcome",
  ]) {
    await expect(page.getByTestId(testId), `${testId} is present`).toBeVisible();
  }

  const completed = await waitForProbe(
    page,
    (value) => value.run?.runId === runId && value.run?.completion?.status === "completed",
    "evidence-backed completion",
    2_400_000,
  );
  expect(completed.run.checks).toMatchObject({ required: "passed" });
  expect(completed.run.review).toMatchObject({ detached: true, status: "passed" });
  expect(completed.run.evidence).toMatchObject({ current: true, sealed: true });
  expect(completed.run.trackerHandoff).toMatchObject({ status: "confirmed" });
  expect(completed.run.delivery.commit ?? completed.run.delivery.pullRequest).toBeTruthy();
  await expect(page.getByTestId("run-completion-reason")).toContainText(/checks|review|evidence/i);
  await captureEvidence(page, testInfo, "evidence-backed-outcome", {
    acceptanceCriterion: "Completion requires checks, detached review, evidence, and tracker confirmation",
    assertions: ["required checks passed", "review passed", "evidence sealed", "handoff confirmed"],
    fixture: issueIdentifier,
    interactions: ["published approved plan", "started first ready task", "opened Run Detail"],
  });
});
