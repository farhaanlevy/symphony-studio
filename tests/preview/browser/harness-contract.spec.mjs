// Copyright 2026 Symphony Studio contributors
// SPDX-License-Identifier: Apache-2.0

import { PNG } from "pngjs";
import { expect, test } from "@playwright/test";
import { assertPngIntegrity, readOwnerIntent, validateDemoIssue } from "./preview-contract.mjs";

test("protected R0 fixtures fail before any live browser work", async () => {
  expect(() => validateDemoIssue("SYM-1")).toThrow(/protected R0 fixture/);
  expect(() => validateDemoIssue("SYM-2")).toThrow(/protected R0 fixture/);
  expect(validateDemoIssue("SYM-314")).toBe("SYM-314");
});

test("committed owner intent is bounded and carries explicit acceptance criteria", async () => {
  const intent = readOwnerIntent();
  expect(intent).toContain("Acceptance criteria:");
  expect(intent).toContain("Copy evidence hash");
  expect(Buffer.byteLength(intent, "utf8")).toBeLessThan(64 * 1024);
});

test("screenshot integrity oracle rejects its black negative control", async () => {
  const image = new PNG({ width: 64, height: 64 });
  for (let offset = 0; offset < image.data.length; offset += 4) {
    image.data[offset] = 0;
    image.data[offset + 1] = 0;
    image.data[offset + 2] = 0;
    image.data[offset + 3] = 255;
  }
  const payload = PNG.sync.write(image);
  expect(() => assertPngIntegrity(payload, { width: 64, height: 64 })).toThrow(
    /effectively black|insufficient pixel variation/,
  );
});

test("screenshot integrity oracle accepts a varied control", async () => {
  const image = new PNG({ width: 64, height: 64 });
  for (let y = 0; y < image.height; y += 1) {
    for (let x = 0; x < image.width; x += 1) {
      const offset = (y * image.width + x) * 4;
      image.data[offset] = x * 4;
      image.data[offset + 1] = y * 4;
      image.data[offset + 2] = (x + y) * 2;
      image.data[offset + 3] = 255;
    }
  }
  expect(assertPngIntegrity(PNG.sync.write(image), { width: 64, height: 64 })).toMatchObject({
    height: 64,
    width: 64,
  });
});
