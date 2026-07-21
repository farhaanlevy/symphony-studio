// Copyright 2026 Symphony Studio contributors
// SPDX-License-Identifier: Apache-2.0

import fs from "node:fs";
import path from "node:path";

function writePrivateJSON(destination, value) {
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

export default class PreviewReporter {
  constructor(options = {}) {
    if (!options.outputFile) throw new Error("preview reporter requires outputFile");
    this.outputFile = options.outputFile;
    this.cases = [];
  }

  onBegin() {
    this.cases = [];
  }

  onTestEnd(test, result) {
    const status = result.status === "skipped" ? "blocked" : result.status;
    this.cases.push({
      durationMs: result.duration,
      project: test.parent.project()?.name ?? "unknown",
      status,
      title: test.title,
    });
  }

  onEnd() {
    const summary = {
      blocked: this.cases.filter((row) => row.status === "blocked").length,
      cases: this.cases.sort((left, right) =>
        `${left.project}:${left.title}`.localeCompare(`${right.project}:${right.title}`),
      ),
      failed: this.cases.filter((row) => !["blocked", "passed"].includes(row.status)).length,
      passed: this.cases.filter((row) => row.status === "passed").length,
      schemaVersion: 1,
    };
    writePrivateJSON(this.outputFile, summary);
  }
}
