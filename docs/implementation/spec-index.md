# Studio specification index

Source: root [`STUDIO_SPEC.md`](../../STUDIO_SPEC.md), imported byte-for-byte
from the Build Week product specification. Line references below refer to that
file at SHA-256
`1140f7ccd31881a83422f8ade2ffe1201064d232e756d7e2014e1022361a191d`.

## Normative map

| Concern | Authoritative section / lines | Implementation use |
|---|---|---|
| Directive, target, precedence, deferred scope | §0–0.3, lines 28–94 | `TARGET_RELEASE=R1.1`; build R0, R1, R1.1 only; Codex-only; evidence defines completion. |
| Execution and reading protocol | §0.4–0.4.1, lines 96–128 | Package-by-package work, compact checkpoints, exact clause retrieval. |
| Direct UI design | §0.5, lines 130–155 | Production LiveView slices, real state, browser evidence, no Figma dependency. |
| No-guess readiness | §0.6, lines 157–182 | Exact-version machine-readable readiness manifest; required capabilities fail closed. |
| Staged releases | §0.7, lines 184–393 | Branches, protected PR merge, manifests, packages, tags, upgrade/rollback. |
| Product thesis | §1, lines 397–458 | User, problem, product promise, value and success metrics. |
| Build Week contract and judging | §2, lines 459–579 | Submission constraints, attribution, claims and evidence package. |
| Fork and upstream preservation | §3, lines 583–727 | Required files, patch classes, invariants, sync, licensing. |
| Release boundaries and catalog | §4, lines 731–1051 | Atomic R0/R1/R1.1 results and exact feature-to-release ownership. |
| Complete Release 1 product contract | §5, lines 1052–4320 | Journey, architecture, Codex, lifecycle, quota, persistence, UI, security and tests. R0 hardens the shared foundations this contract identifies. |
| Work-package DAG and cut policy | §6, lines 4321–4418 | Authoritative dependency order, exit evidence, critical path and frontend order. |
| Deferred releases | §§7–11, lines 4419–5981 | Scope guard only; do not implement or expose R2+ placeholders. |
| Global guardrails | §12, lines 5982–6038 | Secrets, evidence, provider scope, UI and lifecycle constraints. |
| Submission runbook | §13, lines 6039–6255 | External media after v1.1.0; owner performs manual upload. |
| Completion contract | §14, lines 6256–6267 | Exact terminal definition for this implementation goal. |
| Verified external references | §15, line 6268 onward | Time-sensitive source list; refresh primary sources when used. |

## Release boundaries

| Stage | Branch base | Stable result |
|---|---|---|
| R0 / `v0.1.0` | `release/v0.1.0` from `UPSTREAM_BASE` | Hardened, pinned, upstream-compatible original runner with verified packaging and baseline return. |
| R1 / `v1.0.0` | `release/v1.0.0` from published `v0.1.0` | Complete local single-project Build Week MVP for existing Linear issues. |
| R1.1 / `v1.1.0` | `release/v1.1.0` from published `v1.0.0` | Feature-frozen, submission-hardened MVP and external-media tooling. |

No R2+ feature, route, disabled control, placeholder, or speculative provider
abstraction belongs in these releases.

## Work-package dependency and exit index

| ID | Depends on | Required exit evidence |
|---|---|---|
| R0-01 | — | “Untouched upstream suite passes; base SHA recorded.” The live-base adaptation decision and unchanged test-inventory proof are in the R0-01 checkpoint. |
| R0-02 | R0-01 | Pinned Codex version/schema hashes and deterministic fake Linear/App Server fixtures. |
| R0-03 | R0-02 | Framing, stderr, timeout, overload, frame-limit, and orphan-cleanup conformance. |
| R0-04 | R0-02–03 | Structured event, replay, stable-ID, and idempotency contracts. |
| R0-05 | R0-02–04 | Cancellation/retry properties, path safety, lifecycle denial, and outbox seams. |
| R0-06 | R0-02–05 | Exact compatibility/readiness manifest, real cap mapping, and Doctor-ready result. |
| R0-07 | R0-01–06 | Protected auto-merge, remote verification, installable `v0.1.0`, and baseline return. |
| R1-01 | R0-04–07 | SQLite PRAGMAs, crash/reopen, migration, artifact hash, backup and restore. |
| R1-02 | R1-01 | Persist-before-broadcast and projection rebuild. |
| R1-03 | R0-06, R1-01 | Config scope, last-known-good reload, and selective invalidation. |
| R1-04 | R0-06, R1-01–03 | Doctor pass/warn/fail, redaction, and startup blocking. |
| R1-05 | R0-06, R1-01, R1-03 | Role, pace, cap/depth, conflict, quality-lane, and optional tier tests. |
| R1-06 | R0-06, R1-01, R1-03, R1-05 | Dynamic bucket replacement, credits, waits, restart, account, and resume. |
| R1-07 | R0-03–05, R1-01–03 | Claims, operation ledger, crash windows, contract changes, and lifecycle outbox. |
| R1-08 | R1-01–03, R1-05–07 | Typed run-memory mandatory state and artifact round trip. |
| R1-09 | R1-08 | Compaction/rotation fault-injection preservation. |
| R1-10 | R1-01–03, R1-07–09 | Quality/evidence staleness and completion reducer invariants. |
| R1-11 | R0-06, R1-08–10 | Detached review and bounded repair E2E. |
| R1-12 | R1-06–11 | Circuit breakers and fail-closed approval/input recovery. |
| R1-13 | R1-02–04 | Pairing/security E2E, product brief, tokens, Component Lab, screenshots, contrast, accessibility baseline. |
| R1-14 | R1-02, R1-05–07, R1-13 | Real Mission Control → Run Detail slice, Work pace, one real control, Playwright and visual review. |
| R1-15 | R1-06–12, R1-13–14 | Complete Run Detail with long-content, recovery, responsive and accessibility E2E. |
| R1-16 | R1-01–02, R1-13 | History pagination and filters. |
| R1-17 | R1-05–06, R1-13 | Dynamic Usage buckets, credits, pace, waits, identity and optional Fast UI. |
| R1-18 | R1-04, R1-13 | Setup & Doctor compatibility evidence and remediation E2E. |
| R1-19 | R1-14–18 | Deterministic showcase fixture and judge-path rehearsal. |
| R1-20 | All prior R1 | Signed live, security, accessibility, performance, recovery, and soak readiness report. |
| R1-21 | R1-20 | Protected publication and independently installable verified `v1.0.0`. |
| R1.1-01 | R1-21 | Feature freeze; clean-machine, upgrade, backup/restore, live, visual, accessibility, restart, quota and soak evidence green. |
| R1.1-02 | R1.1-01 | Protected publication and verified `v1.1.0` assets. |
| R1.1-03 | R1.1-02 | Exact-release external scenes, captions, transcript, thumbnail and under-three-minute MP4 with checksums; no repository media binary. |

