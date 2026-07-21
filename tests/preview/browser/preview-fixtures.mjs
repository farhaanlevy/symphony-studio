// Copyright 2026 Symphony Studio contributors
// SPDX-License-Identifier: Apache-2.0

import { expect, test as base } from "@playwright/test";

export const test = base.extend({
  browserAudit: [
    async ({ page }, use, testInfo) => {
      const consoleErrors = [];
      const pageErrors = [];
      const requestFailures = [];
      let allowExpectedNetworkFailures = false;

      page.on("console", (message) => {
        if (message.type() === "error") consoleErrors.push(message.text());
      });
      page.on("pageerror", (error) => pageErrors.push(error.message));
      page.on("requestfailed", (request) => {
        if (!allowExpectedNetworkFailures) {
          requestFailures.push(`${request.method()} ${new URL(request.url()).pathname}`);
        }
      });

      await use({
        allowExpectedNetworkFailures() {
          allowExpectedNetworkFailures = true;
        },
      });

      for (const [name, rows] of [
        ["console-errors", consoleErrors],
        ["page-errors", pageErrors],
        ["request-failures", requestFailures],
      ]) {
        if (rows.length) {
          await testInfo.attach(name, {
            body: Buffer.from(`${rows.join("\n")}\n`, "utf8"),
            contentType: "text/plain",
          });
        }
      }
      if (testInfo.status === testInfo.expectedStatus) {
        expect(consoleErrors, "browser console errors").toEqual([]);
        expect(pageErrors, "uncaught page errors").toEqual([]);
        expect(requestFailures, "unexpected failed requests").toEqual([]);
      }
    },
    { auto: true },
  ],
});

export { expect };
