// Copyright 2026 Symphony Studio contributors
// SPDX-License-Identifier: Apache-2.0

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { expect } from "@playwright/test";
import { PNG } from "pngjs";
import { artifactRoot, repositoryRoot } from "./playwright.config.mjs";

export const forbiddenFixtureIssues = new Set(["SYM-1", "SYM-2"]);
export const probePath = "/api/preview/v1/verification";
export const liveWrite = process.env.SYMPHONY_PREVIEW_LIVE_WRITE === "1";
export const handoffPath = path.join(artifactRoot, "live-handoff.json");

function atomicPrivateJSON(destination, value) {
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  const temporary = `${destination}.${process.pid}.prepare`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      flag: "wx",
      mode: 0o600,
    });
    fs.renameSync(temporary, destination);
    fs.chmodSync(destination, 0o600);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

export function readOwnerIntent() {
  const configured = process.env.SYMPHONY_PREVIEW_INTENT_FILE;
  const input = configured
    ? path.resolve(configured)
    : path.resolve(repositoryRoot, "tests/preview/fixtures/owner-intent.md");
  const relative = path.relative(repositoryRoot, input);
  if (configured && relative !== "" && !relative.startsWith(`..${path.sep}`) && relative !== "..") {
    throw new Error("owner-provided intent must remain outside the repository");
  }
  const metadata = fs.lstatSync(input);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > 64 * 1024) {
    throw new Error("owner intent must be a bounded regular file");
  }
  const value = fs.readFileSync(input, "utf8").trim();
  if (!value) throw new Error("owner intent is empty");
  return value;
}

export async function readProbe(page) {
  const result = await page.evaluate(async (pathValue) => {
    const url = new URL(pathValue, window.location.origin);
    const intent = new URL(window.location.href).searchParams.get("intent");
    if (intent) url.searchParams.set("intent", intent);
    const run = window.location.pathname.match(/^\/runs\/([^/]+)$/);
    if (run) url.searchParams.set("run_id", decodeURIComponent(run[1]));
    const response = await fetch(url, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    return { body: await response.text(), status: response.status };
  }, probePath);
  expect(result.status, "authoritative preview probe HTTP status").toBe(200);
  expect(result.body.length, "authoritative preview probe byte bound").toBeLessThan(2 * 1024 * 1024);
  const value = JSON.parse(result.body);
  expect(value).toMatchObject({
    authoritative: true,
    mode: "live",
    schemaVersion: 1,
    source: "symphony_runtime",
  });
  expect(value.project).toMatchObject({
    slugId: "symphony-studio-build-week-3f2698765546",
    teamKey: "SYM",
  });
  return value;
}

export async function waitForProbe(page, predicate, label, timeout = 120_000) {
  let latest;
  await expect
    .poll(
      async () => {
        latest = await readProbe(page);
        return Boolean(predicate(latest));
      },
      { message: label, timeout, intervals: [250, 500, 1_000, 2_000] },
    )
    .toBe(true);
  return latest;
}

export function validateDemoIssue(identifier) {
  expect(identifier).toMatch(/^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,9}$/);
  expect(forbiddenFixtureIssues.has(identifier), "protected R0 fixture must remain untouched").toBe(false);
  return identifier;
}

export function writeHandoff(value) {
  const issueIdentifier = validateDemoIssue(value.issueIdentifier);
  if (value.stateRunIds?.completed !== value.runId) {
    throw new Error("preview handoff requires authoritative completed-run truth");
  }
  atomicPrivateJSON(handoffPath, {
    issueIdentifier,
    runId: value.runId,
    schemaVersion: 1,
    stateRunIds: value.stateRunIds,
  });
}

export function readHandoff() {
  const configured = process.env.SYMPHONY_PREVIEW_HANDOFF_FILE;
  const target = configured ? path.resolve(configured) : handoffPath;
  if (!fs.existsSync(target)) return null;
  const relative = path.relative(repositoryRoot, fs.realpathSync(target));
  if (relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`))) {
    throw new Error("preview handoff must remain outside the repository");
  }
  const metadata = fs.lstatSync(target);
  if (!metadata.isFile() || metadata.isSymbolicLink() || (metadata.mode & 0o777) !== 0o600) {
    throw new Error("preview handoff must be a mode-0600 regular file");
  }
  if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) {
    throw new Error("preview handoff must be owned by the current user");
  }
  const value = JSON.parse(fs.readFileSync(target, "utf8"));
  if (value.schemaVersion !== 1 || typeof value.runId !== "string") {
    throw new Error("preview handoff is malformed");
  }
  validateDemoIssue(value.issueIdentifier);
  return value;
}

export function assertPngIntegrity(payload, expectedViewport) {
  const image = PNG.sync.read(payload);
  expect(image.width).toBe(expectedViewport.width);
  expect(image.height).toBe(expectedViewport.height);
  let transparent = 0;
  let nearBlack = 0;
  const buckets = new Set();
  for (let offset = 0; offset < image.data.length; offset += 4) {
    const red = image.data[offset];
    const green = image.data[offset + 1];
    const blue = image.data[offset + 2];
    const alpha = image.data[offset + 3];
    if (alpha < 8) transparent += 1;
    if (red < 8 && green < 8 && blue < 8 && alpha > 247) nearBlack += 1;
    buckets.add(`${red >> 5}:${green >> 5}:${blue >> 5}:${alpha >> 5}`);
  }
  const pixels = image.width * image.height;
  expect(transparent / pixels, "screenshot is effectively transparent").toBeLessThan(0.98);
  expect(nearBlack / pixels, "screenshot is effectively black").toBeLessThan(0.98);
  expect(buckets.size, "screenshot has insufficient pixel variation").toBeGreaterThan(2);
  return { height: image.height, pixelBuckets: buckets.size, width: image.width };
}

export async function captureEvidence(page, testInfo, caseId, metadata = {}) {
  const viewport = page.viewportSize();
  if (!viewport) throw new Error("evidence capture requires a fixed viewport");
  const caseDirectory = path.join(artifactRoot, "cases", testInfo.project.name);
  fs.mkdirSync(caseDirectory, { recursive: true, mode: 0o700 });
  const screenshotPath = path.join(caseDirectory, `${caseId}.png`);
  const payload = await page.screenshot({
    animations: "disabled",
    fullPage: false,
    path: screenshotPath,
    scale: "css",
  });
  const pixels = assertPngIntegrity(payload, viewport);
  const digest = crypto.createHash("sha256").update(payload).digest("hex");
  atomicPrivateJSON(path.join(caseDirectory, `${caseId}.json`), {
    acceptanceCriterion: metadata.acceptanceCriterion ?? "preview browser state",
    assertions: metadata.assertions ?? [],
    browserProject: testInfo.project.name,
    caseId,
    consoleErrors: 0,
    failedRequests: 0,
    fixture: metadata.fixture ?? "authoritative Studio state",
    interactions: metadata.interactions ?? [],
    route: new URL(page.url()).pathname,
    schemaVersion: 1,
    screenshot: { path: screenshotPath, sha256: digest, ...pixels },
    status: "passed",
    viewport,
  });
  await testInfo.attach(`${caseId}-screenshot`, { body: payload, contentType: "image/png" });
}
