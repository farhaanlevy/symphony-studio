// Copyright 2026 Symphony Studio contributors
// SPDX-License-Identifier: Apache-2.0

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { defineConfig, devices } from "@playwright/test";

const here = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(here, "../../..");

function isWithin(candidate, parent) {
  const relative = path.relative(parent, candidate);
  return relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`));
}

function assertNoSymlinkComponents(candidate) {
  let current = path.parse(candidate).root;
  for (const component of path.relative(current, candidate).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) {
      throw new Error("preview browser path contains a symlink");
    }
  }
}

function repositoryWorktrees() {
  const output = execFileSync(
    "git",
    ["-c", "core.quotepath=false", "worktree", "list", "--porcelain"],
    { cwd: repositoryRoot, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 },
  );
  return output
    .split("\n")
    .filter((line) => line.startsWith("worktree "))
    .map((line) => fs.realpathSync(line.slice("worktree ".length)));
}

function assertOutsideRepositories(candidate) {
  const canonical = fs.realpathSync(candidate);
  for (const worktree of repositoryWorktrees()) {
    if (isWithin(canonical, worktree) || isWithin(worktree, canonical)) {
      throw new Error("preview browser path intersects a repository worktree");
    }
  }
  for (let current = canonical; ; current = path.dirname(current)) {
    if (fs.existsSync(path.join(current, ".git"))) {
      throw new Error("preview browser path is inside a Git repository");
    }
    if (path.dirname(current) === current) break;
  }
  return canonical;
}

function validateProtectedFile(candidate, label) {
  const expanded = path.resolve(candidate);
  assertNoSymlinkComponents(expanded);
  const metadata = fs.lstatSync(expanded);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error(`${label} must be a regular file`);
  }
  if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) {
    throw new Error(`${label} must be owned by the current user`);
  }
  if ((metadata.mode & 0o777) !== 0o600) {
    throw new Error(`${label} must have mode 0600`);
  }
  assertOutsideRepositories(expanded);
  return expanded;
}

const baseURL = process.env.SYMPHONY_PREVIEW_BASE_URL ?? "http://127.0.0.1:4000";
const parsedURL = new URL(baseURL);

if (
  !["http:", "https:"].includes(parsedURL.protocol) ||
  !["127.0.0.1", "localhost", "::1"].includes(parsedURL.hostname) ||
  parsedURL.username ||
  parsedURL.password ||
  parsedURL.search ||
  parsedURL.hash
) {
  throw new Error("SYMPHONY_PREVIEW_BASE_URL must be an uncredentialed loopback URL");
}

const requestedArtifactRoot = path.resolve(
  process.env.SYMPHONY_PREVIEW_ARTIFACT_ROOT ??
    path.join(os.homedir(), ".local/state/symphony-studio-preview/evidence"),
);
assertNoSymlinkComponents(requestedArtifactRoot);
for (const forbidden of [path.parse(requestedArtifactRoot).root, os.homedir(), os.tmpdir()]) {
  if (requestedArtifactRoot === path.resolve(forbidden)) {
    throw new Error("Playwright artifact root is too broad");
  }
}
fs.mkdirSync(requestedArtifactRoot, { recursive: true, mode: 0o700 });
const artifactRoot = assertOutsideRepositories(requestedArtifactRoot);
fs.chmodSync(artifactRoot, 0o700);

const storageState = process.env.SYMPHONY_PREVIEW_STORAGE_STATE
  ? validateProtectedFile(process.env.SYMPHONY_PREVIEW_STORAGE_STATE, "paired browser state")
  : undefined;
const liveWrite = process.env.SYMPHONY_PREVIEW_LIVE_WRITE === "1";
const authenticatedUse = storageState ? { storageState } : {};
const dependency = liveWrite ? ["golden-desktop"] : [];

export default defineConfig({
  testDir: here,
  testMatch: /.*\.spec\.mjs/,
  outputDir: path.join(artifactRoot, "playwright-artifacts"),
  fullyParallel: false,
  workers: 1,
  retries: 0,
  forbidOnly: true,
  timeout: 120_000,
  expect: { timeout: 15_000 },
  reporter: [
    ["list"],
    [path.join(here, "preview-reporter.mjs"), { outputFile: path.join(artifactRoot, "playwright-summary.json") }],
  ],
  use: {
    baseURL,
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: "off",
  },
  projects: [
    {
      name: "harness-contract",
      testMatch: /harness-contract\.spec\.mjs/,
      use: { ...devices["Desktop Chrome"], viewport: { width: 1280, height: 800 } },
    },
    {
      name: "owner-readonly-desktop",
      testMatch: /owner-readonly\.spec\.mjs/,
      use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } },
    },
    {
      name: "owner-readonly-mobile",
      testMatch: /owner-readonly\.spec\.mjs/,
      use: { ...devices["Pixel 5"], viewport: { width: 390, height: 844 } },
    },
    ...(liveWrite
      ? [
          {
            name: "golden-desktop",
            testMatch: /golden-path\.spec\.mjs/,
            timeout: 2_700_000,
            use: {
              ...devices["Desktop Chrome"],
              ...authenticatedUse,
              viewport: { width: 1440, height: 900 },
            },
          },
        ]
      : []),
    {
      name: "desktop-1440",
      testMatch: /state-matrix\.spec\.mjs/,
      dependencies: dependency,
      use: {
        ...devices["Desktop Chrome"],
        ...authenticatedUse,
        viewport: { width: 1440, height: 900 },
      },
    },
    {
      name: "tablet-1024",
      testMatch: /state-matrix\.spec\.mjs/,
      dependencies: dependency,
      use: {
        ...devices["Desktop Chrome"],
        ...authenticatedUse,
        viewport: { width: 1024, height: 768 },
      },
    },
    {
      name: "mobile-390",
      testMatch: /state-matrix\.spec\.mjs/,
      dependencies: dependency,
      use: {
        ...devices["Pixel 5"],
        ...authenticatedUse,
        viewport: { width: 390, height: 844 },
      },
    },
    {
      name: "mobile-360",
      testMatch: /state-matrix\.spec\.mjs/,
      dependencies: dependency,
      use: {
        ...devices["Pixel 5"],
        ...authenticatedUse,
        viewport: { width: 360, height: 667 },
      },
    },
  ],
});

export { artifactRoot, baseURL, repositoryRoot };