## Version-sensitive schemas and state machines

- Architecture, authority, runner independence and storage: §5.3.1–5.3.4.
- Internal run state and its authoritative transitions: §5.4.
- App Server version/schema lock, transport/process safety, method matrix and
  optional Fast compatibility: §5.5.1–5.5.4.
- Model/effort discovery and role policy: §5.6.1–5.6.8; selected/policy/effective
  delegation capacity and enforcement: §5.7.1–5.7.7.
- Workflow schema and harness/tool/loop contracts: §5.8–5.8.8.
- Issue contract, admission, claims, lifecycle, delivery and tracker sync:
  §5.9.1–5.9.11.
- Dynamic quota buckets, quality reserve, waits, identity and credits:
  §5.10.1–5.10.9.
- Typed memory/checkpoints/compaction/restart: §5.11.1–5.11.10; evidence,
  staleness, failure and breakers: §5.12.1–5.12.4.
- SQLite, quota waits, tracker outbox, event envelope and artifacts:
  §5.13–5.13.5.
- Five route families and their action/state contracts: §5.14–5.14.6; visual,
  interaction and accessibility contracts: §§5.15–5.17.
- Pairing, secrets, workspace and web trust boundaries: §5.18.1–5.18.8;
  fail-closed runtime states: §5.19; API/events: §5.20.
- Exact unit/property/contract/integration/browser/live/security/visual/soak
  gates: §5.22.1–5.22.9 and release acceptance in §5.23.
- Required lifecycle states and transitions are validated from persisted
  authoritative state; UI labels are not a second state machine.

Exact interfaces are reread from these sections immediately before their work
package. Generated capability fields are never inferred from this index.

## Security invariants and gates

- One trusted local operator; loopback-only by default. Remote exposure is out
  of supported Build Week scope and fails closed without explicit secure proxy
  and authentication configuration.
- Pairing secret/cookie integrity, CSRF, Origin and Host validation protect all
  read and mutation surfaces; showcase access is separately scoped and read-only.
- Secrets are allowlisted into children, redacted before persistence/broadcast,
  and excluded from databases, evidence, backups, logs, media, and releases.
- Workspaces enforce sanitized identifiers, root containment, symlink denial,
  bounded writable roots, safe cleanup, and no Docker socket exposure.
- Linear/repository/log/external content is untrusted data and cannot change
  policy, approvals, quota, completion, sandbox, secret, or authorization rules.
- Web output is escaped/sanitized with CSP and bounded artifact downloads.
- Approval and user-input flows fail closed and cannot be spoofed by ordinary
  events. Identity changes invalidate waits and resumptions.

Security acceptance evidence is mapped in
[`docs/security/threat-model.md`](../security/threat-model.md) and becomes a
required `studio/release-gate` input.

## Test and release gates

Smallest meaningful tests run during implementation. Each package then runs its
specified exit commands and diff review. Stable candidates additionally require:

- untouched upstream and Studio unit/property/contract/integration suites;
- browser, responsive, accessibility and visual evidence when UI applies;
- transport/schema/compatibility, security, migration, backup/restore, upgrade,
  rollback, clean-install, secret/media exclusion and provenance checks;
- a fresh independent read-only review bound to exact head and base SHAs;
- a sealed candidate manifest and current tested merge tree; and
- post-merge packaging, download, checksum, install and remote ancestry proof.

Only GitHub's protected merge may update `main`. A tag plus verified published
assets—not merely a merge—makes a stage released.
