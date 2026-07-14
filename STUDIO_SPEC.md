# Symphony Studio

## A quota-aware, proof-driven Codex delivery control room built as a disciplined fork of OpenAI Symphony

| Field | Value |
|---|---|
| Document status | Implementation-ready specification |
| Version | 1.6 — Staged stable releases, protected automatic fork publication, previous-release upgrade/rollback gates, and external submission-media production |
| Last verified | 2026-07-14 |
| Working repository | `symphony-studio` |
| Upstream | `openai/symphony` |
| Relationship | Downstream fork with an intentionally small, auditable patch surface |
| Stable source | Non-moving stable tag, verified GitHub Release marked `Latest`, and protected `main` after publication |
| In-progress source | One remote `release/<version>` branch; never the supported install target |
| Publication | Gated release PR with automatic merge, exact-SHA verification, tag, packages, and GitHub Release |
| Submission media | External `STUDIO_SUBMISSION_ROOT`; media binaries never enter Git history or GitHub Release assets |
| Primary stack | Existing Symphony Elixir/OTP and Phoenix LiveView stack |
| Frontend design method | Direct in-code LiveView design with browser verification; Figma is optional and never required |
| MVP tracker | Linear |
| Agent backend | OpenAI Codex App Server only; exact tested CLI version and generated protocol schema are release artifacts |
| Reference main agent | GPT-5.6 Sol with Ultra reasoning effort |
| Build Week category | Developer Tools |
| Submission deadline | 2026-07-21 at 5:00 PM Pacific Time |
| South Africa local deadline | 2026-07-22 at 02:00 SAST |

---

# 0. Implementation directive

Build **Symphony Studio** as a polished, reliable, Codex-only fork of OpenAI Symphony.

Do not replace Symphony’s core operating model. Preserve the parts that make Symphony valuable:

- Linear remains the MVP source of work.
- `WORKFLOW.md` remains the repository-owned policy contract.
- Each eligible issue receives an isolated workspace.
- A bounded orchestrator owns dispatch, reconciliation, retries, and cancellation.
- Codex App Server remains the execution harness.
- Issue state changes remain authoritative for whether work is eligible.
- The runner remains usable without the Studio interface.

Improve Symphony in two layers:

1. **Upstream-oriented hardening**
   - Small, generic changes that improve correctness, testability, event fidelity, safety, and recovery.
   - Changes must remain understandable as potential upstream contributions.
   - Existing upstream behavior and contracts must continue to pass conformance tests.

2. **Studio product layer**
   - A high-quality operator experience.
   - Persistent run history, memory checkpoints, evidence, quota protection, model-role policy, quality gates, and release diagnostics.
   - Studio-specific code must be namespaced and removable without rewriting the core orchestrator.

The Build Week MVP is intentionally narrow:

> Given an existing, eligible Linear issue, Symphony Studio safely assigns a GPT-5.6 Sol Ultra conductor, uses bounded supporting agents only when they add measurable value, preserves critical context through long runs, protects Codex quota for review and repair, verifies the work with deterministic checks and an independent review, and presents the entire run in a polished control room.

The MVP **does not** create a backlog, include a native todo list, or replace Linear. Planning and work creation begin in Release 2.

## 0.1 Mandatory build order

Codex SHALL implement the releases in this order:

1. Release 0 — fork foundation and Symphony hardening.
2. Release 1 — Build Week MVP.
3. Release 1.1 — submission hardening and freeze.
4. Release 2 — specification planner and Linear backlog generation.
5. Release 3 — preview deployments and release operations.
6. Release 4 — native work graph and todo system.
7. Release 5 — multi-project, remote execution, and collaboration.
8. Release 6 — Maintenance Autopilot for trusted bug, feedback, runtime, CI, and release signals.

No Release 2+ navigation, empty state, schema, abstraction, provider interface, or placeholder SHALL be added to the MVP unless Release 1 directly requires it.

The implementation run SHALL record a `TARGET_RELEASE` before coding begins. When the user does not provide one, the Build Week default is `R1.1`. The agent SHALL continue automatically from one published stage to the next until that target is reached unless a hard blocker or safety gate stops it, and it MUST publish and verify every intermediate stable release first. It MUST NOT begin work beyond the target merely because later releases are described in this document.

## 0.2 Scope-control rule

When a proposed feature is not explicitly required by Release 0, Release 1, or Release 1.1:

- do not build it;
- record it under its designated later release;
- do not add a disabled button for it;
- do not add a generic abstraction “for later” unless the MVP already has two concrete implementations;
- prefer a clear seam over speculative architecture.

## 0.3 Quality rule

No work is complete because an agent says it is complete.

A release, run, or work item is complete only when its required evidence exists and all applicable gates pass.

Private chain-of-thought MUST NOT be stored or shown. The product may show concise reasoning summaries, plans, decisions, assumptions, tool actions, commands, file changes, test results, review findings, blockers, and evidence.


## 0.4 Codex execution protocol for this specification

The implementation thread SHALL:

1. read the upstream `README.md`, root `SPEC.md`, Elixir README, `WORKFLOW.md`, and relevant tests before changing code;
2. run the untouched upstream validation suite and record the baseline;
3. implement one work package at a time in dependency order;
4. classify every edit to existing upstream code as Class A, B, or C before merging it;
5. add or update tests in the same change as behavior;
6. run the package’s exit commands before starting the next package;
7. keep a concise implementation journal containing decisions, failed approaches, and evidence;
8. use reversible defaults when the repository answers an ambiguity;
9. stop and report only when a hard external requirement is missing or the specification contains a real contradiction;
10. never start a later release merely because its section is present in this document.

For Build Week evidence, keep the majority of Release 0 and Release 1 core implementation in one primary Codex thread when practical. Use bounded secondary threads for independent review or isolated research, then run `/feedback` in the primary thread used for most core work.

### 0.4.1 Quota-efficient reading protocol

This document is comprehensive; it is not permission to resend the entire document to every agent or every turn.

The primary implementation thread SHALL:

1. read Sections 0, 3, 4, 5.1, 5.2, and 6 once to understand architecture, scope, and build order;
2. build a local heading/section index with stable anchors;
3. retrieve only the exact section, work package, interface contract, and acceptance criteria needed for the current change;
4. keep a compact package checkpoint containing section IDs, decisions, changed files, validation, and unresolved risk;
5. reread an exact clause when behavior depends on it rather than relying on a conversational paraphrase;
6. give supporting agents only the bounded task contract and relevant source references;
7. avoid loading Release 2+ sections during MVP implementation except to verify that a proposed feature is deferred;
8. never duplicate this entire specification inside `AGENTS.md`, `WORKFLOW.md`, an issue, or an agent prompt.

Repository instructions should act as a short map to this document and other sources of truth. Large outputs, test logs, and screenshots should be stored as artifacts and referenced by path/hash rather than pasted repeatedly.

## 0.5 Direct-in-code product design directive

Figma is **not** a dependency, prerequisite, source of truth, or required deliverable. Codex SHALL design and build the production interface directly in the Phoenix LiveView application. External screenshots, mood boards, or Figma files MAY be used as optional references when supplied, but the build must remain complete without them.

The UI workflow SHALL be design-first in intent and vertical-slice in implementation:

1. Write a concise product and visual brief before creating components.
2. Define route hierarchy, real content, state inventory, design tokens, and interaction rules.
3. Build production tokens and primitives in the real application, not a throwaway prototype.
4. Compose high-fidelity screens with typed fixtures that use the same presenter contracts as production.
5. Wire the first screen to authoritative Symphony state immediately.
6. Implement one complete route slice at a time: data, actions, loading, failure, accessibility, tests, and visual QA.
7. Inspect the rendered app in a browser with Playwright at desktop, tablet, and mobile widths.
8. Capture screenshots, critique the result, remove generic or unnecessary UI, and repeat until the visual quality gate passes.

The entire frontend MUST NOT be built as a disconnected static shell before runtime integration. A route is shippable only when its visible state is authoritative and every rendered control works. Mock-only product paths, dead buttons, fabricated progress, and design-only screens are release defects.

Every visible element must earn its place by helping the operator answer one of these questions:

- What is happening?
- Why is it happening?
- Is the result trustworthy?
- Is quota safe?
- What needs attention?
- What action is available now?


## 0.6 No-guess readiness gate

This specification is implementation-ready only when Release 0 produces a green, machine-readable readiness manifest for the exact checkout and installed tools. External interfaces are version-sensitive; Codex MUST discover and test them instead of filling gaps from memory.

Create `artifacts/readiness/implementation-readiness.json` containing at least:

- upstream Symphony commit and patch-ledger revision;
- installed Codex CLI version;
- generated App Server JSON Schema bundle hash;
- required and optional App Server method/field matrix;
- available model IDs and supported reasoning efforts;
- enforceable subagent-cap mapping for the pinned Codex version;
- advertised service tiers for each configured model;
- authenticated Codex mode and safe identity binding;
- current Linear project, state, label, and blocker capabilities;
- supported operating system and packaging result;
- all Release 0 conformance commands and outcomes.

Rules:

- a missing required capability is a blocking Doctor failure, not permission to invent a request field or silently degrade behavior;
- an optional capability is hidden when absent and cannot leave a disabled or misleading control behind;
- every Codex upgrade regenerates the schema bundle, reruns transport, quota, service-tier, review, compaction, goal, and multi-agent conformance tests, and invalidates the prior compatibility result;
- every upstream Symphony rebase reruns the untouched upstream suite before Studio patches are applied;
- every later release begins with an automated dependency-and-contract refresh against its current external integrations;
- the generated manifest is attached to the release evidence and shown in Doctor diagnostics without secrets.


## 0.7 Staged delivery and autonomous fork publication

Every release in this specification is a usable, recoverable checkpoint. Partial work for the next release MUST NOT reduce the usability of the latest stable release.

The authoritative installable stable state is:

- the most recent non-moving stable tag;
- the GitHub Release marked `Latest`;
- the release manifest and attached checksums for that exact tag.

Protected `main` normally matches that release after publication. During the narrow interval after a fully gated merge but before remote package publication finishes, `Latest` remains the supported install source and the release controller reports `release_pending_publication`.

Development for the next release occurs only on a separate release branch. A user may stop the implementation run at any time and continue using the last stable tag without waiting for the in-progress stage.

### 0.7.1 Stable version map

| Specification stage | First stable tag | Independently usable result |
|---|---|---|
| Release 0 | `v0.1.0` | Upstream-compatible Symphony with the hardened fork foundation, original runner workflow, and compatibility evidence. |
| Release 1 | `v1.0.0` | Complete local, single-project Symphony Studio MVP for existing Linear issues. |
| Release 1.1 | `v1.1.0` | Submission-hardened MVP with final packaging, judge path, and external demo-media tooling. |
| Release 2 | `v2.0.0` | MVP plus specification planning and idempotent Linear backlog generation. |
| Release 3 | `v3.0.0` | Prior features plus preview, staging, production-policy, and rollback operations. |
| Release 4 | `v4.0.0` | Prior features plus the Native work graph and todo system. |
| Release 5 | `v5.0.0` | Prior features plus multi-project operation, collaboration, remote execution, and notification routing. |
| Release 6 | `v6.0.0` | Prior features plus Maintenance Autopilot. |

Patch releases such as `v1.1.1` fix defects without changing the stage boundary. Optional release candidates use `vX.Y.Z-rc.N`, are marked prerelease, and MUST NOT replace `Latest`.

### 0.7.2 Branch model

Required branches:

```text
main                     latest gated merge; normally identical to published `Latest`
release/v0.1.0           Release 0 work until publication
release/v1.0.0           Release 1 work until publication
release/v1.1.0           Release 1.1 hardening until publication
release/v2.0.0           Release 2 work until publication
...
```

Rules:

1. Create Release 0 from the locked `UPSTREAM_BASE` commit; create every later release branch from the immediately previous stable tag, never from an unverified local branch.
2. Commit one coherent work package at a time.
3. Run that package's required checks before committing it.
4. Push the release branch to `origin` after every accepted work package so progress is durable and inspectable.
5. Never push release work to `upstream` or directly to protected `main`.
6. Keep the release branch current with `main` before the final release candidate gate.
7. Do not merge an incomplete stage merely to save progress; the remote release branch is the progress checkpoint.
8. After a stable release is published, create the next release branch from the published tag and continue only when it does not exceed `TARGET_RELEASE`.

### 0.7.3 Repository publication preflight

Before the first remote write, the release controller SHALL verify:

- `origin` resolves to the entrant's fork and not `openai/symphony`;
- `upstream` resolves to `openai/symphony`;
- the authenticated GitHub identity has permission to push branches, create pull requests, enable auto-merge, and create releases in the fork;
- `main` is the default branch;
- repository auto-merge and merge commits are enabled;
- `main` is protected by a branch rule or ruleset;
- required check names are unique and known;
- force pushes, branch deletion, and direct pushes are disabled for `main`;
- required checks cannot be bypassed by the release identity;
- the release automation token has only the minimum repository permissions it requires;
- no credential is embedded in a Git remote URL, workflow file, log, or release artifact.

The default single-owner Build Week profile does not require a human GitHub review. It requires a current independent-review artifact and a required `studio/release-gate` status check bound to the exact pull-request head SHA and base SHA. Before the Studio review coordinator exists, Release 0 uses a fresh, read-only Codex review thread with the same evidence schema; Release 1 and later use Studio's detached reviewer.

A repository owner may add a stricter human-approval rule. Automation must then wait at `awaiting_repository_approval` and MUST NOT bypass, remove, or weaken that rule.

Candidate-code workflows SHALL run with read-only repository permissions and without publication secrets. Privileged tag, release, and asset publication runs only from protected `main` after merge. Do not use `pull_request_target` to execute candidate code with write credentials.

A failed publication preflight does not invalidate completed local work. It blocks release completion, preserves the release branch and evidence, and reports the exact missing repository capability.

Minimum repository automation:

```text
.github/workflows/release-gate.yml       read-only candidate and test-merge checks
.github/workflows/publish-release.yml    privileged post-merge packaging and publication
scripts/release/doctor                   remote, ruleset, auth, and tool preflight
scripts/release/candidate                versioning, manifests, freeze, and PR reconciliation
scripts/release/verify                   local/remote integrity and install verification
scripts/release/publish                  idempotent tag, draft release, asset, and Latest publication
docs/releases/<version>/                 release notes and candidate evidence
```

Equivalent names are allowed only when the same responsibilities remain explicit and discoverable.

### 0.7.4 Automatic release pull request and merge

When every scope and quality gate for a stage passes, the release controller SHALL:

1. freeze the release branch against new work-package commits;
2. confirm a clean working tree and a current base branch;
3. rerun the complete stage test matrix on the exact release head and GitHub's current test-merge result against protected `main`;
4. run secret, license, generated-file, migration, artifact, and submission-media exclusion checks;
5. seal `release-candidate-manifest.json` against the release head SHA, base SHA, candidate tree SHA, and tested merge-tree SHA;
6. push the final head to `origin`;
7. open or update exactly one pull request from `release/<version>` to `main`;
8. populate the pull request with stage scope, prior tag, commits, migrations, compatibility data, test evidence, independent-review evidence, known limitations, and rollback instructions;
9. enable GitHub auto-merge using a merge commit after all required status checks and repository requirements pass;
10. when the fork uses a merge queue, enqueue only the release pull request, use release-queue group size `1`, and run the same required checks on GitHub's `merge_group` event;
11. when no merge queue is configured, require the release branch to be current with `main` before ordinary auto-merge;
12. refuse to merge if the pull-request head SHA or base SHA differs from the sealed candidate manifest, if the tested merge tree is stale, or if a new commit arrives after review;
13. let GitHub perform the protected merge; do not reproduce the merge locally and push around branch protection;
14. fetch `origin/main` and verify the merged tree equals the tested release-candidate tree;
15. run the post-merge verification suite on the exact merged `main` commit.

Required stable checks include, as applicable to the stage:

- untouched upstream tests;
- Studio unit, property, contract, integration, browser, accessibility, and security suites;
- generated App Server schema and compatibility-manifest checks;
- database migration, previous-release upgrade, backup, restore, and rollback tests;
- clean-machine package installation;
- independent review and evidence-manifest validation;
- release-claim and Build Week attribution audit for Release 1 and Release 1.1.

The release lifecycle is:

```text
building → candidate → awaiting checks → auto-merge enabled
         → merged → post-merge verification → packaging → published
         ↘ blocked/reverted
```

The workflow is idempotent by version. Re-running it reuses the same release branch, pull request, draft GitHub Release, and asset names; it reconciles remote state instead of creating duplicates.

If the base branch advances before merge, the release branch must be updated and every invalidated check and review artifact rerun. Auto-merge may proceed only on the new exact head and base.

### 0.7.5 Tag, package, and GitHub Release

After post-merge verification passes, automation SHALL:

1. build packages from the exact merged `main` commit, never from the pre-merge branch;
2. verify that the merged tree SHA matches the sealed tested merge-tree SHA;
3. create a non-moving stable tag for the stage;
4. create or reuse one draft GitHub Release for that version;
5. generate the final `release-manifest.json` from the merged commit and sealed candidate manifest, then attach the supported-platform archives, checksums, SBOM, license notices, readiness manifest, candidate manifest, final release manifest, migration report, test summary, and provenance report;
6. download and verify every attached asset and checksum from the draft release;
7. publish the GitHub Release and mark it `Latest` only after all asset verification passes;
8. verify the remote tag, release URL, published asset hashes, and `main` ancestry;
9. record the publication result in the implementation journal and stage evidence;
10. delete the remote release branch only after publication verification succeeds.

`release-candidate-manifest.json` SHALL include the stage, proposed version, previous stable tag, upstream base, release head SHA, base SHA, candidate tree SHA, tested merge-tree SHA, required checks, review-evidence hashes, migration plan, and approved waiver IDs. It is committed or attached to the release pull request and MUST be immutable for that exact head.

The post-merge `release-manifest.json` SHALL reference the candidate-manifest hash and include at least:

- specification stage and semantic version;
- release-branch head SHA, base SHA, candidate-manifest hash, tested merge-tree SHA, merged `main` SHA, and merged tree SHA;
- previous stable tag and upstream Symphony base SHA;
- Codex version, generated App Server schema hash, compatibility-manifest hash, and supported platform;
- database schema version, migration set, backup/restore result, and rollback classification;
- required check names and immutable evidence references;
- package names, sizes, SHA-256 values, SBOMs, and provenance;
- release pull-request number, merge time, tag, GitHub Release ID, publication time, and publication status;
- known limitations and approved waiver IDs, if any.

A stage is not `released` merely because its pull request merged. It becomes `released` only when the stable tag, GitHub Release, assets, and remote verification are complete.

If post-merge verification or packaging fails:

- do not create or move the stable tag;
- do not replace `Latest`;
- block the next release;
- retry a packaging-only or remote-publication failure idempotently without reverting code that passed the tested merge gate;
- create an automatic revert pull request when merged-code, migration, integrity, or clean-install verification fails and a safe deterministic revert is available;
- otherwise leave `main` visibly blocked, preserve the prior stable release as `Latest`, and produce an action-required report.

Tags MUST never be force-moved or reused. A correction after publication uses a new patch version.

### 0.7.6 Install, upgrade, and rollback contract

Every stable release SHALL support:

- a clean installation from its attached archive;
- a version command showing version, commit, upstream base, Codex compatibility hash, and build provenance (`./bin/symphony --version` or equivalent in Release 0; `./bin/studio version` from Release 1 onward);
- for Release 0, a clean install plus a tested return to the recorded upstream baseline;
- from Release 1 onward, an upgrade from the immediately previous stable release with existing data and configuration;
- pre-upgrade backup and integrity verification;
- migration dry-run where a migration exists;
- documented forward recovery and rollback behavior;
- rollback to the previous release when its schema remains compatible, or a tested restore-from-backup path when it does not;
- release notes that list additions, changes, migrations, known limitations, and rollback steps.

A release may not claim independent usability unless clean install and the applicable upgrade, baseline-return, rollback, or restore path pass on every claimed platform.

### 0.7.7 Code publication is not product deployment

This contract publishes Symphony Studio source and installable releases to the entrant's fork. It is required from Release 0 onward.

Release 3 deployment features are different: they deploy a user's managed project to preview, staging, or production environments. Do not defer fork publication until Release 3, and do not treat merging the Studio fork as a production deployment of a managed project.

### 0.7.8 Release boundary handoff

After every successful stable publication, the implementation thread SHALL report and record:

- stage, version, tag, merged commit, Git tree, and GitHub Release URL;
- supported install command and archive checksum;
- previous-version upgrade result and rollback or restore command;
- compatibility-manifest and release-manifest hashes;
- feature summary, known limitations, and approved waivers;
- the next release branch, or `target reached` when `TARGET_RELEASE` is complete.

The thread may then continue automatically to the next release up to `TARGET_RELEASE`. If the user stops or interrupts at the boundary, no partial next-stage work has entered `main`, and the reported stable release remains immediately usable.

---

# 1. Product thesis

## 1.1 Problem

Symphony already solves the basic orchestration problem: it converts eligible tracker issues into isolated Codex runs. Its reference implementation is intentionally an engineering preview. Operating it still requires substantial trust and attention:

- operators cannot easily see why a run is waiting, blocked, retrying, or consuming quota;
- an agent can appear successful without a complete, durable evidence trail;
- long sessions can lose important context after compaction or restart;
- retries can consume scarce quota without adding information;
- the existing dashboard is observability-oriented rather than a complete product experience;
- model and subagent choices are not governed by an explicit cost-versus-quality policy;
- judges or new users cannot quickly verify setup quality and product behavior.

## 1.2 Target user

The MVP targets one developer or technical product builder who:

- maintains one repository and one Linear project per Symphony instance;
- wants Codex to complete multiple existing issues with less supervision;
- has a limited Codex credit or rate-limit budget;
- values correctness, visible evidence, and a polished operational experience;
- is willing to run the product locally in a trusted environment.

## 1.3 Value proposition

Symphony Studio turns Symphony from “an agent daemon with a dashboard” into a trustworthy **delivery control room**:

- the right model performs the right role;
- quota is reserved for the steps that prevent bad work from shipping;
- critical context is exact and recoverable;
- every run has a visible plan, current action, blocker, evidence, and outcome;
- deterministic checks and an independent reviewer, not agent confidence, determine completion;
- setup failures are diagnosed before expensive work starts;
- the user can understand the system without reading terminal logs.

## 1.4 Product promise

The product promise is:

> Manage verified software outcomes instead of supervising Codex terminals.

The product does not promise universal autonomy, zero defects, exact remaining ChatGPT credits when the platform does not expose them, or guaranteed hackathon placement.

## 1.5 Success metrics

Release 1 targets:

- a clean install reaches a successful Doctor result within 10 minutes when prerequisites are present;
- an existing eligible Linear issue can travel from dispatch to accepted evidence without routine human steering;
- 100% of Studio-complete runs have required deterministic validation evidence;
- 100% of Studio-complete runs have an independent review result;
- restart recovery does not duplicate an eligible run;
- no critical memory record is lost during compaction, interruption, or restart tests;
- no secret appears in stored events, browser payloads, screenshots, or diagnostics;
- the UI shows no guessed state and no non-functional control;
- the reference demo completes reliably on a clean machine;
- median uncached input usage is lower than a naive “Sol Ultra for everything” policy on the benchmark suite;
- no Release 2+ feature is needed to understand or operate the MVP.

---

# 2. Build Week contract and judging strategy

## 2.1 Official submission constraints

The submission SHALL be designed around the official Build Week requirements:

- The project must meaningfully use Codex and GPT-5.6.
- The project must be working and runnable as depicted.
- The submission must choose one category.
- A public YouTube demo must be three minutes or less and include voiceover.
- The voiceover must explain the product, how Codex was used to build it, and how GPT-5.6 is used by the product.
- The repository must be available to judges and include clear installation and testing instructions.
- A `/feedback` Codex Session ID from the primary build thread must be submitted.
- A developer tool must include supported platforms, installation instructions, and a path for judges to test it without rebuilding from scratch.
- Because Symphony is pre-existing open-source software, the submission must clearly distinguish upstream code from new Build Week work and comply with the upstream license.

The Official Rules and current Devpost site prevail over this specification if requirements change.

## 2.2 Category

Submit to **Developer Tools**.

The primary audience is developers and engineering teams. The project improves agentic workflows, testing, delivery reliability, and operational control.

## 2.3 Judging criteria mapping

### Technological Implementation

Demonstrate:

- a real fork of Symphony, not a mock dashboard;
- deep Codex App Server integration;
- runtime model discovery;
- GPT-5.6 Sol Ultra as the root conductor;
- bounded custom agents;
- quota-aware admission and reserve policy;
- exact memory checkpoints around compaction and restart;
- detached independent review;
- deterministic evidence gates;
- crash-safe persistence and replay;
- a substantial automated test harness.

### Design

Demonstrate:

- a coherent control room rather than a collection of admin panels;
- real-time, truthful state;
- purposeful controls with correct disabled states;
- clean hierarchy and responsive behavior;
- accessible interaction;
- meaningful motion tied to state changes;
- clear setup, empty, failure, and recovery states;
- a polished judge path.

### Potential Impact

Demonstrate:

- reduced context switching;
- fewer wasted retries;
- protected quota for verification and repair;
- less need to inspect raw terminals;
- clearer accountability for autonomous code changes;
- a path from experimental orchestration to dependable daily use.

### Quality of the Idea

Position the novelty as:

> Symphony Studio is not another multi-agent chat UI. It is an evidence-driven, quota-aware operating layer for Symphony that treats context preservation, independent review, and delivery proof as first-class runtime concerns.

## 2.4 Tie-break priority

Technological Implementation is the first listed judging criterion and should receive the strongest evidence in the README and demo.

Visual polish must support the technical story rather than replace it.

## 2.5 Build Week evidence package

Release 1.1 SHALL include:

- `BUILD_WEEK_DELTA.md`
  - upstream repository URL;
  - exact upstream base commit;
  - fork creation date;
  - all material additions after the submission period began;
  - a component-level explanation of what remains upstream code and what is new;
  - links to dated commits;
  - primary `/feedback` Session ID placeholder;
  - model-role configuration;
  - screenshots and test evidence references.
- `README.md`
  - one-sentence value proposition;
  - architecture;
  - supported platform;
  - setup and demo path;
  - how Codex accelerated development;
  - where product and engineering decisions were made by the entrant;
  - how GPT-5.6 is used at runtime;
  - limitations;
  - license and upstream attribution.
- `docs/JUDGE_GUIDE.md`
  - fastest way to see the product;
  - live mode prerequisites;
  - recorded showcase mode;
  - exact test commands;
  - expected results;
  - troubleshooting.
- `docs/submission/DEMO_SCRIPT.md`
  - final three-minute narration.
- `docs/submission/SHOT_LIST.md`
  - scene order, exact release tag, routes, expected states, and retake boundaries.
- `docs/submission/CAPTURE_MANIFEST.yaml`
  - deterministic scene and export contract without media binaries.
- `docs/submission/RECORDING_CHECKLIST.md`
  - privacy, trademark, audio, duration, caption, and upload checks.
- an external submission-media manifest created outside every Git worktree;
- public or appropriately shared repository access;
- relevant Apache-2.0 attribution and notices;
- a clean release tag and checksum.

---

# 3. Fork strategy and upstream preservation

## 3.1 Repository relationship

Symphony Studio SHALL be a GitHub fork of `openai/symphony`, not a greenfield reimplementation and not a separate companion repository for the MVP.

Required remotes:

```text
origin    <entrant>/symphony-studio
upstream  openai/symphony
```

Required files:

```text
UPSTREAM_BASE
docs/architecture/fork-policy.md
docs/architecture/patch-ledger.md
BUILD_WEEK_DELTA.md
```

`UPSTREAM_BASE` contains the exact commit SHA used to create the Build Week fork.


### 3.1.1 Placement of this product specification

The upstream repository already uses root `SPEC.md` for the language-agnostic Symphony service contract. Do not destroy that source of truth.

When this document is imported into the fork:

- save this product specification as `STUDIO_SPEC.md`;
- leave upstream root `SPEC.md` byte-for-byte intact unless an intentional upstream sync changes it;
- link both documents from the README;
- treat upstream `SPEC.md` as the core-engine contract and `STUDIO_SPEC.md` as the fork product contract.

If the user explicitly requires this file to remain named `SPEC.md` outside the repository, rename it only when placing it into the fork.

## 3.2 Patch classes

Every non-trivial fork change must be classified in `patch-ledger.md`:

### Class A — upstreamable hardening

Generic improvements that do not depend on Studio:

- structured event sink boundary;
- deterministic event identifiers;
- safer cancellation and retry idempotency;
- explicit App Server capability discovery;
- reusable fake Linear and fake App Server test fixtures;
- clearer error types;
- workspace path and cleanup safety;
- conformance tests;
- bug fixes.

### Class B — Studio extension

Features intentionally kept in the fork:

- SQLite event and evidence store;
- run memory and checkpoints;
- quota guard and model-role policy;
- independent review coordinator;
- Studio LiveView interface;
- Build Week showcase mode;
- local diagnostics and release evidence.

### Class C — temporary compatibility patch

A necessary workaround for a specific upstream or App Server version. It must include:

- the triggering version;
- why it exists;
- removal condition;
- regression test;
- owner;
- link to any upstream issue.

## 3.3 Upstream invariants

The fork MUST preserve:

- the root Symphony specification’s scheduler semantics unless a documented Studio policy intentionally narrows them;
- the existing `WORKFLOW.md` keys and defaults;
- dynamic workflow reload;
- Linear tracker normalization;
- per-issue workspace layout;
- bounded concurrency;
- terminal-state cancellation and cleanup;
- restart recovery from tracker and filesystem;
- existing CLI behavior;
- existing JSON API fields under `/api/v1/*`;
- the ability to run the engine without Studio persistence or the Studio UI.

Unknown Studio front-matter keys must remain ignorable by upstream-compatible loaders.

## 3.4 Change budget

Release 0 SHOULD keep direct edits to existing upstream modules as small as practical.

Prefer:

- injected event sinks;
- new behaviours;
- wrapper modules;
- callbacks;
- optional supervisors;
- new namespaces;
- additive API fields.

Avoid:

- renaming core modules;
- replacing the orchestration state machine;
- moving every upstream file;
- rewriting the implementation in another language;
- introducing a general provider abstraction;
- changing Linear from the tracker of record;
- making Studio persistence required for core scheduling correctness.

## 3.5 Upstream sync workflow

CI SHALL include an upstream compatibility job:

1. fetch `upstream/main`;
2. report commits since `UPSTREAM_BASE`;
3. run the original upstream test suite;
4. run Studio conformance tests;
5. produce a range-diff summary;
6. fail only on actual incompatibility, not merely on new upstream commits.

Before each release candidate:

- merge or rebase the selected upstream commit intentionally;
- update `UPSTREAM_BASE` only when the fork baseline changes;
- review every conflict manually;
- rerun live smoke tests;
- update the patch ledger.

## 3.6 License and originality

The fork SHALL retain the Apache License 2.0 and all required notices.

The README must state clearly that the project builds on OpenAI Symphony and identify the Build Week additions. No submission material may imply that upstream Symphony was created during Build Week.

---

# 4. Release map

Every stage inherits all prior stable functionality and is published through Section 0.7 before the next stage begins. `main` and the GitHub Release marked `Latest` therefore remain usable while later work continues on a release branch.

A release boundary is atomic from the user's perspective: unfinished routes, disabled future controls, partial migrations, and mock-only implementations remain on the release branch and never enter `main`.

| Stage | Stable version | User can rely on |
|---|---|---|
| R0 | `v0.1.0` | A hardened, upstream-compatible Symphony runner and original observability experience. |
| R1 | `v1.0.0` | The complete local Build Week MVP. |
| R1.1 | `v1.1.0` | The submission-hardened MVP and external media export. |
| R2 | `v2.0.0` | Planning and Linear backlog generation in addition to the MVP. |
| R3 | `v3.0.0` | Preview and release operations in addition to R2. |
| R4 | `v4.0.0` | Native work graph and todo system in addition to R3. |
| R5 | `v5.0.0` | Multi-project, remote execution, collaboration, and notifications in addition to R4. |
| R6 | `v6.0.0` | Maintenance Autopilot in addition to R5. |

## 4.1 Release 0 — Fork Foundation

**Purpose:** Harden the upstream base before product work.

Deliver:

- fork policy and patch ledger;
- upstream baseline lock;
- unchanged upstream tests passing;
- fake Linear server/client fixture;
- fake Codex App Server fixture;
- structured event sink;
- stable run/attempt identifiers;
- typed failure classification;
- cancellation and retry idempotency tests;
- workspace safety tests;
- App Server model, reasoning-effort, feature, and service-tier discovery;
- exact Codex CLI version lock, generated App Server schema bundle, and compatibility manifest;
- protocol-safe stdout/stderr separation, fragmented/large-frame handling, request correlation, bounded overload retry, and child-process cleanup;
- conformance mapping for root issue capacity and optional subagent caps on the pinned Codex version;
- clean extension points for Studio storage, quota, memory, review, and managed tracker transitions.

Release 0 does not yet include the Studio MVP, but it is independently usable as the original Symphony runner with verified hardening. It SHALL be automatically merged and published as `v0.1.0` before Release 1 begins.

## 4.2 Release 1 — Build Week MVP

**Purpose:** Ship one exceptional workflow for existing Linear issues.

Deliver:

- one trusted local operator;
- one repository and Linear project per Symphony process;
- Codex-only execution;
- GPT-5.6 Sol Ultra conductor;
- bounded read-only supporting agents;
- dynamic provider-reported quota buckets, exact credit data when supplied, and reset times without fixed-window assumptions;
- quota guard with protected verification reserve;
- account-bound durable wait-and-resume after every blocking Codex limit clears;
- a three-position Work pace control that safely bounds root-issue and optional-helper parallelism;
- capability-gated Codex Fast service-tier compatibility, hidden when unavailable and not required for GPT-5.6 Sol;
- durable unique issue claims and an App Server operation ledger that reconcile crash-window and uncertain-start outcomes before retrying;
- immutable issue-contract snapshots, separate mutable eligibility snapshots, and deterministic managed Linear completion through a tracker outbox;
- renewable change-surface write leases that allow parallel read-only exploration while serializing conflicting implementation work;
- persistent run history and event replay;
- exact memory checkpoints;
- deterministic quality gates;
- detached independent review;
- bounded repair loop;
- a polished five-route LiveView experience;
- concise, progressive-disclosure interface copy;
- Setup Doctor;
- recorded showcase mode;
- complete tests, diagnostics, documentation, and release package;
- automatic protected publication of the complete MVP as `v1.0.0` before Release 1.1 begins.

The native todo list, Planner, automatic issue creation, deployments, multi-project portfolio, remote workers, accounts, collaboration, external notification channels, and Maintenance Autopilot are excluded.

## 4.3 Release 1.1 — Submission Hardening

**Purpose:** Freeze features and maximize reliability, clarity, and judge accessibility.

Deliver:

- zero known release-blocking defects;
- two-hour soak;
- clean-machine install rehearsal;
- live end-to-end rehearsal;
- recorded showcase fixture;
- final visual and accessibility QA;
- final README and judge guide;
- Build Week delta report;
- prebuilt `mix release` archive for every platform claimed as supported;
- optional container image only if its clean-machine path is fully tested;
- primary `/feedback` Session ID;
- automatic protected software publication as `v1.1.0` with release tag, GitHub Release, and checksums after every software-release gate passes;
- three-minute final demo export produced afterward from the exact published tag in the external submission workspace, not committed to the repository;
- transcript, captions, thumbnail, checksums, and YouTube upload handoff generated beside the external export.

No feature may enter Release 1.1 unless it fixes a submission blocker or is required to produce and verify the external submission package.

## 4.4 Release 2 — Spec Planner and Linear Backlog

**Purpose:** Turn product intent into high-quality Linear work.

This is the first release that creates todo/work items. It remains Linear-backed and Codex-only.

## 4.5 Release 3 — Preview Deployments and Release Operations

**Purpose:** Prove changes in a real environment and capture deployment evidence.

Start with provider-neutral command contracts and preview environments. Production remains explicitly gated.

## 4.6 Release 4 — Native Work Graph

**Purpose:** Add the built-in todo list, dependency graph, and AI-native work system.

A project uses exactly one tracker of record: Linear or Native. No live split-brain synchronization.

## 4.7 Release 5 — Multi-project, Remote Execution, and Collaboration

**Purpose:** Expand from one trusted operator and one project process to a portfolio and team product.

This release adds the operational complexity only after the single-project product is proven, including per-user notification routing across selected delivery channels.

## 4.8 Release 6 — Maintenance Autopilot

**Purpose:** Turn trusted bug reports, user feedback, runtime errors, failed checks, and post-release regressions into deduplicated, release-aware, verified maintenance outcomes.

Maintenance Autopilot does not blindly convert every incoming message into a coding task. It first verifies the source, removes sensitive data, classifies the signal, correlates duplicates, checks active work and release coverage, and establishes a reproducible failure or equivalent evidence. It creates a patch only when a new fix is actually required.

## 4.9 Provider policy

No non-Codex coding-agent backend is in scope through Release 6.

Do not build a provider marketplace, provider adapter abstraction, model router across companies, or parity benchmark against other coding agents. Optimize Codex quality and Codex quota usage first.

## 4.10 Authoritative feature-to-release catalogue

This catalogue is the scope index Codex SHALL use when deciding whether a feature belongs in the current build. The detailed release sections remain authoritative for behavior and acceptance criteria.

### Release 0 — Fork Foundation

| Feature | Ships in | User value / reason |
|---|---|---|
| Downstream GitHub fork with `origin` and `upstream` remotes | R0 | Makes the Build Week delta auditable and preserves upstream history. |
| `UPSTREAM_BASE` baseline lock | R0 | Proves which Symphony commit the project extends. |
| Patch ledger and patch classes | R0 | Keeps core changes small, reviewable, and potentially upstreamable. |
| Upstream compatibility CI | R0 | Prevents Studio work from silently breaking Symphony. |
| Fake Linear fixture | R0 | Enables deterministic orchestration tests without live quota or network dependence. |
| Fake Codex App Server fixture | R0 | Enables deterministic protocol, retry, and failure tests. |
| Versioned structured event sink | R0 | Gives the UI and evidence layer truthful runtime data. |
| Stable run and attempt identifiers | R0 | Makes replay, retries, and evidence correlation reliable. |
| Cancellation and retry idempotency hardening | R0 | Prevents duplicate or runaway work. |
| Workspace path and cleanup safety | R0 | Protects the host and preserves issue isolation. |
| App Server capability and model discovery | R0 | Prevents hard-coded, invalid model or protocol assumptions. |
| Pinned Codex version and generated schema bundle | R0 | Makes every App Server request, field, and optional capability reproducible for the release. |
| App Server transport conformance | R0 | Keeps stderr out of JSONL, handles fragmented/large messages, overload, timeouts, and orphan cleanup safely. |
| Multi-agent cap conformance | R0 | Proves how the pinned Codex version enforces direct-child and concurrent-thread limits before Ultra is allowed to delegate. |
| Additive extension seams for Studio | R0 | Lets Studio improve Symphony without replacing the core scheduler. |
| Protected staged release train | R0 | Keeps `main` and `Latest` usable while the next stage remains isolated on a release branch. |
| Automatic release-branch push and release-PR auto-merge | R0 | Publishes completed stages to the fork without bypassing required checks or branch protection. |
| Release manifest, immutable tag, GitHub Release, and verified assets | R0 | Gives every stage a reproducible install point and auditable provenance. |
| Previous-release upgrade, backup, restore, and rollback gate | R0 | Lets users adopt each stage without risking existing state. |

### Release 1 — Build Week MVP

| Feature | Ships in | User value / reason |
|---|---|---|
| Existing Linear issue polling and reconciliation | R1 | Starts with a proven source of work and avoids building a tracker too early. |
| Required-label opt-in | R1 | Prevents accidental dispatch of unprepared issues. |
| Existing per-issue isolated workspaces | R1 | Preserves Symphony’s core safety and execution model. |
| Codex account/authentication health | R1 | Fails before spending quota when Codex cannot run. |
| One-time local operator pairing | R1 | Protects source, logs, evidence, and mutation controls without adding a full account system. |
| Runtime model, effort, feature, and service-tier validation | R1 | Confirms the requested GPT-5.6 profiles and optional capabilities really exist for the authenticated account. |
| Capability-gated Fast routing | R1 | Lets Symphony request a provider-advertised Fast tier at a turn boundary when supported; the control is absent for GPT-5.6 Sol when Fast is unavailable. |
| GPT-5.6 Sol Ultra conductor | R1 | Places the strongest reasoning and delegation capability at the accountable root. |
| Work pace — Focused, Balanced, Accelerated | R1 | Lets the user trade elapsed time against simultaneous quota use without bypassing dependencies or quality gates. |
| Up to two read-only Terra explorers | R1 | Speeds independent repository discovery when Work pace, independence, and quota permit it. |
| Read-only failure analyst | R1 | Diagnoses evidence-backed failures without uncontrolled repair attempts. |
| Fresh detached Sol reviewer | R1 | Provides independent quality judgment before completion. |
| Release auditor command | R1 | Checks the complete Build Week delta and submission claims. |
| Thread goals and per-issue token budgets | R1 | Keeps long work directed and bounded. |
| Dynamic provider-backed limit buckets and remaining percentage | R1 | Adapts when Codex adds, changes, or temporarily removes windows instead of baking in a five-hour model. |
| Exact credit and spend-control display when supplied | R1 | Shows real provider values without confusing credits, spend controls, and token activity. |
| Recent account activity | R1 | Shows token activity separately from subscription limits so the two are not confused. |
| Protected validation/review/repair reserve | R1 | Prevents implementation from consuming the capacity needed to prove correctness. |
| Account-bound durable automatic wait and resume | R1 | Lets work continue after every blocking limit clears without switching accounts, duplicating turns, or retry storms. |
| Manual idempotent reset-credit redemption | R1 | Lets the user spend an earned reset intentionally; ordinary timed resets never require manual intervention. |
| Immutable issue-contract and mutable eligibility snapshots | R1 | Prevents changed requirements from reusing stale checks while avoiding invalidation for priority or blocker-only changes. |
| Managed Linear handoff transitions | R1 | Stops an agent from self-certifying completion and confirms tracker sync before Studio reports success. |
| Durable issue claims and App Server operation ledger | R1 | Prevents crashes, duplicate polls, and uncertain external responses from starting the same issue, thread, or turn twice. |
| Change-surface write leases | R1 | Allows useful parallel read-only discovery while serializing root writers whose planned change surfaces overlap. |
| Persistent normalized event history | R1 | Makes live activity, restart recovery, and judge replay trustworthy. |
| Exact memory records and checkpoints | R1 | Preserves critical requirements, decisions, blockers, and evidence. |
| Pre/post-compaction audit and fresh-thread fallback | R1 | Fails safe instead of guessing after context loss. |
| Deterministic quality commands and evidence manifest | R1 | Makes completion depend on reproducible proof. |
| Bounded repair loop and circuit breaker | R1 | Repairs useful failures while stopping wasteful repetition. |
| Setup command and Doctor | R1 | Converts setup problems into precise, actionable checks. |
| Direct-in-code design system and component lab | R1 | Produces a polished real application without a Figma dependency or throwaway shell. |
| Mission Control | R1 | Shows active work, eligible work, attention, and quota safety at a glance. |
| Run Detail | R1 | Makes one complete execution understandable without a terminal. |
| History | R1 | Lets users inspect and compare completed or failed attempts. |
| Usage | R1 | Shows reported limits, remaining percentage, reset timing, protected capacity, recent activity, and model roles. |
| Setup & Doctor interface | R1 | Makes preflight and remediation accessible in the product. |
| Recorded verified showcase mode | R1 | Gives judges a reliable no-credential path while clearly distinguishing recorded data. |
| Local packaging, judge guide, and Build Week evidence generator | R1 | Makes the developer tool installable, testable, and submission-ready. |

### Release 1.1 — Submission Hardening

| Feature | Ships in | User value / reason |
|---|---|---|
| Feature freeze | R1.1 | Protects reliability during the final submission window. |
| P0/P1 defect burn-down | R1.1 | Removes known release-blocking failures. |
| Clean-machine install rehearsal | R1.1 | Proves the documented judge path actually works. |
| Live Codex + Linear rehearsal | R1.1 | Confirms the recorded behavior matches the real product. |
| Visual, responsive, and accessibility final pass | R1.1 | Converts a functional tool into a coherent product experience. |
| Soak, reconnect, restart, and workflow-reload drill | R1.1 | Exposes leaks, duplicate work, and replay failures before submission. |
| Final release audit and attribution report | R1.1 | Ensures claims, licensing, and the Build Week delta are accurate. |
| External submission-media workspace | R1.1 | Keeps raw captures, audio, edit files, and final video outside the source repository and release archive. |
| Deterministic capture, caption, thumbnail, and export pipeline | R1.1 | Produces a repeatable three-minute demo from the exact stable release without turning video production into a core product feature. |
| Manual YouTube upload handoff | R1.1 | Lets the owner review privacy and quality before making the required public upload. |
| Public demo, README, release archive, checksum, and `/feedback` ID | R1.1 | Completes the required submission package. |

### Release 2 — Spec Planner and Linear Backlog

| Feature | Ships in | User value / reason |
|---|---|---|
| Prompt, pasted Markdown, and `SPEC.md` intake | R2 | Lets the user begin from product intent rather than prewritten tickets. |
| Read-only repository discovery | R2 | Grounds planning in real architecture, tests, and constraints. |
| Assumption, decision, and question registers | R2 | Makes ambiguity explicit and recoverable. |
| Versioned normalized specification | R2 | Preserves intent and provides a stable planning contract. |
| Acceptance matrix and validation strategy | R2 | Connects requirements to objective proof before implementation. |
| Dependency-aware plan and work DAG | R2 | Produces executable work in a safe order. |
| Fresh-context plan critic | R2 | Finds missing, duplicate, contradictory, or poorly tested work. |
| Idempotent Linear issue and blocker creation | R2 | Publishes high-quality work without duplicates. |
| Spec & Plan, Plan Review, and Change Request UI | R2 | Makes planning, revision, and impact visible. |
| Mid-flight impact analysis and replanning | R2 | Handles changed requirements without rewriting history. |

### Release 3 — Preview Deployments and Release Operations

| Feature | Ships in | User value / reason |
|---|---|---|
| Repository-owned deployment command contract | R3 | Supports many hosts without premature vendor integrations. |
| Immutable release artifact identity | R3 | Ensures the reviewed commit is the deployed commit. |
| Preview create, verify, and destroy | R3 | Proves changes in a real environment safely. |
| Deployment screenshots, logs, probes, and evidence | R3 | Extends the proof graph beyond local tests. |
| Staging promotion | R3 | Adds a controlled pre-production gate. |
| Explicit production confirmation and policy | R3 | Prevents accidental irreversible releases. |
| Tested idempotent rollback | R3 | Makes failed releases recoverable. |
| Releases interface | R3 | Shows environments, status, checks, URLs, and rollback readiness. |

### Release 4 — Native Work Graph and Todo System

| Feature | Ships in | User value / reason |
|---|---|---|
| Built-in local-first tracker | R4 | Removes the Linear dependency only after the core product is proven. |
| Native todo/work-item model | R4 | Stores outcome, scope, acceptance, dependencies, and evidence together. |
| Kanban board and dense list | R4 | Supports human work management inside Studio. |
| Dependency graph and critical path | R4 | Makes readiness and blockers visible. |
| Work Item Detail, search, and saved views | R4 | Makes larger native backlogs operable. |
| AI board steward | R4 | Proposes splitting, deduplication, readiness, and missing dependencies with safeguards. |
| Linear import/export and tracker switch | R4 | Enables deliberate migration without split-brain state. |
| One-tracker authority enforcement | R4 | Prevents Linear and Native from silently disagreeing. |

### Release 5 — Multi-project, Remote Execution, and Collaboration

| Feature | Ships in | User value / reason |
|---|---|---|
| Studio control plane with one isolated runner per active project | R5 | Scales beyond one repository without weakening runner isolation. |
| Project switcher and portfolio health | R5 | Lets a user operate several projects coherently. |
| User accounts, sessions, invitations, and project roles | R5 | Enables controlled collaboration. |
| Explicit project sharing | R5 | Shares only selected projects, not the whole installation. |
| Per-user Codex identities | R5 | Preserves credential and quota ownership. |
| Global fair capacity broker | R5 | Prevents one project from consuming every worker or quota window. |
| Project-scoped audit and authorization | R5 | Protects cross-user and cross-project boundaries. |
| Per-user notification preferences and channel routing | R5 | Lets each user choose which important updates arrive in-app, by email, in Slack, in Discord, or through a signed webhook. |
| Quiet hours, digest mode, deduplication, and delivery history | R5 | Keeps notifications useful instead of noisy or unreliable. |
| SSH worker pool | R5 | Adds remote execution through a bounded, testable first adapter. |
| Rootless containers for multi-user hosts | R5 | Provides stronger workload isolation. |
| Optional Kubernetes pool after SSH is proven | R5 | Adds larger-scale scheduling only when operationally justified. |

### Release 6 — Maintenance Autopilot

| Feature | Ships in | User value / reason |
|---|---|---|
| Unified maintenance-source contract | R6 | Accepts bug, feedback, error, CI, uptime, and release signals without confusing those sources with tracker authority. |
| GitHub App maintenance connector | R6 | Ingests structured issues/comments, failed checks, pull-request coverage, releases, and deployment status from the code host. |
| Linear maintenance connector | R6 | Reuses the selected tracker for bug intake, comments, labels, dependencies, and status write-back. |
| Sentry issue, feedback, and release connector | R6 | Adds production error groups, user feedback, stack traces, replays, affected releases, and release-health context. |
| Generic signed webhook source | R6 | Lets other bug-reporting or monitoring systems integrate through one small, documented schema instead of many premature SDKs. |
| Maintenance Signal and Maintenance Case models | R6 | Separates individual reports from the canonical defect or regression they may describe. |
| Signature verification, replay protection, and idempotent delivery | R6 | Prevents forged or duplicated external events from creating work. |
| PII, secret, attachment, and untrusted-content controls | R6 | Preserves useful debugging evidence without leaking customer or credential data into Codex, logs, or public trackers. |
| Deterministic-first correlation and reversible deduplication | R6 | Groups repeated reports while avoiding unsafe LLM-only duplicate decisions. |
| Release and fix-coverage graph | R6 | Detects whether a problem is unfixed, already being fixed, fixed but unreleased, deployed and monitoring, or regressed. |
| Active-work, dependency, change-surface, and backport checks | R6 | Prevents duplicate patches and schedules maintenance around work already in progress. |
| Reproduction and evidence gate | R6 | Requires a failing test, deterministic reproduction, or strong production evidence before a fix begins. |
| Observe, Triage, Prepare patches, and Guarded maintenance modes | R6 | Lets users choose automation depth without making production autonomy the default. |
| Risk-based maintenance policy | R6 | Keeps authentication, payments, data integrity, migrations, security, and other high-risk areas behind stricter gates. |
| Quota-aware maintenance budget and emergency lane | R6 | Fixes urgent regressions without starving planned work or bypassing review. |
| Verified automatic patch-to-PR loop | R6 | Reuses Symphony’s implementation, validation, review, repair, and evidence system rather than creating a weaker maintenance path. |
| Release observation and regression reopening | R6 | Resolves a case only after the fix reaches the affected environment and remains healthy for the configured evidence window. |
| Idempotent source write-back | R6 | Updates linked issues and reports without comment spam, premature closure, or overwriting human decisions. |
| Maintenance interface | R6 | Shows new, needs-evidence, covered, fixing, awaiting-release, monitoring, resolved, and regressed cases in plain language. |
| Maintenance notifications | R6 | Uses Release 5 routing for production regressions, action-required cases, patch outcomes, and release-monitoring results. |

### Explicitly not scheduled

The following are intentionally absent until a future evidence-backed revision adds them:

- non-Codex coding-agent providers;
- provider marketplace or provider comparison;
- billing and payments;
- public multi-tenant SaaS;
- native mobile apps;
- autonomous irreversible production deployment;
- generalized workflow-builder canvas;
- unbounded self-modifying maintenance policies;
- automatic public responses generated without a reviewed template;
- automatic remediation or disclosure of security incidents;
- decorative AI personas that do not improve outcomes.

---

# 5. Release 1 MVP — complete product specification

This section is self-contained. Codex should be able to implement the MVP without reading later release sections.

## 5.1 Core user journey

1. The user forks or clones Symphony Studio.
2. The user runs `./bin/studio setup`.
3. Setup verifies local dependencies, creates the SQLite database and instance secret, and prepares a local-operator pairing flow.
4. The user authenticates Codex and provides Linear credentials through environment variables.
5. The user copies or updates `WORKFLOW.md`.
6. The user runs `./bin/studio doctor`.
7. Doctor confirms:
   - upstream and Codex version/schema compatibility;
   - App Server transport and process safety;
   - Linear connectivity, project, state, comment, transition, blocker, and label capabilities;
   - repository bootstrap and workspace safety;
   - Codex authentication and identity binding;
   - GPT-5.6 Sol and Ultra availability;
   - supporting model and enforceable subagent-cap availability;
   - dynamic quota/credit response compatibility;
   - optional service tiers;
   - sandbox configuration;
   - required commands and detached review;
   - writable/recoverable storage;
   - browser/UI health.
8. The user starts Symphony Studio and pairs the local browser session once.
9. Mission Control shows eligible Linear issues, current Usage, selected/effective Work pace, model policy, and dispatch state.
10. The orchestrator claims an eligible issue and persists its contract and eligibility snapshots.
11. A Sol Ultra conductor starts with a typed goal and exact task context.
12. The conductor may spawn zero, one, or two direct read-only Explorers only when Work pace, independence, quota, and the pinned Codex cap permit it.
13. The conductor implements the change.
14. Studio runs deterministic quality gates.
15. A clean, detached reviewer inspects the current contract, diff, and evidence.
16. The conductor repairs blocking findings within the configured budget.
17. Studio seals tests, review, commit, checkpoint, and delivery evidence.
18. Deterministic Studio code writes the handoff marker and transitions Linear through the tracker outbox.
19. The run becomes completed only after Linear confirmation.
20. The user can replay the complete run without opening a terminal.
21. A quota reset, account-safe continuation, process restart, or browser reconnect preserves evidence and avoids duplicate work.

## 5.2 MVP functional scope

### Included

- Linear candidate polling, blocker/label eligibility, reconciliation, comments, and managed handoff transition.
- Immutable issue-contract and mutable eligibility snapshots.
- Required-label opt-in.
- Existing Symphony issue/workspace lifecycle.
- Exact Codex version/schema lock and App Server transport/process conformance.
- Codex App Server local login/status/model/capability discovery.
- GPT-5.6 model-role policy and Sol Ultra root conductor.
- Work pace with enforceable root and read-only helper ceilings.
- Capability-gated Standard/Fast Turn speed, hidden when unsupported.
- Studio goals and per-issue token budgets, mirrored to App Server when supported.
- Dynamic quota/rate-limit buckets, exact credits/spend control when supplied, and recent activity when supported.
- Protected quality capacity, account-bound durable quota wait, and automatic safe resume.
- Manual earned rate-limit reset redemption.
- Persistent event history and projection replay.
- Exact memory/checkpoint records and compaction/rotation recovery.
- Deterministic quality checks, detached review, bounded repair, and circuit breakers.
- Evidence manifest, staleness rules, completion reducer, and transactional tracker outbox.
- SQLite durability, content-addressed artifacts, online backup, and restore.
- One paired trusted local operator session.
- Polished five-route local control room.
- Setup Doctor.
- Read-only showcase fixture.
- Build Week evidence generator.
- Full automated test and recovery matrix.

### Excluded

- Planner chat.
- Spec ingestion.
- Automatic Linear issue creation.
- Built-in todo list or board editing.
- Native tracker.
- Multi-project switcher.
- User accounts, invitations, or sharing.
- Remote UI access as a supported Build Week path.
- Remote workers or Kubernetes.
- Hosted SaaS.
- Other coding-agent providers.
- Vendor-specific deployment integrations or production deployment.
- External notification channels.
- Maintenance-source ingestion or automatic bug patching.
- Billing.
- Mobile native application.
- Arbitrary workflow graphs.
- Vector database or semantic memory system.
- Hidden chain-of-thought display.

## 5.3 System architecture

### 5.3.1 Supervision tree

Recommended structure:

```text
Symphony.Application
├── Symphony.WorkflowStore                    # upstream
├── Symphony.Orchestrator                     # upstream authority
├── Symphony.WorkspaceSupervisor              # upstream
├── SymphonyWeb.Endpoint                      # upstream + Studio routes
└── SymphonyStudio.Supervisor                 # additive
    ├── SymphonyStudio.Repo                   # SQLite
    ├── SymphonyStudio.CompatibilityRegistry
    ├── SymphonyStudio.EventStore
    ├── SymphonyStudio.EventProjector
    ├── SymphonyStudio.IssueContractStore
    ├── SymphonyStudio.CapacityController
    ├── SymphonyStudio.QuotaGuard
    ├── SymphonyStudio.QuotaWaitScheduler
    ├── SymphonyStudio.RunMemory
    ├── SymphonyStudio.QualityCoordinator
    ├── SymphonyStudio.ReviewCoordinator
    ├── SymphonyStudio.TrackerOutbox
    ├── SymphonyStudio.Doctor
    ├── SymphonyStudio.ArtifactStore
    └── SymphonyStudio.PubSubBridge
```

### 5.3.2 Authority boundaries

- Linear is authoritative for current issue identity and tracker lifecycle state.
- The immutable Studio `IssueContractSnapshot` is authoritative for the exact contract-role fields against which one attempt is implemented and reviewed.
- The mutable Studio `IssueEligibilitySnapshot` is authoritative for the last reconciled state, required labels, blockers, priority, and dispatch eligibility.
- Studio SQLite is authoritative for durable issue claims and admission operations in Studio mode; the upstream orchestrator is authoritative for the currently attached worker process and mirrors the durable claim in memory.
- Git is authoritative for code, branch, commit, and diff state.
- Codex App Server is authoritative for thread, turn, item, approval, account, model, and service-tier events.
- Studio SQLite is authoritative for durable Studio events, checkpoints, evidence, capacity preferences, quota waits, managed tracker-transition outbox state, and historical projections.
- `WORKFLOW.md` is authoritative for repository-owned execution policy and hard capacity ceilings.
- The browser is never authoritative for runtime state.

In Studio mode, tracker lifecycle mutations are managed by deterministic Studio code:

- model roles may read Linear data and add narrowly scoped progress comments when policy permits;
- model roles may not move a managed issue into a handoff or terminal state, change required dispatch labels, or self-certify completion through raw GraphQL;
- Studio requests the configured handoff transition through an idempotent transactional outbox only after the current evidence gate passes;
- non-Studio upstream mode retains its existing workflow behavior;
- an external human transition remains authoritative for eligibility, but it cannot retroactively make incomplete Studio evidence valid.

### 5.3.3 Runner independence

When `studio.enabled` is absent or false:

- the original runner still starts;
- Studio storage is not required;
- Studio quality and quota gates do not alter dispatch;
- upstream dashboard and API remain usable.

### 5.3.4 Storage

Use SQLite in WAL mode for the MVP.

Reasons:

- single-user, local-first deployment;
- no external database setup;
- transactional checkpoints;
- reliable queryable history;
- easy backup;
- appropriate for the reference scale.

Large command output, screenshots, patches, and logs are stored as files under a content-addressed artifact directory. SQLite stores metadata and hashes.

## 5.4 Internal run state

Studio adds a durable phase projection without replacing tracker state:

```text
queued
preflight
exploring
waiting_for_change_surface
planning
implementing
validating
reviewing
repairing
waiting_for_quota
resuming
delivery
completion_pending_sync
completed
blocked
failed
cancelled
```

Rules:

- Tracker state and Studio phase are displayed separately.
- `completed` means Studio’s completion contract passed and the deterministic Linear handoff was confirmed; no model message or client state can set it directly.
- `waiting_for_quota` is non-terminal, remains claimed, and has one durable wake schedule.
- `waiting_for_change_surface` is non-terminal; read-only exploration may be complete, but writing waits for a conflict-free lease.
- `resuming` means eligibility, identity, quota, issue contract, and Work pace were rechecked and a conductor lease is being reacquired.
- `completion_pending_sync` means evidence is sealed but the configured Linear handoff transition has not yet been confirmed; it is non-terminal and cannot be displayed as success.
- `blocked` requires a typed blocker.
- `failed` requires a failure class and final diagnostic.
- a browser disconnect cannot change phase;
- a missing event sequence forces replay before the UI advances;
- an agent’s final message alone cannot set `completed`.

## 5.5 Codex integration and compatibility contract

### 5.5.1 Exact version and schema lock

Release 0 SHALL pin the exact Codex CLI/App Server version used by the release and generate both TypeScript and JSON Schema artifacts from that executable:

```bash
codex --version
codex app-server generate-ts --out priv/codex_schema/<version>/typescript
codex app-server generate-json-schema --out priv/codex_schema/<version>/json
```

Store:

- exact version string;
- executable checksum when obtainable;
- generated schema bundle checksum;
- required/optional method and field matrix;
- compatibility test result;
- date tested.

The adapter is generated or validated against that bundle. Documentation is guidance; the pinned generated schema is the request-shape contract for the running release. Doctor blocks managed dispatch when the installed version differs from the tested version unless that exact version has its own green compatibility record.

### 5.5.2 Transport and process safety

The reference transport is App Server stdio JSONL.

Requirements:

- stdout carries protocol JSON only;
- stderr is captured separately as bounded diagnostic logs and never fed into the JSON decoder;
- initialize exactly once, wait for its response, then send `initialized` before any other request;
- correlate every request by ID and apply method-specific timeouts;
- assemble fragmented JSONL frames safely and test messages larger than the upstream one-megabyte line boundary;
- enforce a configurable maximum decoded frame size, with a 16 MiB reference default, and fail with a typed diagnostic rather than allocating without bound;
- treat malformed JSON, duplicate responses, an unexpected response ID, or stdout contamination as protocol failures;
- treat JSON-RPC overload error `-32001` as transient and retry only idempotent requests with exponential backoff and jitter;
- preserve enough stderr tail, request metadata, and schema version to diagnose a failure without storing prompts or secrets;
- terminate the complete child process group on cancellation or shutdown and prove no orphan App Server remains;
- persist a prepared operation record before `thread/start`, `turn/start`, detached `review/start`, or another side-effecting App Server request;
- record request ID, method, canonical request hash, thread/turn context, send state, response/event correlation, and final reconciliation state;
- after connection loss or timeout, mark the operation `uncertain` and reconcile through thread/status/read/list and normalized events supported by the pinned version;
- never blindly reissue an uncertain `thread/start` or `turn/start`; when the exact outcome cannot be proven, checkpoint/block with `uncertain_external_outcome` rather than risk duplicate model work;
- use `clientUserMessageId` or another client identifier only when the generated schema exposes it, and do not assume it provides idempotency unless the conformance suite proves that behavior;
- never retry a tracker mutation or reset-credit consumption without its corresponding idempotency/reconciliation rule.

### 5.5.3 Required and optional operations

Studio SHALL initialize App Server once per worker connection and use the generated schema and runtime capabilities rather than hard-coded assumptions.

Required for the Build Week ChatGPT-backed reference profile:

- `initialize` and `initialized`;
- `account/read`;
- `account/rateLimits/read`;
- `account/rateLimits/updated` when emitted;
- `model/list`;
- `thread/start` and `thread/resume`;
- `turn/start` and `turn/interrupt`;
- `review/start` with detached delivery;
- `thread/status/changed`;
- `turn/*`, `item/*`, approval/input-request, and request-resolution events needed by the pinned schema.

Required product behavior that MAY be implemented by Studio when the corresponding App Server operation is absent:

- durable goals and token budgets;
- proactive checkpoint-based thread rotation;
- quota-wait persistence and scheduling;
- Work pace admission and root-run capacity;
- evidence sealing and tracker handoff.

Optional and hidden or safely substituted when unsupported:

- `account/usage/read`;
- `account/rateLimitResetCredit/consume`;
- `rateLimitsByLimitId` multi-bucket data;
- exact credit and spend-control fields;
- service tiers and per-turn `serviceTier` overrides;
- `turn/steer`;
- `thread/goal/set`;
- `thread/compact/start`;
- `thread/fork` for a recovery branch;
- experimental feature discovery.

An optional operation may not become an undeclared release dependency. When manual compaction is unavailable, Studio checkpoints and rotates before the tested context threshold. When `thread/goal/set` is unavailable, Studio keeps the canonical goal and budget in its own store. When `turn/steer` is unavailable, new operator input waits for the next safe turn boundary.

Studio treats `item/completed` as the authoritative final item state. It MUST NOT parse private internal reasoning or depend on rollout/transcript file formats as a stable API.

### 5.5.4 Turn speed and Codex Fast compatibility

**Work pace** controls parallelism. **Turn speed** controls an optional Codex service tier. They are separate settings and must never be presented as one slider.

The Build Week reference profile uses `Standard` for GPT-5.6 Sol unless live discovery reports a supported Fast tier. Fast is not an MVP acceptance dependency. As of the document’s 2026-07-14 verification, OpenAI’s Speed documentation lists Fast for GPT-5.5 and GPT-5.4, not GPT-5.6 Sol; the final demo therefore assumes Standard while runtime discovery remains authoritative.

Rules:

- do not send `/fast` as user text; slash commands are a CLI interface, not the App Server integration contract;
- discover the selected model through `model/list` and read its advertised service-tier entries and default tier from the pinned schema when those fields exist;
- match a human-facing Fast tier by provider metadata, but send the exact advertised tier `id`, never an assumed literal;
- require ChatGPT-backed authentication and any required Fast feature enablement reported by the installed Codex version;
- default to Standard;
- expose a `Turn speed` control only when the selected model/account actually supports an alternative tier; otherwise render no disabled placeholder;
- apply a tier change at the next turn boundary through the supported `thread/start`, `thread/resume`, or `turn/start` field; never interrupt an active turn merely to change speed;
- record requested and effective service tier on every attempt;
- if Fast is rejected or disappears, keep the current completed work, use Standard for the next safe turn, emit one concise warning, and rerun capability discovery;
- do not claim Fast saves tokens or quota; it is a latency choice that can consume credits faster;
- supporting roles inherit Standard unless their tested role configuration explicitly selects a supported tier.

## 5.6 Model-role policy

### 5.6.1 Runtime discovery

Doctor calls `model/list` and validates the authenticated account’s available model and effort combinations.

The reference Build Week profile requires:

- `gpt-5.6-sol`;
- exact `ultra` reasoning-effort support for `gpt-5.6-sol`;
- `gpt-5.6-terra`;
- Sol High or Max for detached review.

No model is silently downgraded.

When the reference profile is unavailable:

- Doctor fails the Build Week profile;
- the UI states exactly what is missing;
- an explicit compatibility profile may be selected for local development;
- the compatibility profile is visibly different and is not used for the final reference demo.

The reference quota demonstration uses ChatGPT-managed Codex authentication. API-key mode MAY run as a compatibility profile, but it must not promise ChatGPT subscription windows, account activity, Fast credits, or earned reset credits when those surfaces are unavailable. In that mode Studio still shows per-run tokens and Studio budgets, and labels provider subscription data `Unavailable`.


The `studio.models.*.reasoning_effort` field is a Studio-level policy value, not a raw pass-through guess about the current App Server request shape.

The Codex adapter SHALL map them only after capability discovery:

- root `thread/start` or `turn/start` uses the currently supported App Server effort field;
- project-scoped custom-agent TOML uses `model_reasoning_effort` when that schema supports it;
- Ultra is selected only when the authenticated account and selected model report support;
- unsupported values produce a Doctor failure;
- the adapter must not send an invented field or silently coerce Ultra to another effort.

### 5.6.2 Conductor

- **Name:** Conductor
- **Model:** `gpt-5.6-sol`
- **Reasoning effort:** Ultra
- **Sandbox:** workspace-write under the issue workspace
- **Multiplicity:** exactly one root conductor per active issue

Responsibilities:

- understand the issue and workflow contract;
- create the executable plan;
- decide whether delegation has positive value;
- synthesize read-only findings;
- make code changes;
- run targeted checks while implementing;
- resolve review findings;
- prepare the final evidence summary.

Why this role uses Sol Ultra:

- it owns ambiguous, multi-step, high-value decisions;
- it must integrate product intent, repository context, implementation, validation, and delivery;
- Ultra can delegate independent work when it materially improves quality or speed;
- concentrating the strongest profile at the root avoids paying flagship cost for every mechanical task.

Guardrails:

- it is the only write-capable model role in the MVP;
- it may not mark its own work complete;
- it may not bypass deterministic gates;
- it may not spawn nested subagents;
- it must record material decisions and blockers;
- it must stop when the issue budget or a hard policy boundary is reached.

### 5.6.3 Explorer

- **Name:** Explorer
- **Model:** `gpt-5.6-terra`
- **Reasoning:** Medium
- **Sandbox:** read-only
- **Multiplicity:** zero to two direct children

Responsibilities:

- map relevant code paths;
- locate tests, documentation, and ownership boundaries;
- trace callers and dependencies;
- identify likely change surfaces;
- return concise findings with exact file and symbol references.

Why this role uses Terra Medium:

- exploration is read-heavy and parallelizable;
- the output is evidence for the conductor, not the final decision;
- Terra offers strong repository reasoning at lower quota cost;
- read-only access prevents conflicting edits.

### 5.6.4 Failure Analyst

- **Name:** Failure Analyst
- **Model:** `gpt-5.6-terra`
- **Reasoning:** High
- **Sandbox:** read-only
- **Multiplicity:** at most one, only after a deterministic failure

Responsibilities:

- inspect failing test output, logs, and the current diff;
- classify likely root cause;
- distinguish product defect, flaky test, environment failure, and policy failure;
- propose the smallest next diagnostic or repair step;
- cite exact evidence.

Why this role uses Terra High:

- failure diagnosis needs deeper causal reasoning than ordinary exploration;
- it is invoked only when failure evidence exists;
- read-only analysis avoids uncontrolled repair attempts;
- the conductor remains responsible for edits.

### 5.6.5 Independent Reviewer

- **Name:** Reviewer
- **Model:** `gpt-5.6-sol`
- **Reasoning:** High by default; Max for high-risk work and final release audit
- **Sandbox:** read-only
- **Context:** fresh detached review thread

Responsibilities:

- review current changes against the issue and acceptance criteria;
- prioritize correctness, security, regressions, missing tests, and scope drift;
- ignore style-only comments unless they hide a real defect;
- classify findings as blocking, important, or advisory;
- include reproduction or verification steps;
- produce no code changes.

Why the reviewer does not use Ultra by default:

- review should be independent, bounded, and repeatable;
- proactive fan-out can waste quota and make findings harder to attribute;
- Sol High provides strong judgment;
- Max is reserved for high-risk or release-wide review.

### 5.6.6 Release Auditor

- **Name:** Release Auditor
- **Model:** `gpt-5.6-sol`
- **Reasoning:** Max
- **Sandbox:** read-only
- **Multiplicity:** one per release candidate

Responsibilities:

- inspect the complete Build Week delta;
- verify spec coverage, security, setup, tests, docs, demo claims, and license attribution;
- identify contradictions between product behavior and submission materials;
- produce a release-blocker report.

The Release Auditor is not run for every issue.

### 5.6.7 Deterministic work is not an agent role

Event normalization, token arithmetic, state projection, secret redaction, eligibility checks, test execution, hash calculation, and acceptance-gate evaluation MUST be deterministic code.

Do not create an “AI scribe” for work software can perform exactly.

GPT-5.6 Luna intentionally has no standing MVP role. The obvious Luna candidates—status extraction, event classification, and evidence formatting—are more reliable and cheaper as deterministic code. Luna may be benchmarked in a later release for high-volume, non-authoritative Planner transformations only after it demonstrates value over exact software.

### 5.6.8 Frontend design role policy

The MVP does not add a separate Figma agent or a mockup-only designer role.

For UI work:

- the Sol Ultra conductor owns the product decision, visual thesis, implementation, and browser iteration;
- an Explorer MAY inspect existing Phoenix/LiveView patterns, CSS conventions, and component boundaries read-only;
- the detached Reviewer applies the UX, accessibility, responsive, and state-completeness rubric to rendered screenshots and the running app;
- the Release Auditor verifies that the demo, screenshots, and claims match real application behavior.

This keeps design accountable to the same agent that must make the interface functional. It also avoids spending quota on a second speculative design that the implementation cannot support.

## 5.7 Work pace and delegation policy

### 5.7.1 Product control

The user controls parallelism through a three-position, discrete setting named **Work pace**. It is a labelled segmented slider/radio group, not an unbounded numeric concurrency input.

| Pace | Concurrent root issues | Optional Explorers per run | Global optional Explorer pool | Intended use |
|---|---:|---:|---:|---|
| `Focused` | 1 | 0 | 0 | Lowest simultaneous quota use; best for long-running work or a tight budget. |
| `Balanced` | 2 | 1 | 2 | Default; useful parallelism without a large quota spike. |
| `Accelerated` | 4 | 2 | 4 | Faster when several independent issues are ready and capacity is healthy. |

These values are product-profile ceilings, not promises that every slot will be used. `Balanced` is the default.

Work pace does **not**:

- change GPT-5.6 Sol Ultra into a weaker model;
- change Turn speed or enable Fast;
- bypass Linear blockers, required labels, Doctor, circuit breakers, quota reserve, sandbox policy, or quality gates;
- guarantee lower total token use in Focused mode or a fixed speed-up in Accelerated mode.

Focused reduces simultaneous consumption and removes optional exploration. The same required implementation may still need a similar total number of tokens over more elapsed time. Accelerated can consume quota faster because more useful work may run at once.

### 5.7.2 Selected, policy, and effective capacity

Studio keeps three values distinct:

1. **Selected pace** — the user preference persisted by Studio.
2. **Policy ceiling** — the maximum allowed by `WORKFLOW.md`, Doctor, and the compatibility manifest.
3. **Effective capacity** — what can safely run now.

Calculate effective capacity as the minimum of:

```text
selected pace ceiling
∩ WORKFLOW.md hard ceilings
∩ ready, dependency-unblocked Linear work
∩ current conductor and optional-helper leases
∩ Codex quota state and protected quality reserve
∩ local CPU, memory, disk, and process limits
∩ circuit breakers and shutdown/drain state
∩ enforceable limits reported by the pinned Codex compatibility manifest
```

The scheduler never manufactures work to fill a pace target. When only one issue is ready, Accelerated still runs one. When all remaining issues are blocked, it runs none.

The UI shows selected and effective state concisely, for example:

```text
Balanced · 1 active · 1 slot available
```

```text
Accelerated · 1 active · 3 blocked
```

```text
Focused · 3 active · applies as runs finish
```

A `Details` disclosure explains the limiting reasons. Do not show a false completion-time or token-savings percentage without measured project-specific evidence.

### 5.7.3 Safe change semantics

Changing Work pace is an idempotent, audited mutation.

- Increasing pace applies on the next scheduler/admission cycle and never forces the conductor to delegate.
- Lowering pace stops new root admission and new optional Explorer spawns until active counts fall within the new ceiling.
- Lowering pace does not interrupt a model turn, discard a child result, or cancel a run merely to reach the target immediately.
- `Pause new work` overrides root admission but allows an already-active quota-waiting run to resume unless the user selects `Drain and stop`.
- `Drain and stop` overrides Work pace and disables future automatic admission/resume after safe checkpointing.
- A restart restores the selected pace before quota waits and Linear candidates are reconciled.
- Required review, one bounded Failure Analyst invocation, and release auditing use protected quality capacity; they are not optional Explorers and cannot be disabled by Focused mode.
- Every model turn still consumes an identity-wide lease, so protected quality work cannot exceed the provider or host’s real capacity.

### 5.7.4 Codex enforcement

Studio enforces optional delegation at two layers:

1. deterministic Studio admission and role policy; and
2. the exact per-thread Codex configuration proven by Release 0 conformance tests.

Rules:

- `agents.max_depth` remains `1`; only the root may spawn direct children;
- Focused disables the multi-agent/collaboration spawn surface for the conductor when the pinned schema supports that control, rather than relying only on a prompt saying “do not delegate”;
- Balanced and Accelerated set both the general agent-thread cap and any active MultiAgentV2 per-session concurrency field required by the pinned schema;
- inject effective limits through a thread-scoped App Server `config` override when supported, or through a generated run-scoped Codex home/profile; never rewrite the user’s global `~/.codex/config.toml`;
- root-issue concurrency is applied through a typed Studio/orchestrator runtime control and bounded by the repository hard cap; changing pace does not rewrite `WORKFLOW.md`;
- persist the effective thread configuration/lock hash as run evidence;
- the compatibility manifest records whether the root counts toward each raw Codex cap and the exact raw values that yield zero, one, or two optional direct children;
- Studio never assumes `agents.max_threads` alone controls every Codex multi-agent implementation;
- a `SubagentStart` event that would exceed the effective optional-helper cap is rejected or immediately interrupted with a typed `capacity_limited` result and no automatic retry;
- if the installed Codex version cannot prove the requested cap, Doctor blocks managed Ultra dispatch instead of allowing unbounded proactive fan-out;
- supporting role files are read-only and may not override the Studio-enforced depth, write policy, or effective child ceiling.

### 5.7.5 Delegation value rule

Optional delegation is allowed only for independent, read-heavy questions whose parallel answer is expected to save time or improve coverage enough to justify additional quota.

- maximum two optional Explorers per conductor even in Accelerated;
- write-capable subagents are disabled;
- no child may spawn a child;
- no delegation for a task the conductor can complete with one targeted search;
- each child receives one bounded question, exact context references, and a structured output contract;
- the conductor emits a short `delegation.decision` event containing expected value and independence rationale;
- child output contains references, findings, uncertainty, and recommended next step, not raw logs already stored as artifacts;
- child timeout defaults to 10 minutes;
- orphaned children are interrupted when the parent ends;
- repeated delegation after no useful result opens the relevant no-progress guard.

A valid Balanced example:

- one Explorer traces the runtime path while the conductor studies the issue contract;
- the conductor waits, synthesizes, and edits.

A valid Accelerated example:

- Explorer A traces the runtime path;
- Explorer B locates tests and similar patterns;
- both are read-only and have non-overlapping questions.

Invalid examples:

- multiple agents edit the same files;
- one agent summarizes another agent;
- children recursively spawn more agents;
- a child exists only to produce status prose.

### 5.7.6 Change-surface safety

Parallel root issues use isolated workspaces, but isolation alone does not prevent two valid changes from colliding at integration time.

Rules:

- preflight, exploration, and planning turns run with a tested read-only sandbox and may overlap after ordinary dependency checks;
- before the first repository write, the conductor emits a structured predicted change surface containing exact paths, path prefixes/components, migration/config/API flags, and an `exclusive_repository_change` boolean;
- Studio normalizes that surface and transactionally acquires one renewable change-surface lease;
- only after lease acquisition may a subsequent turn receive workspace-write permissions; if the pinned App Server cannot apply the phase boundary safely, Studio starts a checkpoint-backed write thread or blocks instead of trusting a prompt-only rule;
- exact/prefix overlap, a shared migration or global-config surface, or an exclusive/unknown surface conflicts with another active writer unless workflow policy explicitly proves safe coexistence;
- a later conflicting run checkpoints, enters `waiting_for_change_surface`, releases its conductor/model lease, and shows the blocking run and component without exposing unrelated issue content;
- when the blocking lease clears, Studio rechecks issue contract, eligibility, workflow, identity, quota, Work pace, workspace, and Git state before resuming;
- file-change events outside the declared surface trigger a safe-boundary pause and deterministic lease expansion/recheck before more writes;
- a run with unintegrated changes retains its lease through validation, review, repair, delivery, and quota wait; a read-only or no-diff run may release it while blocked;
- a crashed process loses the lease only after expiry and workspace/Git reconciliation; an unintegrated diff is conservatively re-reserved before other writers enter;
- change-surface leases prevent avoidable simultaneous writes; they do not claim automatic merge safety and never replace required rebase/check/review behavior;
- an issue with no useful surface prediction is treated conservatively as repository-exclusive for writing, not guessed parallel-safe.

This guard should be small and deterministic. It is not a general distributed lock manager or semantic merge engine.

### 5.7.7 Persistence and events

Persist:

- selected pace and revision;
- source of the value: default, workflow, user, or temporary safety reduction;
- effective root/helper ceilings and limiting reasons;
- predicted change surface and active lease/expiry when writing;
- time the change becomes fully effective;
- actor and idempotency key.

Emit:

- `capacity.pace.changed`;
- `capacity.effective.changed`;
- `capacity.admission.denied` with structured reasons;
- `capacity.change_surface.waiting`, `capacity.change_surface.acquired`, and `capacity.change_surface.released`;
- `delegation.decision`;
- `delegation.capacity_limited`.

## 5.8 `WORKFLOW.md` Studio extension

Studio uses an additive top-level `studio` map. Upstream loaders may ignore it.

Reference schema:

```yaml
studio:
  enabled: true

  models:
    conductor:
      model: gpt-5.6-sol
      reasoning_effort: ultra
      required: true
    explorer:
      model: gpt-5.6-terra
      reasoning_effort: medium
    failure_analyst:
      model: gpt-5.6-terra
      reasoning_effort: high
    reviewer:
      model: gpt-5.6-sol
      reasoning_effort: high
    release_auditor:
      model: gpt-5.6-sol
      reasoning_effort: max

  codex:
    turn_speed: standard

  tracker:
    lifecycle_mutations: managed
    allow_agent_progress_comments: true

  capacity:
    default_work_pace: balanced
    allowed_work_paces:
      - focused
      - balanced
      - accelerated
    hard_max_concurrent_issues: 4
    hard_max_optional_helpers_per_run: 2
    hard_max_optional_helpers_global: 4

  delegation:
    max_depth: 1
    allow_write_subagents: false
    child_timeout_ms: 600000

  quota:
    policy: protected_reserve
    issue_token_budget: 120000
    review_reserve_tokens: 20000
    repair_reserve_tokens: 20000
    reserve_percent_when_limit_known: 25
    auto_resume_after_reset: true
    reset_safety_delay_ms: 15000
    reset_credit_policy: manual

  memory:
    checkpoint_on:
      - phase_change
      - pre_compact
      - turn_end
      - retry
      - pause
      - shutdown
    active_context_soft_limit_tokens: 40000

  quality:
    max_repair_cycles: 2
    require_detached_review: true
    require_clean_git_status_before_start: false
    checks:
      - id: format
        command: mix format --check-formatted
        required: true
      - id: compile
        command: mix compile --warnings-as-errors
        required: true
      - id: test
        command: mix test
        required: true

  delivery:
    mode: workflow_defined
    require_commit_sha: true
    require_pr_url: false
```

Rules:

- all fields have typed validation;
- invalid Studio config blocks new Studio dispatch but does not crash active workers;
- the last known good config remains active after an invalid reload;
- model and Turn speed changes apply at future thread/turn boundaries, not silently inside an active turn;
- the workflow sets the default Work pace and hard ceilings; the user may choose a lower or equal persisted pace at runtime;
- quality-check changes apply to future gate executions and create a new workflow snapshot;
- quota or capacity reductions apply immediately to new admission and optional child spawns but do not kill an active turn unless a hard provider, security, or shutdown boundary is reached;
- managed tracker mutation policy cannot be loosened by an agent prompt;
- secrets do not belong in `WORKFLOW.md`.

The exact numeric defaults are starting points, not claims about ChatGPT credit conversion. Token budgets are observed thread budgets; they are not displayed as currency.


### 5.8.1 Repository harness contract

The fork SHALL make the repository legible and operable to Codex before relying on longer prompts or more agents.

Required repository-owned harness files:

```text
AGENTS.md
WORKFLOW.md
.codex/
  config.toml
  agents/
    explorer.toml
    failure-analyst.toml
    reviewer.toml
    release-auditor.toml
  skills/
    studio-doctor/
    studio-validate/
    studio-review/
    studio-release-audit/
scripts/
  setup
  check
  test
  e2e
docs/
  architecture/
  operations/
  product/
```

The exact layout may follow upstream conventions, but each responsibility must have one discoverable source of truth.

### 5.8.2 Instruction architecture

`AGENTS.md` SHALL remain concise and navigational.

It contains:

- product purpose;
- upstream-preservation rule;
- current release boundary;
- architecture map;
- canonical commands;
- code ownership/boundaries;
- security constraints;
- completion contract;
- pointers to detailed documents and skills.

It must not duplicate the full product specification, every framework rule, or transient issue context.

Path-scoped instruction files MAY be used when a subsystem has materially different rules. The nearest applicable instruction wins, but a conflict checker SHALL fail Doctor when two active instruction layers contradict a hard invariant.

Stable instructions are placed before dynamic task content to improve prompt-cache reuse. Dynamic issue, diff, check, and blocker state is placed last.

### 5.8.3 Skills

A skill is added only when it removes a repeated, failure-prone workflow.

Every skill SHALL define:

- when it should be used;
- required inputs;
- commands or tools it may call;
- exact output/evidence;
- failure behavior;
- what it must not do;
- verification.

MVP skills:

1. `studio-doctor`
   - runs or interprets preflight;
   - returns structured pass/warn/fail results;
   - never edits credentials.

2. `studio-validate`
   - runs the configured targeted and full checks;
   - captures artifacts;
   - binds results to the current diff.

3. `studio-review`
   - initiates or consumes a detached review;
   - converts findings into the structured severity schema;
   - never changes code.

4. `studio-release-audit`
   - audits the complete release candidate and submission materials;
   - produces one release-blocker report.

Retain useful upstream commit, push, land, and Linear skills rather than recreating them. Modify them only when a tested Studio requirement demands it.

### 5.8.4 Tool policy

Start with the smallest useful tool surface:

- shell/file tools through Codex sandbox;
- Git;
- the existing Symphony `linear_graphql` client tool;
- repository-owned scripts;
- optional browser automation only for UI tasks and release QA.

Do not connect every available MCP server.

In Studio mode, replace unrestricted model-side Linear mutation with a mediated surface:

- read operations and optional progress-comment operations have separate typed tools or policies;
- validate GraphQL through a real parser/AST and an operation/field allowlist, not substring matching;
- reject multiple operations, unknown mutation roots, status/label/state mutations, endpoint overrides, and payloads above configured limits;
- bind every allowed comment to the current issue/run and redact its response;
- deterministic Studio tracker-outbox code alone performs managed handoff transitions;
- non-Studio upstream mode may retain its original raw behavior behind the existing trust posture.

Repository hooks and skills receive an explicit environment contract. They cannot rely on inheriting all Studio or host secrets.

A tool is admitted only when:

- it enables a concrete MVP workflow;
- its permissions are narrower than equivalent ad hoc shell access or clearly justified;
- failure and timeout behavior are known;
- output can be captured and redacted;
- it has a contract test or deterministic smoke test.

Tool descriptions must state constraints and rate limits early and clearly.

### 5.8.5 Hook policy

Use hooks for deterministic lifecycle work, not as the sole security boundary.

MVP hook uses:

- `SessionStart`: verify checkpoint/workspace identity and expose a concise run capsule;
- `PreCompact`: flush and validate the checkpoint;
- `PostCompact`: mark the thread pending preservation audit;
- `PostToolUse`: capture structured evidence for selected commands/tools when the App Server event is insufficient;
- `Stop`: verify critical memory flush and produce a stop diagnostic;
- `SubagentStart` and `SubagentStop`: enforce and record direct-child limits.

Rules:

- hooks are versioned in the repository;
- changed hooks require trust review according to Codex behavior;
- hook failure is visible and classified;
- hooks are bounded by timeout;
- multiple hooks may run concurrently, so correctness cannot depend on their execution order unless one wrapper command owns that order;
- authorization, sandbox, quota, and completion policy remain enforced by the orchestrator and deterministic code.

### 5.8.6 Agent loop contract

The conductor follows this loop:

```text
Orient → Explore → Plan → Implement → Targeted Check
       → Full Validate → Detached Review → Repair if needed
       → Delivery Evidence → Final Checkpoint
```

At every transition it SHALL answer, in structured form:

- current objective;
- evidence obtained;
- decision made;
- files or state changed;
- checks completed;
- blocker, if any;
- next action.

The loop stops when:

- completion gates pass;
- a hard policy boundary is reached;
- the budget stop triggers;
- the circuit breaker opens;
- the issue becomes ineligible.

The loop must not continue merely to produce a more polished status message.

### 5.8.7 Context-efficiency rules

- Reuse the root thread while its state remains valid.
- Use continuation guidance instead of resending the full task prompt.
- Keep stable policy and tool instructions in a cache-friendly prefix.
- Deduplicate exact instructions and records by stable ID/hash.
- Store full logs and diffs once; send concise metadata plus retrieval references.
- Retrieve targeted code and documents instead of injecting the whole repository.
- Report cached and uncached input separately when Codex supplies that distinction.
- Do not trade away critical exact state for lower token counts.
- Rotate to a fresh checkpointed thread when context quality degrades rather than repeatedly compacting summaries.

### 5.8.8 Harness readiness gate

Doctor SHALL score the repository harness before autonomous dispatch:

- reproducible setup;
- deterministic build/test commands;
- current architecture map;
- clear repository instructions;
- working Git workflow;
- reliable fixtures;
- observable application logs;
- UI/browser test path when relevant;
- security boundaries;
- rollback or recovery path;
- current Codex agents, skills, and hooks;
- baseline checks.

A missing harness capability that makes reliable execution unlikely is a blocking Doctor result, not something the conductor is expected to improvise expensively.


## 5.9 Issue admission and run lifecycle

### 5.9.1 Issue contract and eligibility snapshots

Studio separates what the issue **asks for** from whether the issue is **currently eligible to run**.

The Studio workflow compiler assigns every issue input path one role:

- `contract` — an implementation obligation whose change requires a new attempt;
- `eligibility` — mutable scheduling/continuation state;
- `display` — useful context that does not alter either decision;
- `excluded` — not sent to the model or stored beyond restricted diagnostics.

The default role map treats title and description as `contract`; state, priority, assignee, required labels, blockers, URL, and tracker timestamps as `eligibility` or `display`. `WORKFLOW.md` may explicitly promote another field into the contract, but the promotion is schema-validated and visible in Doctor. A mutable field must not be interpolated ambiguously into the contract prompt.

Create an immutable `IssueContractSnapshot` at admission from canonical JSON containing:

- schema version and contract-role map revision;
- stable Linear issue ID and identifier;
- title;
- description;
- every additional field explicitly assigned the `contract` role;
- tracker-provided branch or delivery metadata only when the workflow makes it an implementation obligation;
- content hashes and retained copies/references for promoted attachments or linked requirement text.

Canonicalization is deterministic: UTF-8, Unicode NFC for strings, sorted object keys, preserved array order, explicit nulls, normalized timestamps where a timestamp is deliberately contractual, and one documented serializer implementation. Store the SHA-256 as `issue_contract_hash`.

Bind the attempt, prompt capsule, checks, review, and evidence manifest to that hash and to the immutable `workflow_snapshot_hash`.

Create a separate mutable `IssueEligibilitySnapshot` containing current state, normalized required labels, blockers and their states, priority, assignee, URL, tracker timestamps, fetch time, source revision when available, and eligibility result/reasons. The model may receive this snapshot in a separately labelled operational section; it is not allowed to reinterpret it as the contract.

Reconciliation rules:

- a priority-only, blocker-only, assignee-only, URL-only, ordinary timestamp, or non-contract label change updates scheduling/eligibility without making code evidence stale;
- if a workflow explicitly promotes one of those fields to `contract`, its canonical promoted value participates in the hash and follows contract-change behavior;
- a terminal or otherwise ineligible state stops or cancels work according to upstream policy after Studio attempts a final safe checkpoint;
- a material contract-field change never reuses existing checks or review as current evidence;
- on a material contract change during an active run, finish or interrupt at the next safe boundary, checkpoint, create a new attempt with cause `issue_contract_changed`, invalidate prior check/review/completion evidence, rebuild the prompt capsule, and re-enter preflight automatically if the issue remains eligible;
- a change to `updatedAt` with identical canonical contract fields creates no new attempt;
- tracker comments are not contract input unless the workflow explicitly promotes a specific comment/attachment into a new contract revision;
- every contract transition records old hash, new hash, changed paths, source event, and affected evidence.

This distinction prevents stale acceptance evidence while avoiding wasteful restarts for ordinary prioritization or dependency changes.

### 5.9.2 Durable admission and claim

In Studio mode, an in-memory `claimed` set is not sufficient to prevent duplicate work across crashes.

Admission protocol:

1. fetch/reconcile the current issue contract and eligibility;
2. evaluate Doctor, workflow, identity, quota, Work pace, dependency, circuit-breaker, and existing-claim gates;
3. begin an immediate SQLite transaction;
4. acquire or create the one durable active claim for the Linear issue;
5. atomically create the run, first attempt, issue-contract/eligibility references, workflow reference, identity binding, selected pace revision, and random claim token;
6. commit before creating a workspace, App Server thread, or model turn;
7. mirror the committed claim into the upstream orchestrator and start the worker;
8. persist worker/thread attachment and heartbeat as they become known.

Invariants:

- a partial unique index or equivalent guarantees at most one non-terminal claim per Linear issue ID;
- repeated polls and duplicate webhook/reconciliation events return the existing claim rather than create work;
- failure before transaction commit creates no worker;
- failure after commit but before worker start leaves a recoverable `reserved` claim, not an untracked issue;
- lease/heartbeat expiry alone never proves a worker is absent; Studio reconciles process, App Server thread, workspace, Git, and event state before takeover or release;
- startup restores durable claims and marks their issues claimed before the first ordinary candidate poll;
- a claim is released only after cancellation/terminal reconciliation and required checkpoint/outbox durability;
- changing Work pace or priority changes scheduling, not claim identity.

Persist claim states such as `reserved`, `starting`, `active`, `waiting`, `completion_pending_sync`, `reconciling`, and `releasing`. Every transition is idempotent and evented.

### 5.9.3 Eligibility

An issue is eligible only when all upstream conditions pass and:

- Studio is enabled;
- Doctor has no blocking failure;
- the required model profile is available;
- quota admission passes;
- the Studio event store is writable;
- no unreconciled previous run owns the issue;
- the issue is not under an active circuit breaker.

### 5.9.4 Preflight

Before the first model turn of an attempt:

- persist the current immutable issue-contract snapshot and mutable eligibility snapshot in one transaction with the attempt claim;
- snapshot the effective workflow config and prompt template;
- record repository URL and base branch where available;
- record workspace path;
- record branch, HEAD, merge base, and git status;
- run configured lightweight baseline checks;
- create the initial memory record;
- persist the canonical Studio goal and token budget, and mirror them through App Server when the pinned version supports that operation;
- begin the orient/explore/plan phase with a read-only turn sandbox;
- verify the future workspace-write root equals the issue workspace;
- verify no secret value is present in the prompt.

A preflight failure consumes no conductor turn where possible.

### 5.9.5 Explore

The conductor, still read-only:

- reads the issue and repository instructions;
- decides whether to delegate;
- records affected areas and unknowns;
- produces a bounded plan tied to acceptance criteria;
- emits the structured predicted change surface required by Section 5.7.6.

Studio acquires the change-surface lease before entering Implement.

### 5.9.6 Implement

After the lease and workspace-write turn policy are active, the conductor:

- makes the smallest coherent change;
- keeps unrelated files untouched;
- runs targeted tests during work;
- records material decisions;
- updates plan state;
- checkpoints after meaningful milestones.

### 5.9.7 Validate

Studio runs the configured checks in order.

For each check record:

- ID;
- exact command;
- working directory;
- start and end time;
- exit code;
- duration;
- output artifact hash;
- truncation metadata;
- current commit/diff hash;
- required/optional status.

A required check failure enters diagnosis and repair. It never becomes a warning-only completion.

### 5.9.8 Review

After required checks pass:

- start a detached clean review;
- provide the exact `IssueContractSnapshot`, workflow snapshot, acceptance criteria, relevant decisions, current diff, and check evidence;
- do not include the conductor’s self-review conclusion as fact;
- store findings structurally;
- mark evidence stale if the diff changes after review.

### 5.9.9 Repair

For blocking findings:

- return exact findings to the conductor;
- increment repair cycle;
- apply changes;
- rerun affected checks;
- rerun detached review against the new diff.

Default maximum: two repair cycles.

After the maximum:

- checkpoint;
- mark the run blocked;
- preserve the workspace;
- display the unresolved findings and recommended next action;
- do not continue identical retries.

### 5.9.10 Delivery

The workflow may define local commit, pushed branch, pull request, or merge behavior.

Studio does not add a first-class GitHub integration in the MVP. It records delivery evidence emitted by the workflow or discovered from Git:

- commit SHA;
- branch;
- clean/dirty state;
- PR URL when present;
- CI summary when provided by the workflow;
- requested Linear handoff state.

A model may propose delivery metadata but cannot perform the managed lifecycle transition that declares the issue handed off or terminal.

### 5.9.11 Completion and tracker synchronization

Studio first seals candidate completion only when:

- the current issue-contract and workflow hashes match the attempt;
- all required checks pass against the current diff/commit;
- no unresolved blocking review finding remains;
- required commit/PR evidence exists;
- the final checkpoint is durable;
- the evidence manifest is complete.

Then Studio:

1. writes the sealed evidence manifest;
2. enters `completion_pending_sync`;
3. creates one deterministic handoff operation whose idempotency key derives from issue ID, run ID, target state, and evidence-manifest hash;
4. writes or reconciles one bounded Linear handoff comment containing the Studio run ID, evidence-manifest hash, final commit, check/review result, and operation marker;
5. transitions the issue to the configured handoff state;
6. retries/reconciles each sub-operation with bounded backoff;
7. confirms both the handoff marker and target state through mutation responses or reconciliation reads;
8. marks the Studio run `completed` only after confirmation.

Rules:

- the Build Week reference profile requires Linear comment and state-transition capability for managed completion;
- a failed or pending Linear write cannot be shown as completed;
- local idempotency and reconciliation are required even when Linear does not expose a native idempotency-key field;
- if the target state is already present, Studio still reconciles/writes its own handoff marker before confirming completion;
- a human-created matching state does not falsely become Studio provenance;
- if an external user moves the issue to a terminal state before gates pass, stop the run, preserve its workspace/checkpoint under retention policy, classify it `external_terminal_transition`, and do not claim Studio completion;
- if the issue becomes terminal while `completion_pending_sync`, reconcile the handoff marker and evidence; complete only when they match, otherwise block as an external transition;
- cleanup of a managed workspace is deferred until the final checkpoint and tracker outcome are durable;
- Studio-mode Linear tools exposed to models are allowlisted for reads and optional progress comments; raw status/label mutations that affect eligibility or completion are denied and audited.

## 5.10 Usage and rate-limit engineering

### 5.10.1 Authentication and source availability

The Build Week reference profile uses ChatGPT-backed Codex authentication because subscription limits, account activity, workspace credits, Fast-mode eligibility, and earned resets are ChatGPT account surfaces.

Studio uses:

- `account/read` for auth mode, safe account metadata, and plan type when supplied;
- `account/rateLimits/read` for a full rate-limit/credit snapshot;
- `account/rateLimits/updated` for sparse live changes;
- `account/usage/read` for historical token-activity summaries when supported;
- `turn/completed` and normalized usage events for per-run tokens;
- provider error metadata for the exact failed turn.

Auth-mode rules:

- ChatGPT-managed and other documented ChatGPT-backed modes may expose account limits, activity, credits, and earned resets;
- API-key mode may run only as a compatibility profile and must not display ChatGPT subscription quota, Fast credits, or earned resets unless the installed App Server explicitly supplies those values;
- when an endpoint is unsupported for the current auth mode, show the relevant section as `Unavailable` or omit it; do not turn unsupported account telemetry into a Doctor failure unless the Build Week reference profile requires it;
- historical token activity is never converted into remaining subscription capacity.

### 5.10.2 Dynamic bucket normalization

Codex limit policy is dynamic. Studio MUST NOT encode a permanent five-hour, weekly, primary, or secondary product model.

Normalize the full response as a collection of buckets:

```text
QuotaSnapshot
  status: complete | partial | stale | unavailable
  fetched_at
  identity_binding_id
  buckets[limit_id]
    limit_id
    limit_name?
    window_slots[]
      source_slot: primary | secondary
      used_percent
      window_duration_mins?
      resets_at?
    credits?
      has_credits
      unlimited
      balance?
    spend_control?
      limit
      used
      remaining_percent
      resets_at
    plan_type?
    reached_type?
  reset_credits?
```

Rules:

- prefer `rateLimitsByLimitId` when present;
- use the backward-compatible `rateLimits` object only as a single-bucket fallback when the multi-bucket map is absent, not as a duplicate of the same bucket;
- treat `limitId` as an opaque stable key and `limitName` as optional display metadata;
- preserve `primary` and `secondary` only as source slots; do not assign fixed duration or business meaning to either slot;
- a successful full read replaces the complete current bucket collection for that identity, so removed or temporarily disabled limits disappear from the UI and scheduler;
- a sparse update patches only fields actually supplied for its bucket and cannot delete omitted values or buckets;
- a failed full read never clears the last good snapshot; it marks it stale and retains its source time;
- clamp a reported `usedPercent` only for presentation: `remaining_percent = clamp(100 - usedPercent, 0, 100)`;
- preserve raw values in the restricted diagnostic snapshot and record any out-of-range provider value;
- display exact `credits.balance` only when supplied; respect `credits.unlimited` and `credits.hasCredits` without inventing a numeric value;
- keep `individualLimit`/spend-control values separate from credits and display its provider-supplied `limit`, `used`, `remainingPercent`, and `resetsAt` without currency conversion;
- use `availableCount` as the authoritative earned-reset total even if detail rows are absent or capped.

If a successful full read reports no window slots, the UI says `No limits reported`. This means only that Codex did not report a current window; it does not mean unlimited access. Exact credit or spend-control data may still appear separately.

### 5.10.3 User-facing Usage presentation

The ordinary interface uses short labels:

- page and navigation label: `Usage`;
- window value: `42% left`;
- reset detail: `Resets in 1h 18m` or `Resets Tue at 09:00`;
- run metric: `Tokens used`;
- protected policy: `Checks protected`;
- limit state: `Waiting for quota`;
- stale source: `Updated 8m ago`;
- refresh action: `Check now`.

Window naming order:

1. provider `limitName`, when non-empty and safe to display;
2. provider product label such as `Codex` plus a humanized current duration, for example `15 min window` or `7 day window`;
3. `Codex window` when duration is absent.

Do not retain a special `5-hour limit` label after that window disappears from a successful full snapshot.

A collapsed `Details` disclosure may say:

> Limits, credits, and reset times come from Codex. Missing values are not estimated.

Do not repeat this explanation on every card.

### 5.10.4 Protected quality capacity

Studio protects the ability to perform:

1. independent review;
2. one repair pass;
3. final evidence and release judgment.

This is a Studio admission policy, not a provider-guaranteed reservation. It uses:

- current complete/stale quota state and reached classifications;
- Studio per-run token budgets;
- active root/helper/quality commitments;
- configured review and repair budgets;
- selected Work pace;
- latest measured role usage where enough samples exist.

When protection cannot be justified, Studio denies new root admission first, then optional Explorer spawns. It never skips required checks or review to keep implementation running.

### 5.10.5 Admission order

When capacity is scarce:

1. finish a safe deterministic local check already running;
2. run required independent review;
3. allow one bounded repair or Failure Analyst turn for a blocking finding;
4. continue an already-active conductor when policy permits;
5. resume the oldest eligible quota-waiting run;
6. admit a new issue;
7. spawn optional Explorers last.

Work pace provides ceilings; this order decides which useful work receives the available slots.

### 5.10.6 Durable wait and automatic resume

A provider limit is a resumable waiting state, not an ordinary failed run.

State flow:

```text
running
→ checkpointing
→ waiting_for_quota
→ checking_quota
→ queued_resume
→ resuming
→ running
```

On a provider-classified limit or a turn failure mapped to `rate_limit`, Studio SHALL:

1. stop new turns for the affected Codex identity;
2. stop new root admission and optional Explorer spawns for that identity;
3. let safe local checks finish;
4. create a durable checkpoint for every affected run;
5. perform a full quota read when supported;
6. record every known blocking bucket/window, reached classification, credit/spend-control block, and provider reset time;
7. keep each issue claimed and outside the generic retry queue;
8. release idle App Server/model leases while preserving workspace, thread, attempt, and checkpoint references;
9. persist one active quota wait per run with an idempotent resume token and bound Codex identity;
10. show `Waiting for quota` and the next meaningful check or resume time.

Scheduling:

- when every blocking condition has a reset time, `wake_at` is the latest reset plus a clock-skew safety delay and bounded jitter;
- if at least one blocking condition has no reset time, use durable exponential account rechecks capped at 15 minutes;
- if exact credit/spend-control data says capacity requires credits, an owner action, or has no future reset, enter a typed `credits_required` or `usage_limit_requires_action` blocker instead of polling forever;
- persist wall-clock timestamps in UTC; use a monotonic timer only for the current process; recompute after restart or material wall-clock change;
- never create a throwaway model prompt to test capacity.

At a scheduled or user-requested recheck, Studio performs a fresh full read when available and resumes only when:

- the read is successful or the provider error metadata reliably shows the block has cleared;
- no known bucket, credit state, or spend control still blocks the required model work;
- the bound Codex identity still matches;
- the issue remains eligible and its current contract is reconciled;
- the run was not cancelled, drained, superseded, or circuit-broken;
- workflow, model, effort, sandbox, and compatibility manifest remain valid;
- the Studio token budget remains available;
- Work pace and protected quality capacity allow one conductor lease.

Resume behavior:

- continue the same logical Studio run and create a continuation attempt with cause `quota_reset`;
- resume the existing Codex thread only when persisted thread, checkpoint, issue contract, workspace, Git, and identity state agree;
- otherwise start a fresh thread from the last valid checkpoint;
- claim the quota wait transactionally before acquiring a turn lease;
- never create two turns for one wake-up or two active conductors for one issue;
- when several waits clear, resume one at a time in admission order rather than causing a thundering herd;
- emit `quota.wait.started`, `quota.wait.updated`, `quota.wait.ended`, and `run.auto_resumed`.

When a fresh successful full read reports no windows and no blocking classification after a prior limit, Studio may queue the oldest waiting run for one real continuation attempt. It still labels limits `No limits reported`, not `Unlimited`. If the continuation receives another rate-limit error, return it to durable waiting with increased backoff and no duplicate work.

Restart safety:

- restore selected Work pace and Codex identity bindings first;
- restore active quota waits before the first Linear candidate poll;
- mark those issues claimed before normal dispatch;
- check overdue waits immediately but never blindly launch a turn;
- cancel a wait when its issue becomes terminal/ineligible or the user drains/stops the run;
- `Pause new work` still permits an already-active waiting run to resume; `Drain and stop` does not.

User controls:

- `Check now` is single-flight and rate-limited;
- `Cancel wait` cancels the run after confirmation;
- `Use reset credit` appears only when an earned reset is available;
- ordinary timed reset and continuation require no user action.

### 5.10.7 Codex identity binding

Every attempt and quota wait binds to a non-secret `codex_identity_binding_id` representing the authenticated account/credential context that incurred the work.

The binding records only safe metadata and a local generation value. Use stable account identifiers supplied by App Server when available. Do not parse undocumented token files merely to obtain identity.

Rules:

- an `account/updated` event or fresh `account/read` that proves a different account invalidates automatic resume for the old binding;
- when stable account identity cannot be confirmed after an auth change, fail closed and require explicit confirmation;
- show `Codex account changed` with `Resume with current account` and `Cancel run`;
- choosing `Resume with current account` creates a new attempt and fresh thread from the last validated checkpoint, records the new binding, and never pretends the quota history belongs to one account;
- logout or credential revocation checkpoints work and blocks turns;
- an App Server process restart with the same verified account does not create a new logical identity.

### 5.10.8 Earned reset credits

Earned resets remain user-controlled.

- show `Use reset credit` only when the current full snapshot reports availability;
- show which waiting runs could resume;
- require explicit confirmation;
- call the idempotent consume method with a generated key and reuse that key for retries of the same logical redemption;
- treat `alreadyRedeemed` as success;
- treat `nothingToReset` and `noCredit` as non-destructive outcomes;
- perform a new full quota read after every outcome;
- never consume a reset automatically in Release 1;
- disable the action while pending and prevent duplicate submission.

### 5.10.9 Studio budget stop

A Studio token budget is separate from provider quota.

When an issue reaches its configured budget:

- do not start another model turn;
- finish safe local artifact writes/checks;
- checkpoint;
- classify the stop as `quota_budget`;
- show progress, unresolved work, and the minimum recommended continuation;
- do not auto-resume after a provider reset;
- require an explicit budget increase.

## 5.11 Memory and context engineering

### 5.11.1 Principle

Important state lives in typed records, not only in chat history or a model-generated summary.

### 5.11.2 Memory classes

#### Critical exact state

Must remain exact across compaction, restart, review, retry, and quota wait:

- `IssueContractSnapshot` ID and hash, including the issue ID, identifier, title, description, and every field rendered into the implementation prompt;
- current `IssueEligibilitySnapshot`, including state, required labels, blockers, priority, and tracker revision/freshness;
- acceptance criteria, non-goals, and evidence obligations;
- workflow snapshot ID/hash and managed tracker-lifecycle policy;
- compatibility-manifest hash, Codex identity binding, model, reasoning effort, requested/effective service tier, selected Work pace, and effective capacity;
- current plan and step status;
- material decisions and assumptions;
- unresolved blockers;
- current branch, HEAD, merge base, diff hash, and Git status;
- required check state and command-definition revision;
- review findings and reviewer-policy revision;
- quota snapshots, active blocking conditions, Studio budget, and quality reserve state;
- tracker handoff/outbox state;
- final evidence requirements.

A mutable eligibility field is never allowed to overwrite the immutable contract snapshot that an attempt was asked to implement.

#### Exact retrievable artifacts

Stored by content hash:

- full command output;
- complete diff or patch;
- screenshots;
- logs;
- test reports;
- App Server raw event payloads where permitted;
- repository documents and generated reports.

#### Disposable context

May be omitted from a resumed prompt:

- acknowledgements;
- repeated status prose;
- duplicated command output;
- superseded exploration notes with no accepted decision;
- UI narration.

### 5.11.3 Typed memory records

Store:

- `requirement`;
- `non_goal`;
- `decision`;
- `assumption`;
- `plan_step`;
- `blocker`;
- `finding`;
- `check_result`;
- `evidence`;
- `recovery_note`.

Each record includes:

- stable ID;
- run ID;
- source event or actor;
- exact text or structured payload;
- created time;
- superseded-by reference;
- content hash.

### 5.11.4 Checkpoint

A checkpoint contains:

- schema version, checkpoint ID, run ID, attempt ID, and sequence boundary;
- issue-contract snapshot ID/hash and latest eligibility snapshot ID/source time;
- workflow snapshot ID/hash;
- Codex identity binding and compatibility-manifest hash;
- conductor model, reasoning effort, requested/effective service tier, Work pace, and effective capacity at capture time;
- exact critical records;
- thread and turn IDs;
- branch, HEAD, merge base, Git status, diff artifact, and diff hash;
- completed and pending plan steps;
- checks, command-definition revision, findings, and reviewer-policy revision;
- blockers, including quota blocking conditions and tracker-sync state;
- usage, Studio budget, and protected-quality state;
- next intended action and safe resume phase;
- artifact hashes.

Checkpoint creation is transactional and idempotent. Artifact bytes are made durable before the database transaction publishes references to them. A checkpoint that cannot resolve every mandatory hash is invalid and cannot be used for automatic resume.

### 5.11.5 Checkpoint triggers

Create a checkpoint:

- after preflight;
- after plan approval by the conductor;
- after a material implementation milestone;
- before compaction;
- after compaction;
- before retry;
- before interruption or pause;
- after validation;
- after review;
- before process shutdown;
- at completion.

### 5.11.6 PreCompact protocol

1. stop starting new model-visible work for the thread;
2. flush normalized events;
3. capture repository state;
4. persist all critical memory records;
5. create the checkpoint;
6. verify every critical record resolves by ID and hash;
7. verify no pending tool result is missing;
8. allow compaction only after the checkpoint passes.

The hook writes durable state; it does not rely on hook stdout to inject context.

### 5.11.7 PostCompact protocol

1. observe the post-compaction event;
2. load the last valid checkpoint;
3. provide an exact context capsule on the next turn or supported injection path;
4. ask the conductor for a structured recall response containing the issue, current goal, constraints, blockers, and next step;
5. compare the response with the checkpoint;
6. rehydrate missing records once;
7. if the audit still fails, interrupt the compacted thread and start a fresh thread from the checkpoint;
8. record the fallback.

### 5.11.8 Restart recovery

At startup:

1. open SQLite with the required durability settings and verify migrations and integrity;
2. load Work pace, compatibility results, Codex identity bindings, active quota waits, tracker outbox operations, and non-terminal runs;
3. reserve claimed issues before the first ordinary Linear candidate poll;
4. reconcile the current issue contract and eligibility separately;
5. inspect workspace and Git state;
6. inspect available Codex threads and authenticated account state;
7. resume only when identity, compatibility manifest, thread, workspace, issue contract, workflow, and checkpoint agree;
8. otherwise start a fresh thread from the last valid checkpoint or block with a typed reason;
9. replay any pending deterministic tracker handoff idempotently;
10. never start two conductors for one issue;
11. never delete a workspace merely because a thread cannot resume.

An externally terminal Linear issue is reconciled as `external_terminal_transition`; it is not converted into verified Studio completion unless the sealed evidence and tracker-handoff records already prove that transition was Studio’s confirmed final operation.

### 5.11.9 Context pack

The conductor receives:

- stable repository instructions;
- exact immutable issue contract and current mutable eligibility snapshot, clearly labelled;
- exact acceptance criteria, non-goals, and managed tracker-lifecycle boundary;
- current plan and blockers;
- selected relevant repository slices;
- current diff, checks, review, quota, and tracker-handoff state;
- allowed tools and policy;
- evidence contract;
- Work pace/delegation ceiling and the rule that optional helpers must provide net value.

Default active-context soft limit: 40,000 input tokens.

When the pack exceeds the limit:

- preserve all critical exact state;
- store verbose artifacts externally;
- retrieve only relevant code/docs;
- never summarize away a requirement, contract field, decision, blocker, finding, or completion obligation;
- start a fresh checkpoint-backed thread when another compaction would make exact recall less reliable.

### 5.11.10 No vector database in MVP

The MVP uses:

- exact IDs;
- content hashes;
- repository paths;
- Git references;
- targeted text and symbol search;
- artifact lookup.

A vector database is not justified for the single-repository MVP.

## 5.12 Quality and evidence system

### 5.12.1 Evidence manifest

Every run has one machine-readable manifest. The final manifest is immutable; a later attempt creates a new manifest.

```json
{
  "schema_version": 1,
  "run_id": "uuid",
  "attempt_id": "uuid",
  "issue": {
    "id": "linear-id",
    "identifier": "SYM-123",
    "contract_snapshot_id": "uuid",
    "contract_hash": "sha256:...",
    "eligibility_snapshot_id": "uuid"
  },
  "workflow": {
    "snapshot_id": "uuid",
    "hash": "sha256:..."
  },
  "execution": {
    "compatibility_manifest_hash": "sha256:...",
    "codex_identity_binding_id": "uuid",
    "model": "gpt-5.6-sol",
    "reasoning_effort": "ultra",
    "requested_service_tier": "standard",
    "effective_service_tier": "default",
    "work_pace": "balanced"
  },
  "repository": {
    "base_commit": "sha",
    "final_commit": "sha",
    "diff_hash": "sha256:..."
  },
  "checks": [],
  "review": {
    "status": "passed",
    "policy_revision": "sha256:...",
    "findings": []
  },
  "delivery": {
    "branch": "sym-123-feature",
    "pr_url": null
  },
  "memory": {
    "final_checkpoint_id": "uuid",
    "preservation_audit": "passed"
  },
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "quality_capacity_preserved": true
  },
  "tracker_handoff": {
    "target_state": "Human Review",
    "status": "confirmed",
    "operation_id": "uuid"
  },
  "sealed_at": "timestamp",
  "completed_at": "timestamp"
}
```

The manifest may contain additional versioned fields, but required fields cannot be omitted or inferred from UI state.

### 5.12.2 Evidence staleness

Implementation evidence is bound to:

- issue-contract hash;
- workflow snapshot and relevant quality-command definitions;
- diff or commit hash;
- reviewer-policy revision;
- compatibility-manifest hash.

When code changes:

- affected check results become stale;
- the review becomes stale;
- the UI visibly returns the run to validation;
- stale evidence cannot satisfy completion.

When a material issue-contract field changes:

- the active attempt checkpoints and stops at a safe boundary;
- prior implementation evidence remains historical but cannot complete the new contract;
- a new attempt begins after reconciliation.

A change only to priority, blocker state, ordinary labels, assignee, URL, or tracker timestamp updates eligibility/scheduling and does not by itself stale correct implementation evidence. A workflow change stales only the obligations or checks whose rendered contract or definition changed; the invalidation decision is deterministic and recorded.

### 5.12.3 Failure classification

Required primary classes:

- `configuration`;
- `compatibility`;
- `protocol`;
- `uncertain_external_outcome`;
- `linear_auth`;
- `linear_unavailable`;
- `tracker_sync`;
- `external_terminal_transition`;
- `issue_contract_changed`;
- `codex_auth`;
- `codex_account_changed`;
- `model_unavailable`;
- `service_tier_unavailable`;
- `rate_limit`;
- `credits_required`;
- `usage_limit_requires_action`;
- `quota_budget`;
- `capacity_limited`;
- `workspace`;
- `sandbox`;
- `approval_required`;
- `input_required`;
- `hook`;
- `agent_process`;
- `agent_stall`;
- `deterministic_check`;
- `review_blocker`;
- `context_preservation`;
- `delivery`;
- `storage`;
- `cancelled`;
- `unknown`.

Every failed or blocked run has exactly one primary class and may have secondary tags. `unknown` is never automatically retried more than once; it first produces a diagnostic and classification review.

### 5.12.4 Circuit breaker

Open a per-issue circuit breaker when:

- the same deterministic failure occurs twice with no material diff;
- two consecutive conductor turns produce no repository or plan progress;
- context preservation fails twice;
- App Server crashes repeatedly;
- the repair-cycle limit is reached.

The circuit breaker:

- stops automatic retries;
- preserves the workspace;
- creates a diagnostic;
- requires an explicit retry or a material input/config change.

## 5.13 Persistence model

Required tables:

```text
studio_runs
studio_attempts
studio_issue_claims
studio_codex_operations
studio_events
studio_checkpoints
studio_memory_records
studio_issue_contracts
studio_issue_eligibility_snapshots
studio_workflow_snapshots
studio_codex_compatibility
studio_codex_identity_bindings
studio_capacity_preferences
studio_change_surface_leases
studio_quota_snapshots
studio_quota_waits
studio_check_results
studio_review_findings
studio_evidence_manifests
studio_tracker_outbox
studio_artifacts
studio_circuit_breakers
```

Every mutable row includes a schema version, created/updated timestamps, and the run or process scope needed to prevent cross-run lookup mistakes.

### 5.13.1 Quota-wait record

`studio_quota_waits` stores:

- wait ID, run ID, attempt ID, issue ID, and checkpoint ID;
- bound `codex_identity_binding_id`;
- one versioned list of blocking conditions, each with source bucket ID/name, source slot, reached classification, reset time, and whether it requires credits or operator action;
- provider reset boundary, computed `wake_at`, and next bounded recheck time;
- auto-resume enabled state;
- wait status: `scheduled`, `checking`, `queued_resume`, `resuming`, `resumed`, `blocked`, `cancelled`, or `superseded`;
- last full quota snapshot ID;
- idempotent resume token and transactional claim time;
- check count, backoff state, and last typed error;
- created, updated, and completed timestamps.

There may be at most one active quota wait per run. A wake-up is claimed transactionally before any conductor lease or Codex turn starts. Duplicate timers, sparse updates, process restarts, and repeated user refreshes converge on the same wait record.

### 5.13.2 Tracker outbox

`studio_tracker_outbox` stores deterministic Linear mutations, including final handoff:

- operation ID and idempotency key;
- issue ID and expected eligibility/contract revision;
- compound handoff step: marker comment or state transition;
- normalized payload, operation marker, and expected reconciliation predicate;
- causation run/attempt/evidence-manifest IDs;
- status: `pending`, `sending`, `confirmed`, `retrying`, `failed`, or `superseded`;
- bounded retry state and last response/error;
- created, sent, confirmed, and updated timestamps.

A run remains `completion_pending_sync` until its terminal/handoff operation is confirmed. Model tools cannot bypass this outbox.

### 5.13.3 Event envelope

```json
{
  "schema_version": 1,
  "event_id": "uuid",
  "sequence": 1842,
  "occurred_at": "2026-07-13T12:34:56.123Z",
  "issue_id": "linear-id",
  "issue_identifier": "SYM-123",
  "run_id": "uuid",
  "attempt_id": "uuid",
  "thread_id": "thr_123",
  "turn_id": "turn_456",
  "type": "quality.check.completed",
  "severity": "info",
  "payload": {},
  "redacted": true
}
```

Rules:

- delivery is at least once;
- event IDs deduplicate;
- sequence is monotonic per run;
- a sequence gap triggers replay;
- persist before LiveView broadcast;
- raw provider payloads are restricted artifacts;
- browser projections use normalized event types;
- an event cannot directly mark a run completed; the completion reducer checks current canonical records and tracker handoff.

### 5.13.4 SQLite durability

The MVP uses one Studio-owned SQLite database and a single logical writer process.

At startup set and verify:

```text
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 5000;
```

Requirements:

- all state transitions that must agree use one immediate transaction;
- retry `SQLITE_BUSY` only with bounded jitter and never by replaying a non-idempotent external side effect;
- run `quick_check` at normal startup and `integrity_check` in release/restore drills;
- use SQLite’s online backup API or a tested equivalent; never copy only the main file while WAL state may be outstanding;
- checkpoint WAL according to a documented policy and before release archives or offline maintenance;
- every migration has forward, rollback-or-forward-recovery, crash-interruption, and backup-restore tests;
- a database error fails closed for new dispatch and completion;
- no secret value is stored in the database or backup.

### 5.13.5 Artifact storage

Layout:

```text
<data-root>/
  studio.sqlite3
  backups/
  artifacts/
    <first-two-hash-chars>/<sha256>
  runs/
    <run-id>/
      latest-checkpoint.json
      evidence.json
```

Every artifact includes:

- SHA-256;
- size;
- MIME type;
- sensitivity;
- created time;
- retention class;
- run and event references.

Writes use a same-filesystem temporary file, bounded streaming hash, flush/fsync, atomic rename, and only then a database transaction that publishes the artifact reference. A failed or partial write is quarantined and never presented as evidence. Backup/restore verifies every retained evidence and checkpoint hash.

## 5.14 Studio interface

### 5.14.0 Code-first design and frontend implementation workflow

The production application is the design canvas. No Figma file is required.

#### 5.14.0.1 Content design and copy standard

The interface SHALL use the shortest text that still makes the state, consequence, and next action clear.

Rules:

- headings and navigation labels use one to four plain-language words;
- buttons start with a clear verb and describe the result;
- one card may have at most one helper sentence in its default state;
- helper text must add information rather than restate the heading or value;
- caveats, source semantics, protocol names, and calculation details belong in `Details`, a tooltip, or diagnostics unless they change the user’s immediate decision;
- empty states use a short heading, one useful sentence, and at most one primary action;
- errors say what happened, what is affected, and what to do next;
- do not use internal terms such as `observed`, `projection`, `idempotent`, `authoritative`, or `policy reserve` in ordinary UI copy;
- do not add a subtitle merely to fill space;
- avoid aspirational product copy inside operational screens;
- retain exact technical terminology in logs, APIs, diagnostics, and this specification.

Preferred user-facing terms:

| Internal or verbose term | Ordinary UI copy |
|---|---|
| Observed usage | Usage |
| Observed tokens | Tokens used |
| Policy reserve | Checks protected |
| Rate-limit exhaustion | Waiting for quota |
| Provider snapshot refresh | Check now |
| Automatic continuation after reset | Resumes automatically |
| Exact provider semantics | Details |

A fresh-context copy review SHALL remove repeated explanations, filler subtitles, duplicate status text, and paragraphs that can be represented by a label, value, timestamp, or action.

Before building route markup, create and maintain these repository-local artifacts:

```text
docs/product/frontend-brief.md
docs/product/ui-state-inventory.md
docs/product/ui-actions.md
docs/product/visual-review.md
test/visual/baselines/
```

`frontend-brief.md` contains:

- one-sentence visual thesis;
- primary user and top five operator questions;
- route hierarchy;
- content priority for each route;
- interaction thesis with two or three purposeful motions;
- density, typography, color, responsive, and accessibility constraints;
- explicit anti-patterns.

`ui-state-inventory.md` lists every route and its required states:

- initial loading;
- ready;
- empty;
- partial data;
- stale;
- reconnecting;
- blocked;
- action pending;
- recoverable error;
- terminal error;
- narrow viewport;
- reduced motion.

`ui-actions.md` contains one row per visible mutation with:

- control label;
- user benefit;
- authoritative command;
- visibility condition;
- enabled condition;
- disabled explanation;
- confirmation requirement;
- pending copy;
- success result;
- failure result;
- idempotency key;
- keyboard behavior;
- automated test.

Build a dev/test-only Component Lab using existing LiveView primitives. It SHALL render the actual production components with the actual presenter structs for every important state. It SHALL NOT ship in production navigation. Do not add a new storybook dependency unless it demonstrably reduces total work.

Typed fixtures are permitted only when they instantiate the same presenter/view-model contracts used by live projections. A component may move from the Component Lab into a product route only after it handles real content lengths, missing fields, errors, and responsive behavior.

The frontend build loop is mandatory:

1. Define or update the brief and state inventory.
2. Implement tokens and the smallest necessary primitives.
3. Compose the real route in LiveView.
4. Connect authoritative data and typed commands.
5. Run the app and inspect it with Playwright.
6. Capture 1440 px, 1024 px, and 390 px screenshots in dark and light themes.
7. Run keyboard, axe, reduced-motion, overflow, and long-content checks.
8. Compare against the visual thesis and route purpose.
9. Remove clutter, redundant cards, duplicate labels, ornamental icons, and weak copy.
10. Record the accepted screenshots and review notes.

UI foundation work begins early, but the entire frontend is never completed before functionality. The first shippable vertical slice is:

```text
normalized Symphony events
→ persisted projection
→ Mission Control active-run card
→ open Run Detail
→ execute one real control
→ observe updated evidence
```

No route may merge as “complete” while it depends on a mock-only data path.

The MVP has exactly five implemented route families:

1. Mission Control
2. Run Detail
3. History
4. Usage
5. Setup & Doctor

The global navigation contains four destinations: Mission Control, History, Usage, and Setup & Doctor. Run Detail is contextual and opens from an active or historical run; it is not a permanent navigation item.

No native board is present. Linear remains the place to create, edit, prioritize, and organize work.

### 5.14.1 Global shell

Desktop:

- 240 px collapsible sidebar;
- product mark and `Symphony Studio`;
- primary navigation;
- fixed top bar with connection and dispatch state; show a usage alert only when limits are low, exhausted, or stale;
- content width optimized for dense operational information;
- no permanent right rail.

Mobile:

- compact header;
- bottom navigation for the four global destinations;
- Run Detail uses a clear back action and preserves the originating list state;
- run actions move into an accessible action sheet;
- tables become cards or horizontal detail scrollers.

Global status copy:

- `Live` — event stream current.
- `Reconnecting` — browser stream disconnected; runner unaffected.
- `Stale` — source data older than configured threshold.
- `Dispatch paused` — no new work; active runs continue.
- `Draining` — no new work; waiting for active runs to finish.
- `Blocked` — startup or policy gate prevents dispatch.

### 5.14.2 Mission Control

Purpose:

- answer “What is happening, what needs attention, and is the system safe to continue?”

Header:

- page title `Mission Control` with no filler subtitle;
- dispatch-state pill;
- accessible `Work pace` segmented control with `Focused`, `Balanced`, and `Accelerated`;
- effective-capacity summary such as `Balanced · 1 of 2 active`, `Accelerated · 1 active · 3 blocked`, or `Waiting for safe change area`;
- `Pause new work`, `Drain and stop`, or `Resume dispatch` according to state;
- overflow menu containing `Reload workflow`, `View workflow`, and `Copy data path` only when each action is valid.

Work pace interaction:

- use radio/segmented-control semantics, not a free-form numeric slider;
- changing the selection persists immediately and affects only new admissions/spawns;
- lowering below current activity shows `Applies as runs finish` and never kills work;
- the effective summary explains the strongest current constraint under `Details`;
- the control never implies a guaranteed completion time or token saving.

Summary cards:

1. `Active runs`
2. `Up next`
3. `Needs attention`
4. `Usage`

The `Usage` card shows the most constraining current provider-reported window, for example `42% left · resets in 1h 18m`. Other valid states are `Waiting for quota`, `No limits reported`, and `Usage unavailable`. It does not invent a permanent window name.

Cards show one primary value and at most one short supporting line. They do not repeat the same status elsewhere unless it changes an available action.

Main layout:

- left two-thirds: active runs and eligible queue;
- right one-third: attention panel; when a run is waiting for quota, show its next check/resume time and actions here;
- lower section: recent verified outcomes.

Active run card:

- Linear identifier and title;
- Studio phase;
- conductor model `GPT-5.6 Sol · Ultra`;
- current plan step;
- elapsed time;
- tokens used;
- active optional-helper count;
- quota wait and next check/resume time when applicable;
- last meaningful event;
- check/review status;
- `View run`;
- `Open in Linear`.

Eligible queue row:

- identifier;
- priority;
- state;
- blocker status;
- admission explanation;
- no start button unless manual dispatch mode is configured.

Attention items are actionable and ordered:

1. security or data risk;
2. context-preservation or issue-contract mismatch;
3. Codex account changed;
4. tracker completion sync failure;
5. waiting for quota or credits required;
6. repeated failure/circuit breaker;
7. credential/config issue;
8. ordinary blocker.

Empty states:

- No eligible work:
  - heading: `No eligible issues`
  - body: `Move an issue to an active Linear state and add the required labels.`
  - action: `Open Linear`
- No active runs:
  - heading: `Nothing is running`
  - body depends on whether work is eligible, paused, blocked, or complete.
- Doctor failure:
  - heading: `Dispatch is blocked`
  - body names the first failing check.
  - action: `Open Doctor`.

### 5.14.3 Run Detail

Purpose:

- make one issue’s complete execution legible without a terminal.

Header:

- issue identifier and title;
- Linear state and Studio phase as separate values;
- branch and commit when available;
- `Open in Linear`;
- `Stop run` only while active;
- `Retry from checkpoint` only when terminal and retryable;
- disabled controls include an inline reason.

Sections:

1. **Objective**
   - immutable issue-contract summary and contract hash/revision;
   - current eligibility state, labels, and blockers;
   - acceptance criteria;
   - workflow revision;
   - a visible `Issue changed` notice when a newer contract forced a new attempt.

2. **Plan**
   - ordered steps;
   - current step;
   - completed, active, skipped, and blocked states;
   - no percentage unless based on step completion.

3. **Live activity**
   - semantic events;
   - current command/tool;
   - concise conductor progress;
   - optional-helper cards with role, task, status, and tokens when reported;
   - expandable raw artifact references.

4. **Changes**
   - files changed;
   - diff stat;
   - current diff hash;
   - full patch artifact.

5. **Checks**
   - command;
   - status;
   - duration;
   - contract/workflow/commit binding;
   - output action.

6. **Review**
   - reviewer profile;
   - findings by severity;
   - contract, policy, and diff binding;
   - stale/current status;
   - repair history.

7. **Memory**
   - latest checkpoint;
   - critical-record count;
   - compaction/rotation timeline;
   - preservation audit;
   - recovery path.

8. **Usage & capacity**
   - tokens used and Studio goal budget;
   - current limiting provider window when reported;
   - reset or next-check time;
   - `Waiting for quota`, `Credits required`, or `Codex account changed` state;
   - automatic-resume status;
   - selected Work pace, effective root/helper capacity, and change-surface wait when applicable;
   - requested/effective Turn speed when supported;
   - `Check now`, `Cancel wait`, `Resume with current account`, and `Use reset credit` only when applicable;
   - technical source details inside `Details`.

9. **Evidence**
   - final commit;
   - PR URL;
   - evidence-manifest ID/hash;
   - tracker handoff state;
   - `Syncing completion` while `completion_pending_sync`;
   - final completion decision only after the handoff is confirmed.

Event timeline language must be specific:

- `Explorer mapped 6 relevant files`
- `Conductor updated lib/foo.ex`
- `Tests failed: 2 failures`
- `Failure Analyst identified stale fixture`
- `Detached review found 1 blocking issue`
- `Repair cycle 1 passed`
- `Evidence manifest sealed`
- `Linear handoff confirmed`

Avoid vague entries such as `Agent is thinking`.

### 5.14.4 History

Purpose:

- inspect past runs and compare outcomes.

Controls:

- search by issue identifier/title;
- filter by status, failure class, model profile, and date;
- sort by newest, longest, highest usage, or most repair cycles;
- `Clear filters`.

Each row shows:

- issue;
- final status;
- started/ended;
- duration;
- attempts;
- repair cycles;
- tokens used;
- final commit;
- evidence status.

The page uses cursor pagination. It does not load all events.

Empty state:

- `No runs yet`
- `Completed and failed runs will appear here.`

### 5.14.5 Usage

Purpose:

- show what Codex currently reports, how Studio is using it, and what can start next.

The primary layout is concise. Technical source semantics stay inside `Details`.

Sections:

1. **Limits & credits**
   - group data by provider bucket/`limitId`;
   - render one card for each currently reported non-null window, without assigning permanent meaning to source slots;
   - use provider `limitName` when available, otherwise a duration label such as `15 min window`, `7 day window`, or `Codex window`;
   - large value such as `42% left`;
   - `Resets in 1h 18m` and exact local reset time when supplied;
   - status: `Available`, `Low`, `Waiting`, `Stale`, or `Unavailable`;
   - accessible progress meter using text as well as color;
   - exact `Credits` value only when `credits.balance` is supplied, or `Unlimited credits` when the provider explicitly reports it;
   - spend-control data in its own card, never mislabeled as credits;
   - `No limits reported` when a successful full read contains no windows; never `Unlimited` unless the provider explicitly says so.

2. **Work pace**
   - the same `Focused`, `Balanced`, and `Accelerated` control as Mission Control;
   - selected pace, effective root limit, active roots, optional-helper limit, active helpers, and protected quality lane;
   - one concise explanation when dependencies, quota, resources, or policy reduce effective capacity;
   - changing pace follows the non-destructive drain semantics in Section 5.7.

3. **Current work**
   - active and waiting runs;
   - tokens used per run;
   - Studio budget;
   - `Checks protected`;
   - admission result;
   - waiting copy such as `SYM-123 checks again in 18m` or `SYM-123 resumes automatically after reset`.

4. **Recent activity**
   - account token-activity summary and daily buckets from `account/usage/read` when supported;
   - clearly separate from subscription-limit and credit cards;
   - no conversion from tokens used to percentage left.

5. **Models & Turn speed**
   - active role-to-model/effort mapping;
   - capability-check status;
   - `Turn speed: Standard` by default;
   - `Standard`/`Fast` control only when the selected model and authenticated account advertise a tested alternative service tier;
   - `Applies next turn` after a change;
   - no disabled Fast placeholder and no claim that Fast saves tokens.

6. **Account & reset credits**
   - authentication mode and safe account identity label;
   - plan type when reported;
   - source freshness such as `Updated 2m ago`;
   - `Check now`;
   - earned-reset count and expiry details when reported;
   - `Use reset credit` with concise confirmation naming affected waits;
   - last redemption result;
   - collapsed `Details` for raw bucket IDs, source slots, schema/version, and unavailable fields.

Waiting-state behavior:

- countdowns are computed locally and announced no more than once per minute;
- provider refresh occurs on sparse update, scheduled wake-up, `Check now`, successful reset redemption, reconnect, and bounded background cadence;
- a successful full read replaces removed windows immediately;
- when every blocking condition clears, waiting runs move to `Resuming` and then to their active phase;
- a failed recheck stays `Waiting` and shows the next check time without an error wall;
- an account mismatch never auto-resumes.

No editable model picker is required in the MVP. The repository-owned role config remains the model source of truth.

### 5.14.6 Setup & Doctor

Purpose:

- prevent expensive, unsafe, or irreproducible failures before dispatch.

Doctor checks:

- supported OS and release package;
- Elixir/Erlang/mise versions;
- Git;
- SQLite version, required PRAGMAs, integrity, backup/restore drill, and storage permissions;
- `WORKFLOW.md` readability, schema, last-known-good revision, and managed tracker-lifecycle policy;
- Linear API key presence and connectivity;
- Linear project, state mapping, required labels, blocker queries, comments, and deterministic mutation capability;
- workspace root and cleanup safety;
- repository bootstrap hook;
- Codex executable checksum/version versus the pinned compatibility record;
- generated App Server schema-bundle hash;
- stdout/stderr JSONL framing, initialize order, request correlation, overload handling, frame-size limit, and child cleanup;
- Codex authentication and safe identity binding;
- required App Server method matrix;
- quota response shapes, dynamic bucket replacement, credits, and reset-credit capability when available;
- model and reasoning-effort availability;
- service-tier discovery and Fast eligibility when available;
- Work pace root capacity, MultiAgentV2 direct-child depth, and optional-helper cap enforcement;
- approval/input-request behavior;
- sandbox and network policy;
- quality commands and detached review;
- UI endpoint;
- disk space;
- last live end-to-end result.

Status types:

- Pass
- Warning
- Fail
- Not run

Each check includes:

- what was tested;
- result;
- why it matters;
- exact remediation;
- `Run again` when safe;
- evidence/manifest reference under `Details`.

Primary button:

- `Run all checks`

Secondary actions:

- `Copy diagnostic report`
- `Reload workflow`
- `View workflow`
- `Copy workflow path`
- `Copy data path`
- `View judge guide` in showcase/release mode.

Doctor output is redacted and suitable for issue reports. A red or missing required compatibility result keeps managed dispatch off.

## 5.15 Visual design system

### 5.15.1 Design character

The product should feel:

- calm;
- technical;
- precise;
- trustworthy;
- modern without looking decorative;
- information-dense without becoming cramped.

Use a graphite-neutral foundation with one steel-blue primary accent and semantic status colors. Every color must meet WCAG contrast requirements.

The interface is an operational workspace, not a marketing page. Default to plain layout, lists, dividers, and aligned columns. Use a card only when the card itself is an interaction, grouping boundary, or movable unit. Avoid a mosaic of decorative dashboard cards.

Initial token direction:

| Token | Dark | Light |
|---|---:|---:|
| `--bg` | `#0B0D10` | `#F7F8FA` |
| `--surface-1` | `#11151A` | `#FFFFFF` |
| `--surface-2` | `#171C22` | `#F0F3F7` |
| `--border` | `#252C35` | `#D9DFE7` |
| `--text` | `#F5F7FA` | `#14181F` |
| `--text-muted` | `#98A3B3` | `#657084` |
| `--accent` | `#7AA2FF` | `#315FD6` |
| `--success` | `#45C48A` | `#167A50` |
| `--warning` | `#E8B35A` | `#9A6200` |
| `--danger` | `#F06A6A` | `#B63A3A` |
| `--info` | `#6CB6E8` | `#1F6F9F` |

These are starting tokens, not permission to bypass rendered contrast testing. Any change to them updates the visual baseline and contrast report in the same commit. Status always includes text or an icon in addition to color.

### 5.15.2 Typography

Use a system sans-serif stack for interface text and a locally available monospace stack for identifiers, commands, hashes, and code.

Hierarchy:

- page title: 28–32 px;
- section title: 18–20 px;
- card title: 14–16 px semibold;
- body: 14–16 px;
- metadata: 12–13 px;
- commands/code: 13–14 px monospace.

Do not use all-caps paragraphs. Use uppercase only for short labels when contrast and letter spacing remain readable.

### 5.15.3 Spacing and layout

Use a 4 px base grid.

Common spacing:

- 4 px micro-gap;
- 8 px related controls;
- 12 px dense card gap;
- 16 px standard component padding;
- 24 px section gap;
- 32 px page rhythm.

Use consistent radii:

- 6 px controls;
- 10 px cards;
- full radius for status pills.

### 5.15.4 Motion

Motion communicates a real transition:

- 160–220 ms for hover, expand, status, and list movement;
- 240–320 ms for page-level panel transitions;
- transform and opacity only where practical;
- active-run pulse no faster than 2 seconds and disabled under reduced motion;
- no confetti;
- no looping decorative background;
- no fake typewriter animation;
- no progress animation without actual state change.

Honor `prefers-reduced-motion` completely.

### 5.15.5 Icons

Use one local icon set.

Every icon-only control requires:

- accessible label;
- tooltip on hover/focus;
- minimum 44 px touch target;
- visible focus.

Do not mix icon families.

### 5.15.6 Design quality gates

A route passes visual review only when:

- its purpose is clear from headings, labels, and state without reading body copy;
- one region is visually dominant and competing chrome has been removed;
- cards are used only where their boundary improves interaction or comprehension;
- primary and secondary actions are visually unambiguous;
- copy is operational and specific rather than aspirational or generic;
- real issue titles, paths, hashes, logs, and empty states fit without breaking hierarchy;
- loading, stale, reconnecting, blocked, and error states feel designed rather than appended;
- desktop and mobile preserve the same decision value;
- motion explains causality and disappears cleanly under reduced motion;
- dark and light themes both pass contrast and visual-regression checks;
- the Reviewer has inspected rendered screenshots and at least one live browser flow;
- no required information is hidden behind hover alone.

Reject these outcomes:

- generic SaaS card grids;
- a sidebar plus dozens of undifferentiated panels;
- excessive pills, badges, or ornamental icons;
- purple-gradient defaults;
- fake terminal animations;
- placeholder lorem ipsum or invented production metrics;
- controls whose importance is communicated only by color;
- visual polish that masks incomplete functionality.

## 5.16 Interaction rules

- Destructive actions require confirmation with exact impact.
- `Pause new work` does not stop active runs.
- `Drain and stop` waits for active runs and then stops polling.
- `Stop run` interrupts the active turn, checkpoints, and leaves the workspace.
- `Retry from checkpoint` creates a new attempt; it does not erase history.
- `Reload workflow` validates first and keeps the last known good config on failure.
- `Use one reset credit` is idempotent and user initiated.
- A button is not rendered when the user cannot perform the action in the MVP’s trust mode.
- Disabled buttons state why they are disabled.
- Toasts acknowledge completion; durable errors remain inline until resolved.
- Browser refresh never loses a server-side action.
- Double-click and repeated-submit protection is required for every mutation.

## 5.17 Accessibility

Meet WCAG 2.2 AA.

Required:

- complete keyboard navigation;
- visible focus;
- semantic landmarks and headings;
- properly associated labels and descriptions;
- live-region announcements for meaningful status changes;
- no color-only meaning;
- reduced-motion support;
- 200% zoom/reflow;
- 44 px touch targets;
- accessible dialogs;
- table/card alternatives on mobile;
- automated axe checks;
- manual keyboard and screen-reader QA for all five routes.

## 5.18 Security and trust posture

The MVP is a trusted, single-user local tool.

### 5.18.1 Network binding

Default bind: `127.0.0.1`.

If configured to bind to a non-loopback address:

- startup shows a blocking warning;
- the user must explicitly enable remote exposure;
- documentation requires a trusted reverse proxy and authentication;
- this mode is not part of the Build Week supported reference path.

### 5.18.2 Local operator session

Release 1 has no account system, but the mutation-capable local UI is not anonymous.

- setup creates a random instance signing secret in an owner-readable `0600` secret file outside SQLite;
- startup creates a short-lived, single-use pairing code shown only in the terminal;
- the first browser session enters the code over loopback and receives a signed, `HttpOnly`, `SameSite=Strict` session cookie;
- pairing-code hashes are memory-only or short-lived, rate-limited records; the raw code never enters URLs, logs, SQLite, diagnostics, or screenshots;
- mutation routes require the paired session plus CSRF and Origin checks;
- reads containing issue, code, log, usage, or evidence data also require the paired session;
- validate the `Host` header against configured loopback hosts to reduce DNS-rebinding risk;
- session revocation and `./bin/studio pair --reset` invalidate prior cookies;
- showcase mode uses a separate read-only session capability and cannot call mutation handlers;
- non-loopback binding is not made safe merely by this local pairing mechanism and remains outside the supported MVP path.

### 5.18.3 Secrets

- Linear keys and OpenAI credentials remain in the Studio process environment, a `0600` local secret file, or Codex-managed auth storage as appropriate.
- Secrets are never stored in SQLite, content-addressed artifacts, evidence manifests, or release archives.
- App Server and hook child processes receive an explicit environment allowlist; they do not inherit `LINEAR_API_KEY`, pairing/instance secrets, or unrelated Studio credentials by default.
- Linear access for model work is mediated by Studio tools; the raw Linear credential is not exposed to shell commands or prompts.
- A required tool receives only the narrow secret reference/value needed for that operation and only for its lifetime.
- Redaction runs before persistence and broadcast and is backed by secret-canary tests.
- Diagnostic exports contain secret references, not values.
- Backups exclude instance/auth secret files unless a separately documented encrypted secret-backup flow is used.
- Screenshots, demo recordings, and showcase fixtures are scanned.

### 5.18.4 Workspace

- issue identifiers are sanitized;
- workspace paths must remain under the configured root;
- symlink escape is rejected;
- sandbox writable roots are explicit;
- network access is off by default and enabled only when workflow policy requires it;
- the host Docker socket is never mounted;
- cleanup never follows symlinks outside the workspace;
- a failed hook cannot trigger destructive reset of a reused workspace.

### 5.18.5 Untrusted content

Linear descriptions, repository files, logs, and external docs are untrusted data.

They cannot override:

- system policy;
- sandbox;
- approval policy;
- quota policy;
- completion gates;
- secret handling;
- authorization.

### 5.18.6 Web security

- CSRF protection;
- strict CSP;
- output escaping;
- sanitized Markdown;
- no raw HTML from logs or agent messages;
- secure response headers;
- bounded artifact downloads;
- no directory browsing;
- no secret-bearing URL parameters.


### 5.18.7 Approval and input requests

The managed reference path is non-interactive unless Studio explicitly presents an authorized operator action.

Rules:

- use an explicit, tested approval and sandbox policy; never inherit an unknown local default;
- allow deterministic operations only when policy already authorizes their exact risk class and workspace scope;
- never auto-approve sandbox escape, destructive host access, unrestricted network, secret disclosure, production action, or an unknown tool;
- persist unresolved App Server approval, MCP elicitation, and user-input requests as typed `approval_required` or `input_required` blockers;
- checkpoint before releasing the conductor lease;
- show one concise action request with the requested operation, risk, affected resource, and safe alternatives;
- do not answer an arbitrary user-input request with a generic fabricated response merely to keep the run moving;
- deduplicate requests by App Server request/call ID and resolve each at most once;
- cancel or expire the request safely when the run, issue contract, account, or workflow changes;
- after approval or input, revalidate issue eligibility, identity, Work pace, workspace, and budget before continuing.

### 5.18.8 Supported-platform claims

Release documentation SHALL list only platforms that pass the clean-machine installation and live smoke test.

At least one reference platform is required. Additional platforms are marked:

- `supported` only after the full reference path passes;
- `experimental` after partial testing with known limitations;
- `not supported` when unverified.

Do not claim native Windows support merely because the browser interface renders on Windows. WSL or container-based support is a separate tested path.

## 5.19 Failure behavior and failsafes

### Linear unavailable

- keep safe active local work running only until the next tracker decision is required;
- pause new dispatch and final completion sync;
- mark eligibility data stale;
- retry with bounded backoff and jitter;
- never infer terminal state or confirm completion.

### Linear authentication failure

- block new dispatch and tracker outbox sends;
- preserve active workspace, checkpoint, and pending outbox entries;
- show exact remediation;
- do not retry aggressively.

### Issue contract changed

- detect material prompt-contract changes independently from eligibility changes;
- checkpoint and stop the current attempt at a safe boundary;
- mark prior evidence historical/stale for the new contract;
- create a new attempt only after the new contract and current eligibility are reconciled;
- priority, blocker, assignee, and ordinary status changes do not trigger this path unless they change rendered obligations.

### External terminal transition

- interrupt active model work safely;
- preserve evidence and workspace;
- classify `external_terminal_transition`;
- do not display verified completion unless Studio already has a sealed manifest and confirmed matching tracker handoff;
- require explicit reconciliation when a human terminal transition conflicts with active work.

### Tracker completion sync failure

- keep the run in `completion_pending_sync`;
- never show `Completed`;
- retry the idempotent outbox operation with bounded backoff;
- surface the last error and `Retry sync` when operator action is useful;
- never ask the model to repeat the mutation.

### Codex authentication failure

- checkpoint;
- stop new model turns;
- allow local evidence viewing;
- show `Re-authenticate Codex`;
- resume only after account and compatibility checks pass.

### Codex account changed

- cancel automatic resume for waits bound to the prior identity;
- show `Codex account changed`;
- permit `Resume with current account` only as a new attempt/fresh thread from the validated checkpoint;
- keep prior usage attribution attached to the original binding.

### Required model or effort unavailable

- block the reference profile;
- show the missing model/effort and compatibility-manifest result;
- never silently select another model or lower reasoning effort.

### Fast/service tier unavailable

- preserve completed work;
- switch future turns to Standard only at a safe turn boundary;
- emit one warning and refresh capability discovery;
- do not fail the MVP merely because Fast is absent.

### App Server protocol or compatibility failure

- stop managed dispatch for the affected installed version;
- terminate the child process group safely;
- preserve bounded stderr and request metadata;
- require a regenerated schema and green conformance result before automatic work resumes;
- never guess a renamed field, retry a non-idempotent request, or parse contaminated stdout.

### App Server overload

- treat JSON-RPC `-32001` as transient;
- back off with jitter;
- retry reads and other idempotent operations only;
- reconcile before retrying a request that may have started a turn or external mutation.

### Uncertain App Server outcome

- mark the prepared operation `uncertain`;
- stop new turns for that run;
- inspect supported thread/status/read/list surfaces, normalized events, workspace/Git changes, and the operation ledger;
- reconcile to `acknowledged`, `not_started`, or `side_effect_observed` only with evidence;
- retry only after `not_started` is proven;
- otherwise checkpoint and block rather than creating a second thread or turn.

### App Server crash

- persist the last event sequence;
- restart within bounded policy;
- resume the thread only when identity, contract, workspace, and checkpoint agree;
- otherwise start fresh from the checkpoint;
- open a circuit breaker after repeated crashes.

### Approval or user input required

- persist the request and checkpoint;
- release model capacity;
- block with one actionable request;
- never fabricate consent or an answer;
- resume only after the request is resolved once and all admission gates still pass.

### Agent stall

- use event heartbeat and configured stall timeout;
- checkpoint if possible;
- interrupt the turn;
- classify `agent_stall`;
- retry once with the checkpoint;
- block after repeated identical stalls.

### Rate limit

- stop new turns for the affected Codex identity;
- finish safe local checks and checkpoint affected runs;
- persist every known blocking condition and the identity binding;
- compute the next wake from the latest known reset, or use bounded rechecks when any blocking condition has no reset;
- show `Waiting for quota`, `Credits required`, or `Action required` as appropriate;
- recheck rather than blindly launching a turn;
- resume one run at a time only after every current gate passes;
- rebuild waits before ordinary dispatch after restart;
- avoid retry storms and duplicate turns;
- keep reset-credit redemption manual;
- preserve review/repair priority.

### Quota budget

- stop model work;
- preserve deterministic outputs;
- block with a continuation recommendation;
- require explicit budget change;
- do not resume merely because a provider window reset.

### Capacity limited

- keep the run queued with a precise reason: Work pace, dependency, change-surface conflict, helper cap, quality lane, local resources, or another lease;
- do not label expected queueing as failure;
- re-evaluate on the relevant state change rather than busy-polling.

### Deterministic check failure

- store full output;
- invoke the Failure Analyst once when it adds value;
- return diagnosis to the conductor;
- count a repair cycle;
- block after repeated identical failure.

### Review failure

- store findings;
- return blocking findings;
- invalidate prior review after relevant code/contract/policy change;
- block when the repair limit is reached.

### Context preservation failure

- never continue by guessing;
- start a fresh thread from the last valid checkpoint;
- block if the fresh-thread audit fails.

### SQLite unavailable or corrupt

- stop new dispatch, automatic resume, completion, and tracker mutations;
- keep the core runner disabled in Studio mode rather than losing evidence;
- copy the database/WAL state to quarantine through a tested recovery path;
- expose recovery instructions;
- never silently recreate and lose history.

### Disk pressure

- warn at the configured threshold;
- stop new dispatch before critically low space;
- retain critical checkpoints and evidence;
- offer safe artifact cleanup by retention class.

### Browser disconnect

- runner continues;
- UI reconnects and replays missing sequences;
- no state is inferred from stale client memory.

### Process shutdown

- enter drain when graceful;
- checkpoint active runs;
- flush events, SQLite transactions, and artifact writes;
- terminate App Server child groups;
- preserve workspaces;
- reconcile identity, waits, contracts, and outbox operations on restart.

## 5.20 API and observability

Keep existing `/api/v1/*` compatibility for the upstream runner.

Add local Studio endpoints under `/api/studio/v1`:

```text
GET   /overview
GET   /runs
GET   /runs/:id
GET   /runs/:id/events
GET   /runs/:id/evidence
GET   /runs/:id/issue-contract
GET   /runs/:id/checkpoints
GET   /usage
POST  /usage/refresh
GET   /capacity
PATCH /capacity/work-pace
GET   /models
GET   /compatibility
PATCH /turn-speed
GET   /doctor
POST  /doctor/run
POST  /dispatch/pause
POST  /dispatch/resume
POST  /dispatch/drain
POST  /runs/:id/stop
POST  /runs/:id/retry
POST  /runs/:id/quota-wait/cancel
POST  /runs/:id/resume-with-current-account
POST  /runs/:id/tracker-sync/retry
POST  /workflow/reload
POST  /usage/reset-credits/:credit_id/consume
```

Rules:

- browser mutations require authenticated local session and CSRF protection;
- every non-idempotent mutation requires a client-generated idempotency key or uses a server-issued operation ID;
- repeated identical requests return the original operation/result rather than duplicating work;
- mutable resources expose revision/ETag data and reject stale writes with a typed conflict;
- Work pace and Turn speed responses distinguish selected/requested values from effective values and constraints;
- usage responses expose a versioned dynamic bucket collection, credits, spend control, source freshness, and stale state; they do not bake in a fixed window duration;
- issue-contract and evidence responses contain hashes and snapshot IDs;
- completion responses distinguish `completion_pending_sync` from `completed`;
- responses include schema version and source timestamp;
- errors use stable codes, retryability, and concise remediation;
- large artifacts are separate bounded downloads;
- no secret, raw credential, private reasoning, or unrestricted provider payload appears.

API mutation support outside the local UI is optional in the MVP, but the internal command handlers use the same typed contracts and idempotency rules.

Structured logs include:

- run, attempt, issue, operation, and correlation IDs;
- event type and failure class;
- model role and effective service tier;
- selected/effective Work pace and capacity reason when changed;
- token usage and provider bucket IDs when reported;
- durations and retry counts;
- no prompt body, issue description, secret, or raw credential by default.

Health endpoints:

- `/health/live` — process is alive;
- `/health/ready` — required database, workflow, compatibility, identity, tracker, and storage gates pass for managed dispatch;
- `/health/dependencies` — redacted per-dependency status and freshness.

## 5.21 Performance objectives

Reference scale:

- 100 visible Linear issues;
- 10 retained active/retry entries;
- 50,000 stored events;
- 1,000 historical runs.

Targets on a documented developer laptop:

- p95 semantic event to visible UI under 500 ms;
- Mission Control usable within 1.5 seconds after server response begins;
- Run Detail initial render under 2 seconds for a 10,000-event run through pagination/virtualization;
- no full-page reload for live updates;
- stable browser memory during a two-hour active session;
- no unbounded ETS, process mailbox, DB connection, or artifact growth;
- SQLite projection rebuild documented and tested.

## 5.22 Test strategy

### 5.22.1 Unit tests

Cover:

- Studio config parsing, validation, last-known-good reload, and scope fences;
- local pairing-code generation, expiry, single use, session revocation, and cookie policy;
- generated App Server schema loading and required/optional method matrix;
- JSONL framing, request correlation, timeout, frame-size, stderr isolation, and overload classification;
- model/effort/profile validation;
- service-tier discovery, exact tier-ID mapping, Standard fallback, and next-turn application;
- Work pace selection, persistence, effective-cap calculation, live decrease/drain behavior, quality-lane exclusion, and change-surface overlap;
- immutable issue-contract hashing and mutable eligibility normalization;
- contract-change versus priority/blocker-only change classification;
- managed tracker mutation authorization and outbox reduction;
- full quota-snapshot replacement, sparse patch merging, bucket removal, remaining-percentage clamping, credits, spend control, and source freshness;
- Codex identity binding and account-change detection;
- protected quality-capacity arithmetic;
- multi-condition durable-wait scheduling, latest reset selection, bounded unknown-reset polling, and idempotent resume;
- reset-credit idempotency;
- durable issue-claim state transitions, unique active claim, takeover reconciliation, and event normalization/sequence deduplication;
- prepared/sent/acknowledged/uncertain App Server operation reduction;
- memory-record lifecycle and checkpoint validation;
- evidence binding/staleness and completion reduction;
- failure classification and circuit breaker;
- SQLite transaction/retry helpers;
- redaction, artifact hashing, and UI presenters.

### 5.22.2 Property/model tests

Prove or aggressively test:

- one issue never has two durable active claims, two active conductors, or two turns created from one wake-up/uncertain request;
- root admission never exceeds effective Work pace, workflow, resource, or quota ceilings;
- optional helpers never exceed the per-run/global cap and never spawn recursively beyond depth one;
- two conflicting root writers cannot hold overlapping change-surface leases;
- lowering Work pace never kills an active run and eventually converges to the new ceiling;
- required review/check work cannot be crowded out by optional helpers;
- blocked or ineligible work never dispatches;
- an unpaired browser or invalid Host/Origin cannot read project data or mutate state;
- a stale issue contract, workflow, check, or review cannot complete a run;
- priority/blocker-only changes do not incorrectly invalidate code evidence;
- a model-originated Linear lifecycle mutation is denied;
- `completed` is unreachable before a confirmed tracker handoff;
- an external terminal transition cannot manufacture verified completion;
- a successful full quota read removes absent windows while a sparse update does not;
- a wait never wakes before the latest known blocking reset;
- a run cannot auto-resume under a different Codex identity;
- required reserve cannot be allocated twice;
- duplicate/out-of-order events and tracker deliveries converge on one projection;
- retries remain bounded;
- a workspace path never escapes its root;
- every mandatory context record survives checkpoint serialization/reload;
- secret-like fixtures are redacted before persistence or broadcast.

### 5.22.3 Contract tests

Use generated schemas and deterministic fixtures for:

- App Server initialize ordering, required methods, request/response IDs, unknown fields, malformed JSON, duplicate responses, stdout contamination, and uncertain side-effect reconciliation;
- fragmented frames, frames larger than one MiB, configured maximum-frame rejection, bounded stderr, process-group cancellation, and JSON-RPC `-32001` overload;
- `account/read`, account changes, logout, ChatGPT versus API-key auth behavior;
- dynamic `rateLimitsByLimitId`, legacy fallback, zero/one/many windows, removed windows, reset changes, reached classifications, credits, spend control, and sparse updates;
- `account/usage/read` unsupported/auth-restricted states;
- model/effort/service-tier discovery and a rejected/disappearing Fast tier;
- root/direct-child capacity and the pinned MultiAgentV2 cap mapping;
- thread/turn/item lifecycle, detached review, interruption, optional compaction, approvals, MCP elicitations, and user-input requests;
- reset-credit redemption outcomes;
- Linear candidate, blocker, comment, state, issue-change, optimistic-conflict, and idempotent outbox mutations;
- denial of raw model tracker-lifecycle mutation.

### 5.22.4 Integration tests

Cover:

- SQLite required PRAGMAs, WAL contention, migrations, crash/reopen, online backup, integrity check, and restore;
- atomic artifact write and database publication;
- persist-before-broadcast and projection rebuild;
- process restart, durable claim restoration/takeover, and run reconciliation;
- fake Linear plus fake App Server full lifecycle;
- issue contract changing during exploration, implementation, validation, and quota wait;
- priority/blocker-only issue updates;
- managed `completion_pending_sync` outbox retry and confirmation;
- external terminal transition before and after evidence sealing;
- workflow reload and selective evidence invalidation;
- active turn interruption and unresolved approval/input request;
- checkpoint-to-fresh-thread recovery;
- Work pace changes with several eligible/dependency-blocked issues;
- parallel exploration followed by conflicting/non-conflicting change-surface acquisition, expiry, and resume;
- quota stop, multiple blocking buckets, durable wait, restart reconciliation, and automatic resume;
- reset time moving forward or a bucket disappearing while waiting;
- Codex account switching while waiting;
- issue cancellation or ineligibility while waiting;
- exactly-once wake-up, uncertain `thread/start`/`turn/start`, and no duplicate turn;
- Standard/Fast next-turn behavior when a tested tier is present;
- repair loop, artifact download, and LiveView reconnect/replay.

### 5.22.5 Browser end-to-end tests

Use LiveView tests for server behavior and Playwright for critical browser behavior.

Required flows:

1. First-run local pairing, session revocation, and rejected unpaired access.
2. Doctor failure to remediation and readiness-manifest evidence.
3. Mission Control live update.
4. Change Work pace, show effective capacity, block overlapping writers, and lower pace while work is active.
5. Open Run Detail and inspect contract, eligibility, checks, review, memory, usage, and tracker handoff.
6. Pause, drain, and resume semantics.
7. Stop a run with confirmation.
8. Retry from checkpoint.
9. Dynamic Usage cards add and remove provider windows from full snapshots.
10. Exact credits and spend control render separately; missing values are not invented.
11. `No limits reported` is distinct from `Unlimited`.
12. Usage caveats remain inside `Details` with no repeated long disclaimer.
13. Rate-limit stop enters `Waiting for quota`, survives restart, and resumes automatically with a fake clock.
14. A wait with several blocks uses the latest reset and resumes one run at a time.
15. `Check now` is single-flight and `Cancel wait` prevents later resume.
16. Manual reset credit prevents double submit and returns through the normal resume path.
17. Codex account change blocks auto-resume and offers `Resume with current account`.
18. Fast control is absent when unsupported and applies next turn when a fixture advertises it.
19. Material issue change creates a new attempt and visibly stales prior evidence.
20. Completion remains `Syncing completion` until Linear confirmation.
21. An external terminal transition is not shown as verified completion.
22. Approval/input request becomes one actionable blocker and never fabricates consent.
23. Mobile navigation.
24. Keyboard-only navigation and screen-reader announcements.
25. Reduced motion.
26. Browser reconnect with missed-event replay.
27. Recorded showcase mode.
### 5.22.6 Live smoke tests

Every commit uses fakes.

A real Codex + disposable Linear end-to-end test runs:

- before the release candidate;
- after meaningful App Server integration changes;
- after a Codex version/schema change;
- after upstream synchronization;
- before recording the final demo.

It must:

- verify the installed version and compatibility-manifest hash;
- create or use an isolated test issue;
- claim it through managed admission;
- make a known repository change;
- run checks;
- perform detached review;
- produce and seal evidence;
- confirm the deterministic Linear handoff;
- clean up safely.

A separate live capability probe verifies quota/service-tier/account fields without deliberately exhausting quota. Do not burn live quota on every small commit.

### 5.22.7 Security tests

- path traversal and symlink escape;
- XSS through issue, log, command, and agent content;
- local pairing, expiry, revocation, brute-force rate limiting, Host/Origin validation, CSRF, and stale/idempotency mutation handling;
- secret redaction in events, diagnostics, screenshots, artifacts, and backups;
- artifact path/size/MIME authorization;
- malicious prompt instructions, GraphQL alias/fragment/multi-operation bypasses, and raw tracker mutation attempts;
- non-loopback startup warning;
- sandbox writable-root and network-policy enforcement;
- approval/input request spoofing, duplicate resolution, and unsafe autoapproval rejection;
- account-binding confusion and cross-account auto-resume prevention;
- protocol stdout injection and oversized-frame denial;
- child-environment allowlisting and no raw credentials in SQLite, artifacts, backups, or release archives.

### 5.22.8 Visual and accessibility QA

Capture stable snapshots for:

- all five routes;
- light and dark themes;
- desktop, tablet, and mobile;
- pass, warning, fail, blocked, empty, loading, reconnecting, stale, quota-waiting, account-changed, completion-syncing, and contract-changed states;
- all three Work pace selections and constrained effective capacity;
- reduced motion.

Manual review:

- keyboard and screen reader;
- 200% zoom and reflow;
- contrast and touch targets;
- long issue titles, paths, hashes, bucket names, and error details;
- no-data states;
- ten simultaneous run cards;
- every action label, confirmation, pending state, and disabled reason;
- fresh-context copy pass for unnecessary explanation.

### 5.22.9 Release soak and recovery drill

Release 1.1 requires:

- two hours with active event flow;
- repeated LiveView reconnects;
- at least one app restart;
- at least one App Server crash/restart;
- at least one simulated multi-bucket quota wait that survives restart and resumes exactly once;
- one Codex account-change simulation while waiting;
- one Work pace decrease while multiple roots/helpers are active;
- one overlapping change-surface wait and safe resume;
- one issue-contract change and one priority-only change;
- one tracker handoff retry;
- one workflow reload;
- one online backup and clean restore;
- no memory leak, duplicate run/turn, lost event, stale completion, browser crash, orphan App Server, or SQLite corruption.

## 5.23 MVP release acceptance criteria

Release 1 is complete only when all are true:

1. The repository is a valid fork and retains upstream licensing and attribution.
2. Untouched upstream tests and Studio conformance tests pass at the recorded upstream SHA.
3. Studio can be disabled and the core runner still works.
4. Release 0 produces a green readiness manifest for the exact Codex version, generated schema hash, platform, and upstream revision.
5. App Server transport, overload, timeout, frame-boundary, process-cleanup, and required-method conformance pass.
6. Doctor validates Codex, Linear, workspace, models, sandbox, checks, storage, database recovery, and UI.
7. The reference profile visibly uses GPT-5.6 Sol with Ultra reasoning effort.
8. Work pace has Focused, Balanced, and Accelerated settings; selected and effective capacity are distinct and lowering pace drains without killing work.
9. Supporting agents are direct, read-only, bounded by the tested pinned-version cap, and used only when their expected value exceeds delegation overhead.
10. Required checks and review retain protected capacity regardless of Work pace.
11. Fast is hidden when unsupported; when a fixture advertises it, Studio sends the exact service-tier ID at the next turn boundary and safely falls back to Standard.
12. No non-Codex coding-agent provider code exists.
13. An existing eligible Linear issue completes the full reference lifecycle.
14. Each attempt binds to an immutable issue-contract snapshot and a separate mutable eligibility snapshot.
15. A material issue change creates a new attempt and prevents prior evidence from completing the new contract; a priority/blocker-only change does not falsely stale it.
16. Model tools cannot directly change the managed Linear lifecycle.
17. A run remains `completion_pending_sync` until the deterministic tracker outbox confirms handoff.
18. An external terminal Linear transition cannot manufacture verified completion.
19. Usage renders a dynamic provider bucket/window collection and removes absent windows after a successful full read; no fixed five-hour assumption exists.
20. Exact credits render only from the provider credit field; spend control and token activity remain separate and missing values are not invented.
21. API-key compatibility mode does not claim ChatGPT subscription quota, reset credits, or Fast capability it cannot observe.
22. Quota admission protects review and repair capacity.
23. Rate-limit exhaustion records every blocking condition, waits through the latest known reset or bounded recheck path, survives restart, and resumes exactly once.
24. A quota wait is bound to the Codex identity that incurred it and cannot auto-resume after an account change.
25. A block with no reset and required credits/operator action becomes a typed blocker rather than polling forever.
26. Earned reset redemption is manual and idempotent.
27. Run events persist before broadcast and replay after reconnect.
28. Restart/recovery cannot duplicate dispatch, a conductor, a wake-up turn, or a tracker mutation.
29. SQLite durability settings, crash recovery, online backup, integrity check, and clean restore pass.
30. Critical memory survives compaction/rotation and fresh-thread recovery tests.
31. Every completed run has current deterministic check evidence bound to the current contract/workflow/commit.
32. Every completed run has current independent review evidence.
33. Stale evidence cannot satisfy completion.
34. Repeated deterministic or protocol failure opens the correct circuit breaker without identical retry storms.
35. Approval and input requests fail closed, persist, deduplicate, and never fabricate consent.
36. All five route families are complete, responsive, accessible, and powered by canonical state.
37. Default UI copy is concise and progressively disclosed; no repeated quota disclaimer, fake precision, or unnecessary subtitle appears in the primary layout.
38. Every visible control works and has correct visibility, loading, success, disabled, conflict, and error behavior.
39. Private chain-of-thought and secrets are absent from child environments unless explicitly required, and from database, logs, UI, fixtures, diagnostics, backups, and release artifacts.
40. The clean-machine judge path, recorded showcase, Build Week evidence, and primary `/feedback` Session ID are complete.
41. No known P0/P1 defect or unwaived release-impacting P2 defect remains, and no required test is flaky.
42. No Release 2+ feature is required to install, understand, or operate the MVP.
43. All source, log, usage, evidence, and mutation routes require a valid paired local-operator session; showcase access is read-only.
44. Parallel root exploration may overlap, but conflicting writers are serialized by durable change-surface leases and resume without duplicate edits.
45. A durable unique issue claim is committed before worker/model start, restored before polling, and uncertain App Server starts cannot be blindly duplicated.
46. The GitHub Release marked `Latest` always identifies the last fully published stable stage; unfinished next-stage work remains on a release branch, and any gated-but-unpublished `main` merge is visibly marked `release_pending_publication`.
47. Every completed stage pushes its release branch, opens one release pull request, and auto-merges only after required checks, current independent-review evidence, exact-head validation, and repository rules pass without bypass.
48. Post-merge automation verifies the merged tree, builds from the merged `main` commit, publishes a new immutable tag and verified GitHub Release assets, and never moves or reuses a stable tag.
49. Release 0 passes clean install and upstream-baseline return; every later stable release passes clean install, upgrade from the immediately previous stable release, pre-upgrade backup, and the applicable rollback or restore path on every claimed platform.
50. Raw capture, narration, edit, and final video files exist only under a canonical external `STUDIO_SUBMISSION_ROOT`; the repository and release archives contain only scripts, text manifests, captions/templates, and an optional public YouTube URL.
51. A failed post-merge or packaging verification cannot replace `Latest` or start the next release; packaging-only failures retry idempotently, while merged-code failures produce a safe automatic revert pull request or a visible action-required block.

# 6. MVP implementation sequence

This is the build sequence for Codex. It is not a product todo-list feature.

| ID | Work package | Depends on | Required exit evidence |
|---|---|---|---|
| R0-01 | Create fork metadata, upstream remote policy, baseline lock, patch ledger, and licensing proof | — | Untouched upstream suite passes; base SHA recorded |
| R0-02 | Pin Codex; generate schema bundles; add fake Linear and App Server fixtures | R0-01 | Version/schema hashes and deterministic fixtures |
| R0-03 | Implement App Server transport/process conformance | R0-02 | Framing, stderr, timeout, overload, frame-limit, and orphan-cleanup tests |
| R0-04 | Add structured event sink and stable run/attempt/operation IDs | R0-02–03 | Event/replay/idempotency contract tests |
| R0-05 | Harden cancellation, retries, workspaces, and managed Linear mutation seams | R0-02–04 | Property, path-safety, lifecycle-denial, and outbox-seam tests |
| R0-06 | Add capability/model/effort/quota/service-tier/identity/multi-agent discovery and readiness manifest | R0-02–05 | Exact compatibility manifest; real cap mapping; Doctor-ready result |
| R0-07 | Add protected staged release train, publication Doctor, candidate/final release manifests, GitHub auto-merge workflow, package verification, and previous-release upgrade/rollback harness | R0-01–06 | `v0.1.0` is automatically merged, remotely verified, installable, and published without bypassing branch protection |
| R1-01 | Add SQLite store, migrations, tracker outbox, artifact store, and online backup | R0-04–07 | Required PRAGMAs, crash/reopen, migration, hash, and restore tests |
| R1-02 | Add normalized event persistence and projection replay | R1-01 | Persist-before-broadcast and rebuild tests |
| R1-03 | Add Studio config schema and last-known-good dynamic reload | R0-06, R1-01 | Scope, reload, and selective-invalidation tests |
| R1-04 | Add Doctor and startup readiness gate | R0-06, R1-01–03 | All pass/warn/fail states, redaction, and blocking behavior |
| R1-05 | Add model roles, Work pace, bounded delegation, change-surface leases, and capability-gated Turn speed | R0-06, R1-01, R1-03 | Pace/cap/depth/conflict/quality-lane/service-tier tests |
| R1-06 | Add dynamic usage snapshots, protected quota admission, identity-bound waits, budgets, and reset redemption | R0-06, R1-01, R1-03, R1-05 | Bucket replacement, credit separation, wait/restart/account/resume tests |
| R1-07 | Add durable issue claims, App Server operation ledger, issue-contract/eligibility snapshots, and deterministic tracker lifecycle/outbox | R0-03–05, R1-01–03 | Crash-window, uncertain-start, contract-change, external-terminal, and completion-sync tests |
| R1-08 | Add typed run memory and validated checkpoints | R1-01–03, R1-05–07 | Mandatory-state and artifact round-trip tests |
| R1-09 | Add compaction/rotation audit and fresh-thread fallback | R1-08 | Fault-injection preservation tests |
| R1-10 | Add quality checks, evidence manifest, staleness, and completion reducer | R1-01–03, R1-07–09 | Completion-invariant and manifest-schema tests |
| R1-11 | Add detached review and bounded repair loop | R0-06, R1-08–10 | Review/repair E2E |
| R1-12 | Add circuit breakers, approval/input blockers, and recovery diagnostics | R1-06–11 | Repeated-failure and fail-closed request tests |
| R1-13 | Add local operator pairing; define frontend brief/state/action inventories; build production tokens, Component Lab, and shell | R1-02–04 | Pairing/security E2E, screenshots, contrast, component-state, and accessibility baseline |
| R1-14 | Build first real Mission Control → Run Detail vertical slice, including Work pace | R1-02, R1-05–07, R1-13 | Canonical live state, one real control, Playwright, and visual review |
| R1-15 | Complete Run Detail, contract, usage, evidence, memory, review, handoff, and replay | R1-06–12, R1-13–14 | Long-content, recovery, responsive, and accessibility E2E |
| R1-16 | Build History | R1-01–02, R1-13 | Pagination/filter tests |
| R1-17 | Build dynamic Usage and capacity interface | R1-05–06, R1-13 | Buckets, credits, pace, waits, account, and optional Fast UI tests |
| R1-18 | Build Setup & Doctor UI | R1-04, R1-13 | Compatibility evidence and remediation E2E |
| R1-19 | Add showcase fixture and Build Week evidence generator | R1-14–18 | Judge-path rehearsal |
| R1-20 | Run full live smoke, security, accessibility, performance, recovery, and soak | All prior R1 | Signed Release 1 readiness report |
| R1-21 | Publish Release 1 through the protected release train | R1-20 | `v1.0.0` auto-merges, passes post-merge verification, and is installable from verified GitHub Release assets |
| R1.1-01 | Freeze features; burn down defects; rerun clean-machine, live, visual, accessibility, restart, quota, backup, and soak drills | R1-21 | Submission-hardening evidence is green with no release blocker |
| R1.1-02 | Finalize code/docs/packaging and publish Release 1.1 through the protected release train | R1.1-01 | `v1.1.0` auto-merges, passes post-merge verification, and its GitHub Release assets verify |
| R1.1-03 | Prepare the external submission workspace from exact `v1.1.0`; capture or assemble scenes, captions, thumbnail, transcript, and final MP4; record `/feedback` ID and upload handoff | R1.1-02 | Verified under-three-minute external export and checksums are upload-ready; repository/release contain no media binary; final submission checklist passes |

Parallel work is allowed only when dependencies and shared-file ownership are explicit.

## 6.1 Critical path

The critical path is:

```text
R0-01 → R0-02 → R0-03 → R0-04 → R0-06 → R0-07
      → R1-01 → R1-02 → R1-07 → R1-08 → R1-10 → R1-11
      → R1-15 → R1-19 → R1-20 → R1-21
      → R1.1-01 → R1.1-02 → R1.1-03
```

R0-06 and R1-04 are parallel blocking gates: no managed live run may start until both are green.

## 6.2 Cut order if schedule pressure occurs

Cut in this order:

1. non-essential motion;
2. optional History filters;
3. non-critical charts or analytics;
4. light theme only if the remaining theme is fully accessible;
5. Fast/Turn-speed UI when the live reference model does not advertise the capability; retain hidden compatibility code and tests.

Never cut:

- real Codex/GPT-5.6 Sol Ultra execution;
- exact version/schema/transport readiness gate;
- Doctor;
- issue-contract and eligibility separation;
- deterministic managed tracker handoff;
- Work pace and enforceable root/helper caps;
- dynamic provider-backed usage and correct credits/spend-control semantics;
- protected quality capacity and identity-bound automatic reset resume;
- exact checkpoints;
- deterministic checks;
- independent review;
- evidence and stale-evidence invalidation;
- restart, SQLite, and outbox safety;
- judge setup path;
- required accessibility;
- Build Week attribution.

## 6.3 Frontend implementation order

The UI work SHALL follow this order and must not become a separate months-long phase:

1. **Experience contract** — frontend brief, route purposes, state inventory, action inventory, and visual thesis.
2. **Production foundation** — tokens, typography, layout primitives, status treatment, buttons, form controls, disclosures, dialog, toast, skeleton, and dev/test Component Lab.
3. **Golden vertical slice** — one real run appears in Mission Control, opens in Run Detail, executes one real control, and updates from a persisted event.
4. **Run truth** — plan, activity, changes, checks, review, memory, usage, and evidence use authoritative projections.
5. **Operational support** — History, Usage, and Setup & Doctor.
6. **State completeness** — empty, loading, partial, stale, reconnecting, blocked, action-pending, recoverable-error, terminal-error, mobile, and reduced-motion states.
7. **Polish and freeze** — screenshot critique, accessibility, responsive fixes, copy edit, performance, and visual baselines.

A route cannot advance to the next step merely because its happy path looks polished. Functional truth, failure behavior, accessibility, and automated coverage are part of the design.

---

# 7. Release 2 — Specification Planner and Linear Backlog

## 7.1 User benefit

A user can provide a prompt or `SPEC.md` and receive a high-quality, dependency-aware Linear plan without manually writing every issue.

This is the first release with product planning and todo creation.

## 7.2 Scope

Included:

- paste prompt;
- upload or select repository `SPEC.md`;
- Planner conversation;
- read-only repository research;
- assumptions and decisions;
- normalized specification revisions;
- acceptance criteria;
- dependency-aware work breakdown;
- independent plan critic;
- idempotent Linear issue and relation creation;
- change requests and impact analysis;
- traceability from requirement to issue and run.

Excluded:

- native tracker;
- live bidirectional tracker sync;
- team approval workflows;
- deployment;
- non-Codex providers.

## 7.3 Planner roles

### Planner Conductor

- GPT-5.6 Sol Ultra.
- Owns requirements, tradeoffs, decomposition, and final plan.
- Read-only repository access until the plan is accepted or Autopilot policy releases it.

### Repository Explorer

- GPT-5.6 Terra Medium.
- Maps code, docs, tests, architecture, and ownership.

### Plan Critic

- GPT-5.6 Sol High.
- Fresh context.
- Checks coverage, cycles, task size, validation, risk, and contradictions.

Deterministic code validates:

- unique IDs;
- DAG acyclicity;
- required fields;
- Linear idempotency;
- duplicate issue keys;
- schema and provenance.

## 7.4 Planner artifacts

Store:

- original source;
- normalized spec revision;
- requirements;
- non-goals;
- assumptions;
- decisions;
- research references;
- risk register;
- acceptance matrix;
- plan revision;
- issue graph;
- source-to-issue traceability;
- change history.

## 7.5 Question policy

The Planner does not ask questions answerable from the repository or existing policy.

Questions:

- are batched;
- explain impact;
- provide options;
- recommend a default;
- allow `Use recommended defaults`.

Autopilot may choose only reversible, policy-compliant defaults.

## 7.6 Linear creation

The Planner:

- creates parent/child issues;
- creates blocker relations;
- adds required dispatch labels only when work is ready;
- writes an idempotency marker;
- stores internal-to-Linear mappings;
- never duplicates issues after retry;
- updates unstarted issues after a spec revision;
- never rewrites completed history.

## 7.7 Release 2 UI

Add:

- `Spec & Plan`;
- `Plan Review`;
- `Change Requests`.

Do not add a duplicate native board. Link to Linear for ordinary work management.

## 7.8 Release 2 acceptance

- prompt-to-plan fixed corpus passes;
- every requirement is covered or explicitly deferred;
- generated dependencies are acyclic;
- critic findings are resolved or explicitly rejected;
- rerunning publication creates no duplicates;
- a mid-flight change produces a new spec revision and impact analysis;
- incompatible active work checkpoints safely;
- Release 1 quality, quota, memory, and evidence gates remain intact.
- Release 2 is automatically promoted, merged, tagged, published as `v2.0.0`, remotely verified, and reinstalled successfully before Release 3 begins.

---

# 8. Release 3 — Preview Deployments and Release Operations

## 8.1 User benefit

A completed change can be proven in a live environment, not only by local tests.

## 8.2 Design principle

Use provider-neutral, repository-owned command contracts first.

Do not add multiple deployment-vendor SDKs before the generic contract is proven.

## 8.3 `WORKFLOW.md` deployment contract

Deployment is a later-release, provider-neutral command protocol. Commands are direct argument arrays, not interpolated shell strings.

```yaml
studio:
  deploy:
    protocol_version: 1

    preview:
      create:
        argv: ["./scripts/studio-deploy", "preview", "create"]
        timeout_ms: 900000
        network_access: true
      verify:
        argv: ["./scripts/studio-deploy", "preview", "verify"]
        timeout_ms: 300000
        network_access: true
      destroy:
        argv: ["./scripts/studio-deploy", "preview", "destroy"]
        timeout_ms: 300000
        network_access: true

    staging:
      create:
        argv: ["./scripts/studio-deploy", "staging", "create"]
        timeout_ms: 900000
        network_access: true
      verify:
        argv: ["./scripts/studio-deploy", "staging", "verify"]
        timeout_ms: 300000
        network_access: true
      rollback:
        argv: ["./scripts/studio-deploy", "staging", "rollback"]
        timeout_ms: 600000
        network_access: true
      approval: policy

    production:
      create:
        argv: ["./scripts/studio-deploy", "production", "create"]
        timeout_ms: 900000
        network_access: true
      verify:
        argv: ["./scripts/studio-deploy", "production", "verify"]
        timeout_ms: 300000
        network_access: true
      rollback:
        argv: ["./scripts/studio-deploy", "production", "rollback"]
        timeout_ms: 600000
        network_access: true
      approval: explicit
```

Studio invokes the executable directly with the declared `argv`, an isolated release working directory, a minimal environment, and JSON on stdin:

```json
{
  "schema_version": 1,
  "operation": "preview.create",
  "idempotency_key": "uuid",
  "environment": "preview",
  "commit_sha": "sha",
  "artifact": {
    "path": "/absolute/isolated/path/release.tar.gz",
    "sha256": "sha256:..."
  },
  "previous_release_id": null,
  "deployment_id": null,
  "release_id": null,
  "metadata": {}
}
```

On success, stdout contains exactly one bounded JSON object and nothing else:

```json
{
  "schema_version": 1,
  "status": "succeeded",
  "deployment_id": "dep_123",
  "release_id": "rel_123",
  "url": "https://preview.example.test",
  "deployed_commit_sha": "sha",
  "deployed_artifact_sha256": "sha256:...",
  "previous_release_id": null,
  "rollback_token": "opaque-non-secret-reference",
  "evidence": []
}
```

Protocol rules:

- stderr is bounded diagnostic output; it cannot contain secrets and is not parsed as the result;
- stdout contamination, invalid JSON, an oversized result, mismatched commit/artifact hash, or an unknown schema/status is a protocol failure;
- non-zero exit is a failed operation even if stdout contains success JSON;
- retries reuse the same idempotency key and first query/reconcile provider state when the prior outcome is uncertain;
- commands receive secret references through the configured secret broker, never YAML literals or JSON values;
- no command may infer the target commit from a mutable branch;
- the operation result is persisted before UI broadcast or a follow-on promotion;
- all deployment adapters must pass one common command-protocol conformance suite before vendor-specific integration is considered.

## 8.4 Preview lifecycle

1. Build an immutable artifact from a commit SHA.
2. Create preview with idempotency key.
3. Capture preview ID and URL.
4. Run health check.
5. Run smoke/E2E checks.
6. Capture screenshots, logs, and metrics.
7. Attach deployment evidence to the run.
8. Emit a canonical deployment event containing environment, release ID, artifact hash, commit SHA, previous release, timestamps, verification result, and rollback target.
9. Destroy preview on expiry or explicit action.

## 8.5 Safety

- deployment secrets are injected by reference into one isolated operation;
- production is never the default;
- production requires explicit confirmation showing commit, artifact hash, environment, current release, and rollback target;
- deployment commands use the structured direct-exec protocol in Section 8.3 and never interpolate untrusted shell text;
- permissions, network egress, timeout, CPU/memory, and output limits are explicit per operation;
- no deployment runs from a dirty workspace;
- the artifact SHA must match reviewed code and the command must return the same deployed SHA;
- stale contract, review, checks, or evidence blocks deployment;
- rollback is tested before production is enabled;
- a failed verification marks the deployment failed and triggers only the configured idempotent rollback policy;
- automatic rollback cannot promote or target a different environment;
- the UI never labels a deployment healthy without a current passing probe;
- every environment exposes its currently deployed release and commit when the platform can determine them;
- release and deployment events are durable enough for Maintenance Autopilot to correlate a production signal with the code actually running;
- an unknown prior operation outcome is reconciled before any retry;
- a lost process, timeout, or Studio restart cannot create a second deployment for the same idempotency key.

## 8.6 Release interface

Add `Releases`:

- environments;
- commit;
- artifact;
- status;
- preview URL;
- checks;
- screenshots;
- logs;
- rollback availability;
- audit trail.

Controls:

- `Create preview`;
- `Verify again`;
- `Destroy preview`;
- `Promote to staging`;
- `Deploy to production`;
- `Rollback`.

Each control shows exact impact and prerequisites.

## 8.7 Release 3 acceptance

- preview create/verify/destroy passes against a reference app;
- duplicate requests do not create duplicate previews;
- reviewed SHA equals deployed SHA;
- failed verify blocks promotion;
- rollback drill passes;
- the deployment event stream can reconstruct which commit and artifact reached each environment;
- production cannot run without explicit policy and confirmation;
- deployment evidence appears in the same proof graph as code evidence;
- Release 1 and Release 2 gates remain green.
- Release 3 is automatically promoted, merged, tagged, published as `v3.0.0`, remotely verified, and reinstalled successfully before Release 4 begins.

---

# 9. Release 4 — Native Work Graph and Todo System

## 9.1 User benefit

A user may run Symphony Studio without Linear and manage planning, dependencies, execution, and evidence in one AI-native work system.

This is the first release containing the built-in todo list.

## 9.2 Authority rule

A project selects exactly one tracker of record:

- Linear; or
- Native.

Do not implement always-on bidirectional synchronization.

Import/export is a deliberate migration operation with a recorded boundary.

## 9.3 Native work model

Work types:

- initiative;
- epic;
- story;
- task;
- bug;
- research;
- migration;
- review;
- release.

Required fields:

- stable ID;
- title;
- outcome;
- user value;
- scope;
- non-goals;
- acceptance criteria;
- validation;
- parent;
- blockers and dependents;
- typed relations including `duplicates`, `regression_of`, `covered_by`, `fixed_by`, `released_in`, and `backport_of`;
- priority;
- risk;
- repository references;
- spec provenance;
- current state;
- current run;
- evidence;
- version history.

State machine:

```text
Discovery → Draft → Ready → Queued → Claimed → In Progress
          → Verifying → Reviewing → Merge Ready → Done
```

Exceptional states:

```text
Blocked · Retrying · Rework · Failed · Cancelled · Superseded
```

## 9.4 Native interface

Add:

- Board;
- Dependency Graph;
- Work Item Detail;
- Saved Views;
- Search.

Board requirements:

- Kanban and dense list;
- virtualized large sets;
- filters;
- keyboard movement;
- drag creates a typed transition;
- invalid moves explain why;
- no automatic transition without an event.

Dependency graph:

- DAG;
- critical path;
- blocker reasons;
- cycle detection;
- accessible list alternative;
- filters;
- progressive rendering.

## 9.5 AI board steward

The Planner may:

- split oversized work;
- merge duplicates;
- propose missing dependencies;
- flag stale work;
- compute readiness;
- explain why work is not running.

It may not:

- silently delete work;
- introduce cycles;
- repeatedly split work without limit;
- rewrite completed history;
- thrash status.

All automated changes are versioned and reversible.

## 9.6 Linear migration

Support:

- import Linear issues, relationships, comments, and references;
- export Native work to Linear;
- dry-run;
- mapping report;
- conflict report;
- immutable migration checkpoint;
- rollback before cutover;
- no silent dual authority.

## 9.7 Release 4 acceptance

- Native passes the same tracker contract as Linear;
- work and dependency state survives restart;
- Planner creates Native work idempotently;
- no cycles;
- board and graph remain responsive at the documented scale;
- migration preserves IDs/provenance/evidence;
- one tracker is clearly authoritative;
- Release 1–3 gates remain green.
- Release 4 is automatically promoted, merged, tagged, published as `v4.0.0`, remotely verified, and reinstalled successfully; the prior Linear-backed stable release remains available.

---

# 10. Release 5 — Multi-project, Remote Execution, and Collaboration

## 10.1 User benefit

A user or small team can operate multiple repositories and share selected projects without sharing credentials or workspaces.

## 10.2 Architecture

Move from one project per process to:

- one Studio control plane;
- one isolated runner process/container per active project;
- a global capacity broker;
- project-scoped storage and events;
- per-user Codex identities;
- local and SSH worker pools.

Do not convert the runner into an inseparable monolith.

## 10.3 Accounts and roles

Roles:

- platform admin;
- project owner;
- maintainer;
- contributor;
- viewer.

Platform admin does not automatically receive project content.

Project sharing is explicit and audited.

## 10.4 Credential isolation

- each Codex identity belongs to one user;
- each project binds one execution identity;
- collaborators do not see credential values;
- a runtime receives one identity;
- quota is attributed to identity, project, issue, and run;
- no automatic borrowing from another user.

## 10.5 Capacity broker

Lease dimensions:

- project;
- user identity;
- worker;
- issue;
- CPU/memory/disk;
- model role;
- token budget;
- expiry and heartbeat.

Scheduling:

- bounded;
- fair;
- starvation-resistant;
- quota-aware;
- explainable.

## 10.6 Remote execution

First remote adapter: SSH workers.

Requirements:

- mutual host verification;
- ephemeral scoped credentials;
- project-isolated directories;
- health checks;
- version negotiation;
- event replay;
- safe disconnect;
- no cross-project writable mounts.

Containers become the default for multi-user hosts.

Kubernetes remains optional after SSH is proven.

## 10.7 Notification preferences and channel routing

Each user can choose where important updates are delivered without changing another member’s preferences.

Initial channels:

- in-app notification centre, always available;
- email;
- Slack incoming webhook;
- Discord webhook;
- generic HTTPS webhook signed by Studio.

SMS, native mobile push, and a marketplace of notification providers are not included.

Preference scopes:

- user default;
- per-project override;
- event category;
- delivery mode: immediate, digest, or off;
- quiet hours in the user’s timezone;
- severity threshold.

Default immediate events:

- credential or configuration action required;
- hard blocker or circuit breaker;
- security or context-preservation failure;
- run failed;
- run completed;
- waiting for quota longer than a configurable threshold;
- quota available and work resumed;
- deployment approval/failure/rollback when Release 3 is enabled;
- new production regression, maintenance action required, patch failure, release-monitoring regression, or verified maintenance resolution when Release 6 is enabled;
- invitation or role change.

Routine plan steps, command output, file reads, and progress events stay in the activity feed unless the user explicitly opts into a digest. The product must not turn autonomous work into notification spam.

Delivery rules:

- every notification has a stable deduplication key;
- sends use the transactional outbox and bounded retries;
- one failed channel never blocks project work or another channel;
- delivery history records queued, sent, delivered when supported, failed, and suppressed states;
- `Send test` validates a channel before enabling it;
- channel secrets are encrypted and never returned to the browser after creation;
- generic webhooks include timestamped signatures and replay protection;
- payloads contain a concise summary and deep link, not source code, diffs, secrets, or raw logs by default;
- quiet hours defer non-critical notifications and never suppress an explicitly configured critical event;
- digest generation groups duplicates and related events into one useful update;
- revoking project access stops future project notifications immediately.

## 10.8 Portfolio interface

Add:

- project switcher;
- portfolio health;
- global attention;
- identity usage view;
- worker capacity;
- project membership;
- notification settings and delivery history;
- audit.

Do not merge project work boards into one ambiguous global board.

## 10.9 Release 5 acceptance

- two projects run concurrently without cross-project state or credential leakage;
- two users see only authorized projects;
- one project failure does not stop another;
- fair scheduling prevents starvation;
- remote worker loss recovers safely;
- event replay survives connection loss;
- per-user quota attribution is correct;
- notification preferences are isolated per user and project;
- quiet hours, immediate delivery, digest mode, deduplication, test delivery, retry, and revocation pass end-to-end tests;
- notification payloads pass secret and sensitive-content scanning;
- a failed notification channel does not block a run;
- all earlier release gates continue to pass.
- Release 5 is automatically promoted, merged, tagged, published as `v5.0.0`, remotely verified, and reinstalled successfully with cross-project upgrade and rollback evidence before Release 6 begins.

---


# 11. Release 6 — Maintenance Autopilot

## 11.1 User benefit and scope

A project can keep itself healthy after deployment without turning every report into ticket noise or allowing an agent to patch production blindly.

Release 6 adds a **Maintenance Autopilot** that:

1. receives trusted bug, feedback, runtime, CI, uptime, and release signals;
2. verifies and normalizes each delivery;
3. strips secrets and sensitive customer data before model use;
4. groups reports into one canonical maintenance case;
5. checks whether the problem is already fixed, already being fixed, or covered by an unreleased change;
6. establishes reproduction or equivalent evidence;
7. schedules a patch only when new engineering work is required;
8. runs the patch through the same Symphony validation, independent review, repair, and evidence gates as planned work;
9. follows the fix through preview, release, and an observation window; and
10. resolves or reopens the source reports based on deployed evidence.

The default outcome is a verified pull request, not an automatic production change. Guarded merge and release automation is opt-in, risk-limited, and available only when the Release 3 deployment contract and all quality gates are active.

Release 6 depends on Releases 2–5:

- Release 2 supplies work creation and change contracts;
- Release 3 supplies immutable release identity and deployment evidence;
- Release 4 supplies native maintenance relations when the Native tracker is selected;
- Release 5 supplies multi-project isolation, fair capacity, accounts, and notification routing.

Release 6 remains Codex-only.

## 11.2 Product terminology

Use these terms consistently:

- **Maintenance source:** an external system that reports bugs, feedback, errors, failed checks, uptime failures, or release state.
- **Delivery:** one authenticated webhook or polled source response.
- **Maintenance signal:** one normalized, immutable observation from a source.
- **Maintenance case:** the canonical Studio record for one suspected underlying defect or regression. A case may contain many signals from several sources.
- **Coverage:** evidence that existing work, a commit, a pull request, a release candidate, or a deployed release already addresses the case.
- **Reproduction:** a deterministic failing test, runnable scenario, replay, trace-backed oracle, or other approved proof that distinguishes broken from fixed behavior.
- **Observation window:** the post-release period and evidence threshold used to decide whether the fix held.

Do not call every signal an issue or every user complaint a bug. Classification precedes work creation.

## 11.3 Source strategy

### 11.3.1 Initial sources

Release 6 SHALL ship four source paths.

#### GitHub App

Use the existing or project-scoped GitHub App connection to consume only subscribed events needed by Maintenance Autopilot:

- `issues` and `issue_comment` for reports and clarification;
- `pull_request` and review/check state for active-fix coverage;
- `check_run`, `check_suite`, and `workflow_run` for CI regressions;
- `deployment`, `deployment_status`, and `release` for code-to-environment correlation;
- `push` only when required to update commit ancestry or release coverage.

GitHub issue forms are RECOMMENDED for repositories that accept public or internal bug reports. A generated bug form SHOULD request current behavior, expected behavior, reproduction steps, affected version, environment, and optional screenshots or logs. Reporters are never treated as trusted instructions.

#### Linear

Reuse the project’s Linear connection for:

- issues, comments, labels, relations, and state changes;
- bug or maintenance labels configured by project policy;
- dependencies and duplicate links;
- idempotent status and summary write-back.

Linear remains tracker authority when the project selected Linear. Maintenance cases remain Studio’s correlation and evidence authority.

#### Sentry

A Sentry connection MAY ingest:

- error and performance issues;
- issue alerts and regressions;
- stack traces, breadcrumbs, tags, traces, replays, attachments, and suspect-commit references when available;
- user feedback linked to runtime context;
- release identity, first/last seen release, environment, event and affected-user counts, and release-health data.

The connector SHALL capability-discover the exact API, alert, webhook, and permission surfaces available to the connected Sentry organization. Missing capabilities degrade explicitly; they do not produce guessed fields.

#### Generic signed webhook

Other systems integrate through a small provider-neutral endpoint rather than requiring an SDK in Release 6.

The accepted body is versioned JSON:

```json
{
  "schema_version": 1,
  "event_id": "source-stable-id",
  "type": "bug",
  "occurred_at": "2026-07-14T12:34:56Z",
  "project_key": "payments-web",
  "title": "Checkout returns 500 after coupon removal",
  "description": "Sanitized report text",
  "severity": "high",
  "environment": "production",
  "release": {
    "version": "web-2026.07.14.3",
    "commit_sha": "40-hex-sha-or-null"
  },
  "fingerprint": "provider-or-project-fingerprint",
  "source_url": "https://source.example/report/123",
  "metrics": {
    "events": 84,
    "affected_users": 19
  },
  "metadata": {}
}
```

Requirements:

- HMAC-SHA256 signature over the exact raw body;
- timestamp and nonce or stable delivery ID;
- replay window and idempotent delivery record;
- payload and attachment size limits;
- allowlisted project key;
- no executable code or arbitrary tool instructions;
- unknown fields retained only in a restricted raw artifact, not promoted into trusted state automatically.

### 11.3.2 Deferred source adapters

Jira, GitLab Issues, Bugsnag, Datadog Error Tracking, PagerDuty, Intercom, Zendesk, Canny, PostHog, email intake, and additional customer-support products are later adapters. They are not required for Release 6 exit.

The generic webhook is the escape hatch until usage evidence justifies a dedicated adapter.

## 11.4 Maintenance-source contract

Define a versioned `MaintenanceSource` behaviour separate from the tracker adapter.

A source adapter exposes only capabilities it supports:

```text
verify_delivery(raw_request)
normalize_delivery(verified_delivery)
hydrate_signal(signal_ref)
fetch_updates(cursor)
link_case(source_ref, case_ref)
write_status(source_ref, status_payload)
request_information(source_ref, template_payload)
resolve_source(source_ref, resolution_payload)
reopen_source(source_ref, reason_payload)
health()
capabilities()
```

Rules:

- `verify_delivery` runs before JSON fields influence routing or storage outside the restricted delivery record.
- Normalization is deterministic wherever possible.
- Source write operations use idempotency keys and optimistic conflict checks.
- A read-only source is valid; unsupported write-back is shown as unsupported.
- Tracker authority and maintenance-source authority are distinct. Connecting GitHub Issues does not silently replace Linear or Native as the project tracker.
- A source adapter MUST NOT execute code or choose a fix.

## 11.5 Canonical data model

### 11.5.1 `MaintenanceSignal`

An immutable normalized observation contains:

| Field | Meaning |
|---|---|
| `id` | Studio UUID. |
| `project_id` | Authorized project boundary. |
| `source_id` | Configured source. |
| `source_delivery_id` | Stable delivery ID used for deduplication. |
| `source_object_id` | Issue, feedback, alert, error group, check, or incident identifier. |
| `source_revision` | ETag, update timestamp, or provider revision when available. |
| `signal_type` | `bug_report`, `user_feedback`, `error_group`, `ci_failure`, `uptime_failure`, `release_regression`, `support_message`, `security_signal`, or `other`. |
| `occurred_at` | Source event time. |
| `received_at` | Studio receipt time. |
| `title` and `summary` | Sanitized concise content. |
| `environment` | Production, staging, preview, development, or source-specific value. |
| `release_version` | Observed release, if supplied. |
| `commit_sha` | Observed commit, if supplied and valid. |
| `provider_fingerprint` | Stable source grouping key when supplied. |
| `normalized_fingerprint` | Studio-computed deterministic fingerprint. |
| `severity` and `impact` | Provider values plus normalized impact fields. |
| `first_seen_at` and `last_seen_at` | Signal recurrence window when known. |
| `event_count` and `affected_users` | Nullable provider metrics. |
| `component_hints` | Sanitized route, service, package, symbol, or ownership hints. |
| `evidence_refs` | Restricted links to stack, trace, replay, screenshot, attachment, check log, or source artifact. |
| `privacy_flags` | PII, customer data, secret, attachment, and retention classification. |
| `authenticity` | Verified source, method, key revision, and replay status. |
| `raw_artifact_ref` | Encrypted, restricted original delivery when retention policy permits. |

A signal never changes. Later source changes create a new signal or a source-revision record.

### 11.5.2 `MaintenanceCase`

A case contains:

- stable case ID and project;
- canonical title and defect statement;
- classification and confidence;
- user and business impact;
- affected environments, releases, branches, and supported versions;
- linked signals and correlation proof;
- source-of-truth tracker binding, if one was created;
- suspected component and code owners;
- reproduction status and artifacts;
- coverage state and linked work, branches, commits, pull requests, release candidates, deployments, and backports;
- dependencies, conflicts, and change-surface locks;
- risk class and automation eligibility;
- maintenance work item and run IDs;
- patch, review, CI, and evidence state;
- release target and observation policy;
- source write-back state;
- resolution and regression history;
- immutable audit events.

### 11.5.3 Coverage state

Exactly one current coverage state is projected:

```text
unknown
uncovered
possible_coverage
fix_in_progress
fixed_on_branch
in_release_candidate
released_monitoring
resolved
regressed
not_applicable
```

`possible_coverage` never suppresses a new fix automatically. Only proven coverage may do so.

## 11.6 Classification and state machine

### 11.6.1 Classification

Classify each case as one of:

- product defect;
- regression;
- CI/build regression;
- uptime or operational incident;
- user-feedback bug;
- feature request;
- support question;
- documentation/content defect;
- security or privacy signal;
- abuse/spam;
- telemetry noise;
- unknown.

Only product defects, regressions, qualifying CI failures, documentation defects, and policy-approved operational defects are eligible for automatic patch preparation.

Feature requests enter normal planning. Support questions are routed to the configured tracker or human queue and create no automatic customer reply. Security and privacy signals enter a restricted human-led incident path. Spam and telemetry noise create no engineering work.

### 11.6.2 Maintenance model roles

Use models only where judgment adds value:

- **Deterministic services** verify deliveries, redact data, compute exact fingerprints, inspect commit ancestry, read tracker relations, enforce risk policy, schedule work, and decide whether evidence gates pass. These are not agent tasks.
- **Maintenance Analyst — GPT-5.6 Terra High** is an optional, read-only role for ambiguous classification, concise evidence requests, semantic duplicate suggestions, and component hints after deterministic processing. Terra is used because this work is bounded, high-volume, and does not justify Sol Ultra by default.
- **Patch Conductor — GPT-5.6 Sol Ultra** is the existing accountable implementation agent. It is invoked only after the case is `Ready for fix` and receives the exact maintenance work contract.
- **Independent Reviewer — fresh GPT-5.6 Sol High or Max** uses the existing detached review contract and has no source-resolution authority.
- **Recovery Analyst** may diagnose a failed reproduction or patch attempt under the existing read-only failure-analysis rules.

The Maintenance Analyst SHALL receive a structured, redacted case capsule and return a typed result containing classification suggestion, confidence, evidence, conflicts, missing information, and candidate relations. It MUST NOT:

- merge or split cases;
- lower risk;
- create a patch or tracker work item;
- close, resolve, or publicly comment on a source;
- override deterministic coverage or release evidence;
- inspect raw restricted customer data unless a separate policy-approved tool grants a sanitized view.

Batch low-impact classification work where possible. Do not invoke a model when exact source type, labels, fingerprints, or policy already determine the result.

### 11.6.3 Case lifecycle

```text
Received → Verifying → Correlating → Triaging
         → Needs evidence
         → Covered
         → Ready for fix → Reproducing → Patching → Verifying fix
         → Reviewing → Awaiting release → Monitoring → Resolved
```

Exceptional states:

```text
Duplicate · Already fixed · Not a bug · Feature request · Support
Security review · Spam · Suppressed · Blocked · Failed · Regressed · Cancelled
```

State ownership:

- ingress service owns Received and Verifying;
- correlation engine owns Correlating and candidate duplicate links;
- deterministic policy owns exact classifications; the read-only Maintenance Analyst may recommend ambiguous classifications;
- reproduction service owns Reproducing and evidence status;
- scheduler and Symphony runner own Patching;
- deterministic validation and independent review own Verifying fix and Reviewing;
- release service owns Awaiting release and Monitoring;
- resolution service owns Resolved only after policy evidence passes.

No implementation agent may set Resolved directly.

## 11.7 Ingestion trust, privacy, and content safety

All source content is untrusted data.

Before a signal may enter an agent context:

1. verify source signature, installation, organization, project, and timestamp;
2. reject replayed, oversized, malformed, or unauthorized deliveries;
3. store the raw body only in a restricted encrypted artifact if policy permits;
4. scan for credentials, tokens, cookies, authorization headers, personal data, payment data, and customer content;
5. redact or tokenize sensitive values while preserving stable correlation where permitted;
6. classify attachments and exclude unsafe or unsupported types;
7. convert HTML and rich text to sanitized plain text or safe Markdown;
8. label every field with source provenance;
9. prevent report text from changing system instructions, permissions, tools, network policy, release policy, or tracker authority.

Default model context excludes:

- user email and direct identifiers;
- session cookies and headers;
- full request bodies;
- raw database values;
- unredacted URLs with secrets or personal query parameters;
- screenshots, replays, or attachments until a policy-approved tool requests the sanitized artifact.

A project may configure stricter retention or disable model use of customer-derived content entirely.

## 11.8 Correlation and deduplication

Correlation is deterministic-first and explainable.

Evaluate in this order:

1. exact source delivery and source object identity;
2. provider issue group or fingerprint;
3. existing source links and explicit duplicate relations;
4. normalized exception type, top application frames, route or endpoint, service, and component;
5. affected release and environment overlap;
6. reproduction signature or failing-test identity;
7. linked issue, branch, commit, pull request, or work item;
8. normalized title and symptom similarity;
9. model-assisted semantic similarity as a candidate signal only.

Automatic case linking requires either an exact provider/source relationship or multiple independent deterministic matches. A model similarity score alone may suggest a duplicate but may not merge cases or suppress work.

Every correlation decision stores:

- matched features;
- conflicting features;
- confidence band;
- selected canonical case;
- actor or policy version;
- reversible merge record.

Humans may split or merge cases. Splitting restores source links and state without losing history.

Do not group reports that have materially different:

- expected behavior;
- affected component;
- security boundary;
- release range;
- reproduction;
- root cause; or
- required fix.

## 11.9 Release-aware fix coverage

Before creating maintenance work, build a **fix coverage graph** spanning:

- source-reported release and environment;
- currently deployed release and commit per environment;
- default branch and supported release branches;
- open and recently merged pull requests;
- active Linear or Native work;
- current Symphony runs and predicted change surfaces;
- release candidates and promotion state;
- commits already deployed or awaiting deployment;
- backports and supported-version policy;
- relevant test and reproduction results.

Coverage checks include:

- exact source or issue links;
- GitHub linked pull requests and closing keywords;
- tracker relations such as duplicate, covered-by, fixed-by, and backport-of;
- commit ancestry between the proposed fix and deployed release;
- whether the reproduction fails on the affected commit and passes on the alleged fix commit;
- whether the alleged fix is included in the release candidate or environment;
- whether an active work item changes the same failing behavior;
- whether a dependency upgrade or shared-file lock already owns the required change surface.

Possible outcomes:

- **Already fixed:** the affected reproduction passes on a supported target commit and the fix is deployed to the affected environment.
- **Fix in progress:** an active work item or pull request has proven coverage; attach the case and monitor it.
- **Fixed, not released:** the fix is on a target branch or release candidate; do not create a duplicate patch.
- **Backport needed:** the default branch is fixed but a supported release branch remains affected.
- **Uncovered:** no current work or commit proves coverage; the case may proceed to reproduction and patching.
- **Unknown:** evidence is insufficient; request or gather more evidence rather than assuming.

Textual similarity between a report and a pull-request title is not proof that the pull request fixes it.

## 11.10 Reproduction and evidence gate

A case may become `Ready for fix` only when it has an approved failure oracle.

At least one of the following is required:

1. a deterministic local or integration reproduction;
2. a failing automated regression test against the affected commit;
3. a sanitized replay, trace, request fixture, or crash artifact that deterministically distinguishes affected and fixed behavior;
4. strong production telemetry with a precise code path plus an independent reviewer-approved test oracle when local reproduction is impossible;
5. for an obvious documentation or static-content defect, an exact source reference and deterministic assertion.

The reproduction artifact records:

- affected commit, release, and environment;
- setup and commands;
- sanitized inputs;
- observed result;
- expected result;
- stability across repeated runs;
- test or artifact hash;
- limitations and unverified assumptions.

Rules:

- create or identify the failing test before applying the fix whenever practical;
- never encode real customer secrets or personal data in a fixture;
- do not treat a screenshot or free-form complaint alone as a sufficient oracle for a non-obvious code change;
- if evidence is insufficient, move to `Needs evidence` and produce one concise request for the missing reproduction, version, environment, or expected behavior;
- optional diagnostic instrumentation is a separate, reviewed change and cannot be mislabeled as the fix;
- inability to reproduce does not authorize speculative edits.

## 11.11 Automation modes and risk policy

### 11.11.1 Project mode

The project owner selects one mode:

| Mode | Behavior |
|---|---|
| `Off` | Store no maintenance source connection or disable processing. |
| `Observe` | Ingest, correlate, and display cases; create no tracker work or source write-back. |
| `Triage` | Classify, deduplicate, check coverage, request evidence, and maintain tracker links; create no patch automatically. |
| `Prepare patches` | Create verified maintenance work and pull requests for eligible cases; do not auto-merge or auto-deploy. Recommended default after setup. |
| `Guarded maintenance` | May merge and release low-risk fixes after all configured gates, history requirements, and Release 3 policy pass. Explicit opt-in only. |

New connections default to `Observe` until source health, project mapping, privacy settings, and a dry-run sample pass.

### 11.11.2 Risk classes

| Risk | Examples | Maximum automatic action |
|---|---|---|
| Low | typo, broken static link, narrow deterministic UI defect, isolated null handling with strong tests | Prepare patch; guarded merge/release only when explicitly enabled and certified. |
| Medium | bounded application logic, non-breaking dependency correction, localized performance or reliability defect | Prepare patch and review; merge requires policy and current evidence. |
| High | authentication, authorization, payments, billing, data integrity, concurrency, public API compatibility, migrations, infrastructure, cross-tenant behavior | Prepare a draft patch at most; human approval required for merge and release. |
| Critical | security incident, privacy breach, data loss, credential exposure, destructive migration, legal or compliance concern | No autonomous patch or public write-back; enter restricted human-led response. |

Risk classification may only become stricter automatically. Lowering a risk class requires an authorized, audited decision.

### 11.11.3 Policy controls

Per project or source:

- allowed signal types;
- included environments;
- severity and impact threshold;
- supported versions and backport policy;
- labels, repositories, services, components, and paths;
- automation mode;
- maximum active maintenance cases;
- maintenance token/time budget;
- emergency-lane policy;
- release freeze windows;
- auto-merge and auto-release eligibility;
- observation duration and evidence threshold;
- source write-back policy;
- customer-response template policy;
- data retention and privacy policy.

## 11.12 Scheduling, dependencies, and capacity

Maintenance work uses the same dependency graph, Work pace, quota guard, capacity leases, and change-surface conflict detection as planned work.

Scheduling considers:

- production versus non-production;
- regression introduced by the latest release;
- severity, affected users, event growth, and uptime impact;
- reproduction confidence;
- whether a rollback or feature-flag mitigation exists;
- dependency unlock value;
- active release and code freeze;
- existing work or patch coverage;
- supported-version policy;
- predicted file/module conflicts;
- maintenance budget and protected review/repair reserve;
- age and recurrence.

Rules:

- a newly deployed severe regression MAY enter one bounded emergency lane;
- emergency work may preempt only at safe checkpoints and never bypass validation or independent review;
- planned work must not starve because low-impact maintenance signals arrive continuously;
- duplicate reports do not consume additional run slots;
- one case cannot own several active patch attempts unless backports are explicitly separate work items;
- a dependency already being fixed is linked and awaited instead of reimplemented;
- if active work touches the same protected change surface, the scheduler adds a dependency, waits, or creates an explicit integration checkpoint;
- lowering Work pace prevents new maintenance admission but does not kill safe active attempts;
- provider limits enter the existing durable quota-wait flow and resume automatically after capacity returns.

## 11.13 Verified patch lifecycle

When a case is eligible, Studio creates a maintenance work contract containing:

- canonical defect statement;
- user impact and urgency;
- affected and unaffected releases/environments;
- exact reproduction or failure oracle;
- evidence and source references;
- existing coverage analysis;
- dependencies and conflicts;
- expected change surface;
- acceptance criteria;
- required tests and non-regression checks;
- risk class;
- release and backport targets;
- source write-back and observation policy;
- explicit non-goals.

The patch then uses the standard Symphony loop:

1. preflight current branches, release state, dependencies, and source revision;
2. reproduce against the affected commit;
3. plan the smallest complete fix;
4. implement in an isolated workspace;
5. run targeted and repository-required checks;
6. prove the reproduction now passes;
7. run a fresh independent review;
8. repair bounded findings and revalidate;
9. create or update a pull request;
10. link the maintenance case and source reports;
11. wait for CI, merge policy, and release policy;
12. attach complete evidence.

The pull request body includes:

- what failed and who was affected;
- reproduction evidence;
- root cause, when established;
- fix summary;
- tests and review;
- risk and rollback notes;
- affected releases and backport decision;
- linked source reports without leaking restricted data;
- `Fixes` or equivalent closing syntax only when source closure timing is correct for that tracker.

No maintenance agent may:

- close the case because the code changed;
- skip repository-wide required checks;
- merge around a release freeze;
- broaden scope into unrelated cleanup;
- modify production data to make the symptom disappear;
- suppress the source alert as a substitute for fixing the defect.

## 11.14 Release observation and regression handling

A merged fix normally moves to `Awaiting release`, not `Resolved`.

When the fix reaches an environment:

1. verify deployed release, artifact, and commit identity;
2. run the original reproduction or synthetic check against that environment when safe;
3. start the configured observation window;
4. monitor recurrence, event rate, affected users, health checks, latency, crash-free metrics, and rollback signals available from connected sources;
5. compare with the pre-fix baseline and minimum evidence threshold;
6. resolve only when the required evidence is sufficient.

An observation policy contains both:

- a minimum duration; and
- a minimum evidence threshold such as requests, sessions, events, synthetic runs, or explicit manual confirmation.

“No new events” on a low-traffic system is not automatically proof of a fix. When organic traffic is insufficient, require a synthetic reproduction, explicit verification, or a longer policy-defined window.

If the symptom returns in a release that should contain the fix:

- mark the case `Regressed`;
- reopen linked sources where supported and policy permits;
- preserve the prior patch and release evidence;
- create a new attempt linked as `regression_of` rather than rewriting the old history;
- evaluate rollback or feature-flag mitigation through Release 3 policy;
- notify configured users.

## 11.15 Source write-back

Source updates are concise, idempotent, and respectful of human ownership.

Supported updates may include:

- link to the canonical maintenance case;
- classification or needs-evidence status;
- duplicate or covered-by relation;
- patch pull request;
- awaiting-release status;
- deployed release and observation status;
- verified resolution or regression.

Rules:

- use one updateable status comment when the provider supports it instead of posting a new comment for every phase;
- namespace labels managed by Studio and do not remove unrelated human labels;
- never close a manually reopened report without new evidence and policy permission;
- never overwrite human-edited descriptions or comments;
- no public comment may include private repository paths, customer data, raw stack traces containing secrets, internal-only URLs, or hidden evidence;
- security and privacy cases receive no public automated response;
- if a source does not support safe write-back, Studio remains read-only and shows that state;
- source write failures never mark the Studio case resolved and are retried through the outbox.

## 11.16 Maintenance interface

Add one project navigation item: **Maintenance**.

Do not add separate top-level pages for every source or state. Use a focused workspace with three tabs:

1. **Cases**
2. **Sources**
3. **Policy**

### Cases

Default filters:

- New;
- Needs evidence;
- Covered;
- Fixing;
- Awaiting release;
- Monitoring;
- Regressed;
- Resolved.

Each row shows only:

- title;
- source icons;
- impact;
- environment and affected release;
- current state;
- coverage such as `Covered by PR #184`;
- last seen;
- owner or automated action.

Useful plain-language states:

```text
Needs steps to reproduce
Already covered by PR #184
Fixed on main · not released
Patch in review
Deployed · monitoring
Resolved in web-2026.07.16.1
Regressed after release
```

### Case detail

Show:

- defect and expected behavior;
- impact and recurrence trend;
- sanitized source signals;
- affected releases and environments;
- correlation proof and duplicate controls;
- existing work and fix coverage;
- reproduction and failing test;
- dependencies and conflicts;
- patch plan, run, diff, tests, review, and PR;
- release and backport status;
- observation evidence;
- source synchronization;
- audit history.

Actions, when valid:

- `Request details`;
- `Link existing fix`;
- `Prepare patch`;
- `Pause`;
- `Mark duplicate`;
- `Split reports`;
- `Mark not a bug`;
- `Require human review`;
- `Resolve with evidence`.

Every disabled action explains one concrete prerequisite. Technical source payloads stay behind `Details`.

### Sources

Show health, permission scope, last delivery, replay failures, mapping, privacy policy, and `Send test` or dry-run sample. Connecting a source requires a successful signature/capability test before activation.

### Policy

Use concise controls for mode, environments, risk, budget, backports, freeze windows, observation, and write-back. Show the effective policy and inherited project defaults; do not force users to reason about raw rule syntax.

## 11.17 Notifications

Release 6 uses Release 5 notification routing.

Default immediate notifications:

- severe new production regression;
- maintenance case requires credentials, evidence, or human risk approval;
- patch or verification failed after the bounded repair budget;
- a fix regressed during monitoring;
- guarded rollback was proposed or executed;
- security or privacy signal entered the restricted path.

Default digest events:

- low- or medium-impact case created;
- duplicate cluster growth;
- patch pull request opened;
- fix awaiting release;
- verified resolution.

Notifications use the case deduplication key so one error storm does not send one message per event.

## 11.18 Persistence and events

Add at minimum:

- `maintenance_sources`;
- `maintenance_source_deliveries`;
- `maintenance_signals`;
- `maintenance_cases`;
- `maintenance_case_signals`;
- `maintenance_case_relations`;
- `maintenance_coverage_links`;
- `maintenance_reproductions`;
- `maintenance_policies`;
- `maintenance_observations`;
- `maintenance_source_syncs`.

Raw deliveries and sensitive evidence use restricted artifact storage. Canonical projections contain only sanitized data needed by the product.

Required event families:

```text
maintenance.source.connected|disabled|health_changed
maintenance.delivery.received|verified|rejected|replayed
maintenance.signal.normalized
maintenance.case.created|updated|merged|split|classified
maintenance.case.coverage_found|coverage_invalidated
maintenance.case.needs_evidence|ready_for_fix
maintenance.reproduction.started|passed|failed
maintenance.patch.queued|started|pr_opened|failed
maintenance.release.awaiting|deployed|monitoring
maintenance.case.resolved|regressed|reopened
maintenance.source.write_queued|succeeded|failed
```

Events are project-scoped, replayable, idempotent, and redacted before broadcast.

## 11.19 Failure and recovery behavior

### Duplicate or replayed delivery

Return success after idempotently confirming the prior record. Create no new signal, case, comment, or notification.

### Source outage

Keep existing cases active, mark source freshness, use bounded backoff, and reconcile from the last cursor when service returns. Do not resolve based on stale data.

### Source credential revoked

Pause write-back and hydration for that source. Existing code work may continue only when its evidence remains sufficient and policy allows it.

### Release mapping missing

Show `Release unknown`, keep the case out of automatic resolution, and request deployment instrumentation or explicit mapping.

### Alleged existing fix becomes stale

Invalidate coverage when the pull request closes without merge, the commit is reverted, the release candidate changes, the reproduction fails again, or the source reports a newer affected release.

### Patch conflicts with active work

Checkpoint or wait according to dependency and change-surface policy. Do not open competing patches that modify the same behavior blindly.

### Monitoring source unavailable

Extend or pause the observation window. Do not interpret missing telemetry as success.

### Studio restart

Restore source cursors, case state, coverage links, maintenance leases, outbox writes, quota waits, observation timers, and monitoring baselines before admitting new maintenance work.

## 11.20 Security and privacy requirements

- least-privilege GitHub, Linear, Sentry, and webhook credentials;
- signature verification and timing-safe comparison;
- replay protection and bounded delivery age;
- project and installation mapping before hydration;
- no cross-project correlation using customer-derived content;
- encrypted credentials and restricted raw payloads;
- attachment MIME, size, decompression, and malware checks;
- outbound URL allowlists and SSRF protection;
- content provenance in every context record;
- prompt-injection resistance for report text, comments, logs, stack traces, and attachments;
- secret canaries through normalization, model context, logs, comments, PRs, notifications, and diagnostics;
- security reports kept private and excluded from ordinary public-source automation;
- retention and deletion propagate to derived signals where legally and technically required;
- audit every merge/split, classification override, policy change, source write, patch, release, and resolution.

## 11.21 Testing strategy

### Unit and property tests

Cover:

- webhook signature and replay validation;
- source normalization and capability degradation;
- PII and secret redaction;
- deterministic fingerprinting;
- duplicate merge/split reversibility;
- classification eligibility;
- coverage-state transitions;
- commit ancestry and release mapping;
- supported-version and backport policy;
- maintenance budget and fair scheduling;
- risk ceilings;
- observation-window evidence;
- idempotent source write-back.

Property invariants:

- one source delivery creates at most one immutable signal;
- an exact signal cannot belong to two active canonical cases;
- unrelated projects never share a case, fingerprint corpus, artifact, or source credential;
- a case with only `possible_coverage` is never suppressed as fixed;
- a case cannot resolve before the fix reaches the affected environment and observation evidence passes;
- a Critical case cannot enter autonomous patch, merge, or release;
- duplicate event storms remain bounded in work, notifications, and token use;
- source write retry cannot create duplicate comments or state transitions.

### Contract tests

- GitHub issue, comment, PR, check, release, deployment, signature, redelivery, and permission fixtures;
- Linear issue/comment/label/relation webhook, signature, timestamp, and retry fixtures;
- Sentry issue, feedback, event, release, regression, and capability fixtures;
- generic webhook schema versions and signature vectors;
- tracker and deployment correlation fixtures.

### Required end-to-end scenarios

1. A GitHub bug report matches an active pull request; Studio links it and creates no duplicate patch.
2. A Sentry production regression is reproduced, patched, reviewed, released, monitored, and resolved.
3. The default branch is fixed but production is not; the case waits for release instead of creating work.
4. Sentry feedback and a GitHub issue describe the same defect; one case contains both signals.
5. A feature request is classified into planning and never enters the patch loop.
6. An ambiguous complaint moves to `Needs evidence` with one concise request.
7. A report contains a secret and prompt injection; neither reaches Codex, logs, PR text, or source comments.
8. A webhook is replayed many times; one signal and one notification exist.
9. A fix conflicts with an active release change; dependency policy prevents parallel conflicting edits.
10. Codex quota is exhausted during a maintenance patch; the run checkpoints, waits, and resumes once.
11. A supposedly fixed issue recurs after deployment; the prior case becomes `Regressed` and preserves history.
12. A manually reopened source issue is not automatically reclosed without new release evidence.
13. A Critical security signal stays private and requires human action.
14. Studio restarts during monitoring and resumes the exact observation window without premature resolution.
15. Two projects use the same external fingerprint string and remain fully isolated.

## 11.22 Implementation work packages

| ID | Work package | Depends on | Exit condition |
|---|---|---|---|
| R6-01 | Canonical maintenance models, state machine, relations, events, and migrations | R2, R4, R5 | Projection rebuild and state/property suites pass. |
| R6-02 | Source behaviour, signed generic webhook, delivery store, redaction, and replay protection | R6-01 | Signature vectors, replay, privacy, and idempotency tests pass. |
| R6-03 | GitHub App maintenance connector | R6-02 | Issue/check/PR/release/deployment contract and E2E fixtures pass. |
| R6-04 | Linear maintenance connector and tracker write-back | R6-02 | Issue/comment/relation/signature/reconciliation tests pass. |
| R6-05 | Sentry issue, feedback, event, and release connector | R6-02 | Error/feedback/release/regression capability suite passes. |
| R6-06 | Correlation, reversible deduplication, and case clustering | R6-01–05 | Golden duplicate corpus and false-merge bounds pass. |
| R6-07 | Release/fix coverage graph, ancestry, active-work, dependency, and backport analysis | R3, R4, R6-06 | Already-fixed/in-progress/unreleased/backport scenarios pass. |
| R6-08 | Reproduction service, sanitized fixtures, evidence gate, and needs-evidence workflow | R6-06–07 | Reproduction corpus and privacy tests pass. |
| R6-09 | Risk policy, automation modes, maintenance budget, emergency lane, and scheduling | R5, R6-07–08 | Fairness, risk ceiling, freeze, conflict, and quota tests pass. |
| R6-10 | Standard Symphony patch-to-PR integration and source linking | R6-09 | Verified maintenance PR E2E passes with no weaker quality path. |
| R6-11 | Release observation, regression reopening, backport flow, and idempotent source write-back | R3, R6-10 | Deploy/monitor/resolve/regress/retry scenarios pass. |
| R6-12 | Maintenance UI, notifications, diagnostics, docs, security, load, and soak hardening | R6-01–11 | Accessibility, source-storm, isolation, clean-install, and soak gates pass. |

Implement in order. Do not start vendor adapters before R6-01 and R6-02 establish one secure contract.

## 11.23 Release 6 acceptance

Release 6 is complete only when:

1. GitHub, Linear, Sentry, and generic webhook sources pass their capability and contract suites.
2. Every accepted delivery is authenticated, replay-safe, idempotent, project-scoped, and redacted.
3. One underlying defect reported through several sources produces one canonical maintenance case without losing source provenance.
4. A model-only similarity guess cannot merge cases or suppress a patch.
5. The system distinguishes bug, regression, feature request, support, security, spam, and unknown cases.
6. Existing work, pull requests, commits, release candidates, deployments, dependencies, and backports are checked before new work is created.
7. A fix already in progress or fixed but unreleased does not produce a duplicate patch.
8. A new patch requires reproduction or an approved equivalent failure oracle.
9. The patch uses the same deterministic checks, independent review, bounded repair, evidence, quota, and context safeguards as planned work.
10. Low-, medium-, high-, and critical-risk ceilings are enforced and tested.
11. New connections begin safely in Observe mode and require a successful dry run before deeper automation.
12. Maintenance work respects Work pace, fair capacity, dependencies, file conflicts, release freezes, and protected review reserve.
13. A merged fix remains Awaiting release until the exact commit reaches the affected environment.
14. Resolution requires both an observation duration and sufficient evidence; low traffic cannot create false success.
15. Recurrence after a containing release reopens the case as a regression with full prior history.
16. Source updates are concise and idempotent and never override unrelated human edits or leak restricted content.
17. A source outage, Studio restart, quota wait, runner crash, or notification failure cannot duplicate work or prematurely resolve a case.
18. Security and privacy signals remain private and outside autonomous public patching.
19. The Maintenance interface is responsive, accessible, concise, and powered only by authoritative state.
20. All Release 1–5 quality, security, isolation, recovery, and evidence gates remain green.
21. Release 6 is automatically promoted, merged, tagged, published as `v6.0.0`, remotely verified, and reinstalled successfully after its connector, privacy, risk, load, release-observation, and regression gates pass.

---

# 12. Global guardrails

Across all releases:

- preserve Symphony at the core and keep upstream-compatible improvements small;
- remain Codex-only through Release 6;
- use GPT-5.6 meaningfully and preserve the tested model/effort contract;
- pin external protocol versions and generated schemas; do not guess request fields or capabilities;
- do not expose private chain-of-thought;
- do not treat motion as progress;
- do not show guessed, stale-without-label, or client-invented state;
- do not label estimates as facts;
- do not invent exact token, credit, currency, or subscription balances;
- do not encode a permanent quota-window duration or meaning for `primary`/`secondary` source slots;
- do show provider-reported percentage left, credits, and reset time only when available;
- do not interpret `No limits reported` as unlimited access;
- do not require manual resume after an ordinary timed quota reset;
- do not auto-resume a wait under a different or unverified Codex account;
- do not poll forever when a limit requires credits or operator action;
- do not auto-spend an earned reset credit in Release 1;
- do not send `/fast` as App Server user text or expose Fast when the selected model/account does not advertise a tested tier;
- do not combine Turn speed and Work pace into one control;
- do not let Work pace, optional helpers, or implementation traffic consume the protected quality lane;
- do not create duplicate durable claims, conductors, uncertain-outcome retries, wake-up turns, recursive helper swarms, or overlapping root writers;
- do not let an agent self-certify completion or directly mutate the managed Linear lifecycle;
- do not treat an external terminal tracker transition as verified completion;
- do not report completion before the deterministic tracker outbox confirms handoff;
- do not reuse evidence across a material issue-contract change;
- do not invalidate evidence merely because priority or blocker status changed;
- do not bypass deterministic checks or use stale review evidence;
- do not retry an identical deterministic, protocol, or unknown failure indefinitely;
- do not fabricate approval, consent, or user input;
- do not spawn agents for work deterministic code can perform;
- do not add a native todo list before Release 4;
- do not create Linear work before Release 2;
- do not deploy before Release 3;
- do not execute deployment commands through untrusted shell interpolation;
- do not add provider abstractions without a current need;
- do not add enterprise complexity before the single-user product is excellent;
- do not send routine progress to external notification channels by default;
- do not treat every feedback message, alert, or issue as a code defect;
- do not create a maintenance patch before source verification, correlation, coverage analysis, and reproduction or equivalent evidence;
- do not create a duplicate fix when active work or an unreleased commit already proves coverage;
- do not resolve a maintenance case merely because a pull request merged; require release and observation evidence;
- do not let model similarity alone merge maintenance cases or suppress work;
- do not expose customer data, secrets, private stack traces, or restricted evidence in prompts, public issues, pull requests, notifications, or diagnostics;
- do not autonomously patch, disclose, merge, or deploy Critical security or privacy incidents;
- do not allow maintenance storms to starve planned work, bypass Work pace, or consume protected quality capacity;
- do not auto-run irreversible production actions;
- do not begin work beyond `TARGET_RELEASE`; publish and verify every intermediate stage first;
- do not merge a release before all current exact-head checks pass or bypass a repository rule to make automation appear successful;
- do not wait for the demo video before publishing code that has passed the Release 1.1 source-release gate; record the final video only from the resulting stable tag/archive;
- do not commit, attach, or automatically upload raw/final submission media or upload credentials;
- do not store secrets in SQLite or release artifacts;
- do not make the dashboard required for core runner correctness;
- do not claim zero bugs, certainty about future external APIs, or guaranteed contest placement.

# 13. Release 1.1 submission and demo plan

## 13.1 Judge testing paths

Provide two paths. Both SHALL be available from a verified asset attached to the published `v1.1.0` GitHub Release on at least one supported platform so judges do not need to compile the project.

### Live path

For judges with Codex and Linear access:

```bash
tar -xf symphony-studio-<version>-<platform>.tar.gz
cd symphony-studio
./bin/studio setup
./bin/studio doctor
./bin/studio start
```

A source-build path remains documented for developers, but it is not the fastest judge path.

The guide provides environment variables, supported OS, sample `WORKFLOW.md`, expected Doctor output, and the one-time local browser pairing step printed by `./bin/studio start`.

### Recorded showcase path

```bash
tar -xf symphony-studio-<version>-<platform>.tar.gz
cd symphony-studio
./bin/studio showcase
```

Showcase mode:

- loads an anonymized, deterministic event fixture;
- is visibly labeled `Recorded showcase data`;
- disables runtime mutations;
- permits full navigation through all five routes;
- demonstrates the exact event/evidence shapes produced by live mode;
- never pretends to be a live Codex session.

## 13.2 External submission-media workspace

The demonstration video is a submission artifact, not product source. Raw recordings, narration, editing projects, generated intermediate files, and the final MP4 MUST remain outside the Symphony Studio Git repository and outside every Git worktree.

The repository tracks only reproducible text and automation:

```text
docs/submission/
├── DEMO_SCRIPT.md
├── SHOT_LIST.md
├── CAPTURE_MANIFEST.yaml
├── RECORDING_CHECKLIST.md
└── UPLOAD_CHECKLIST.md

scripts/submission/
├── prepare
├── capture
├── export
└── verify
```

The media root is selected through `STUDIO_SUBMISSION_ROOT`. The default is `$XDG_DATA_HOME/symphony-studio-submission` when `XDG_DATA_HOME` is set, otherwise `~/symphony-studio-submission`. It is intentionally a sibling of, not a child of, the application runtime-data root.

For the final release:

```text
$STUDIO_SUBMISSION_ROOT/v1.1.0/
├── source/                 exact release archive or detached clean worktree
├── captures/               raw browser and optional terminal recordings
├── audio/                  narration and approved sound assets
├── edit/                   editing project and intermediate files
├── exports/
│   └── openai-build-week-symphony-studio.mp4
├── captions/
│   ├── demo.srt
│   └── transcript.md
├── thumbnails/
│   └── youtube-thumbnail.png
├── upload/
│   ├── youtube-title.txt
│   ├── youtube-description.md
│   └── upload-checklist.md
├── submission-media-manifest.json
└── checksums.txt
```

Safety rules:

- `prepare` canonicalizes the requested path and rejects any path inside the repository, a linked worktree, `.git`, the runtime data root, or a release-packaging directory;
- the external workspace is created with owner-only permissions where the platform supports them and is excluded from Studio application backups, release archives, and automated uploads;
- cleanup is explicit and confirmation-gated; capture or export commands never delete raw media automatically;
- `.gitignore`, release-archive checks, and CI reject tracked `.mp4`, `.mov`, `.mkv`, `.webm`, raw audio, or editing-project binaries under the product repository unless an explicit future policy allows a tiny licensed asset;
- the external media directory is private by default and is not uploaded as a GitHub Release asset;
- capture starts from the exact published stable release tag or its verified release archive, not an uncommitted checkout or an unpublished candidate;
- the media manifest records release tag, commit SHA, archive checksum, scene hashes, capture timestamps, duration, dimensions, audio presence, caption files, redaction result, and export checksum;
- raw captures and final exports pass secret, token, private-name, issue-data, browser-history, notification, and metadata review;
- any scene showing live data uses a disposable or anonymized project;
- a bug discovered during recording is fixed through a new patch release and affected scenes are recaptured from that new tag.

The scripts SHOULD use Playwright's deterministic browser capture and FFmpeg or an equivalent local encoder when installed. They may assemble prepared live and showcase scenes, captions, narration, and a thumbnail, but they MUST NOT upload to YouTube automatically.

The owner manually performs the final public YouTube upload after watching the complete export. Automation prepares the title, description, captions, thumbnail, checksum, and upload checklist. After upload, the owner records the public URL in the external manifest and Devpost form. The repository does not need the final public URL to satisfy the submission. If the owner later chooses to add the URL or transcript to tracked documentation, that change follows the normal release train and ships as a new patch release; it MUST NOT leave untagged commits on `main` or include the video binary.

Code-release completion and submission completion are distinct:

- `v1.1.0` SHALL publish automatically as soon as its code, package, upgrade, security, accessibility, recovery, and release gates pass; final video production MUST NOT delay or become an input to the source-code merge;
- final capture and export begin from the exact published `v1.1.0` tag or its verified archive, so the video cannot accidentally depict unreleased code;
- the Build Week submission remains incomplete until the owner confirms the public YouTube URL and the final Devpost form is not a draft.

## 13.3 Three-minute demo structure

### 0:00–0:20 — Problem

- Show several Codex terminals or upstream-style run state briefly.
- Explain the context-switching, trust, and quota problem.
- State: `Symphony Studio turns existing Linear work into verified Codex outcomes.`

### 0:20–0:45 — Setup and real foundation

- Show the fork relationship and upstream base.
- Run or show Doctor.
- Highlight `GPT-5.6 Sol · Ultra` and Codex App Server.

### 0:45–1:25 — Live autonomous run

- Show an eligible Linear issue being claimed.
- Open Run Detail.
- Show the conductor plan.
- Show one bounded Explorer.
- Show file changes and real App Server events.

### 1:25–1:50 — Quota and memory

- Show percentage left, reset time, `Checks protected`, and the selected/effective Work pace.
- Show `Waiting for quota`, its resume countdown, and the automatic continuation path.
- Show a checkpoint and compaction/recovery audit.
- Explain why important state is not trusted to a summary.

### 1:50–2:25 — Verification

- Show deterministic checks.
- Show detached review finding a real issue.
- Show repair and revalidation.
- Show evidence becoming current.

### 2:25–2:50 — Outcome and impact

- Show final commit/PR and evidence manifest.
- Show History and a verified outcome.
- State the user impact.

### 2:50–3:00 — Build Week proof

- Show `BUILD_WEEK_DELTA.md`.
- State how Codex accelerated the build.
- State how GPT-5.6 powers the conductor, explorers, and review.

## 13.4 Recording rules

- public YouTube;
- under three minutes;
- English or English translation;
- clear voiceover;
- no copyrighted music or unlicensed assets;
- no secrets, private repository names, personal tokens, or sensitive issue data;
- record loading-free prepared paths;
- capture from the exact published stable release or a byte-identical verified archive;
- use real product behavior;
- keep every raw and final media file under `STUDIO_SUBMISSION_ROOT`, never in the repository;
- export captions and a transcript;
- strip unnecessary file metadata from the public export;
- do not speed the video until narration becomes difficult to understand;
- do not upload automatically; the owner watches and approves the complete final export first.

## 13.5 Final release checklist

- [ ] Official rules and FAQ rechecked on submission day.
- [ ] Deadline and Developer Tools category confirmed.
- [ ] Repository and release archive accessible to judges.
- [ ] `main`, the stable tag, GitHub `Latest`, candidate-manifest hash, and final release-manifest commit/tree hashes agree.
- [ ] Release branch was pushed, protected release PR auto-merged after all required checks, and no branch-protection bypass was used.
- [ ] Post-merge verification and remote asset-download verification passed.
- [ ] Prebuilt archive runs without compiling on every claimed supported platform.
- [ ] Upgrade from the previous stable release and the documented rollback/restore path pass.
- [ ] Release checksum is published and verified.
- [ ] License, upstream attribution, `UPSTREAM_BASE`, and Build Week delta are present.
- [ ] Exact Codex version, executable/schema hashes, compatibility matrix, and readiness manifest are attached.
- [ ] App Server transport/process conformance passes on the release package.
- [ ] GPT-5.6 Sol Ultra reference profile passes live capability validation.
- [ ] Work pace limits, helper depth/caps, quality lane, live pace decrease, and conflicting change-surface serialization pass.
- [ ] Dynamic quota buckets, removed-window replacement, credit/spend separation, and `No limits reported` copy pass.
- [ ] Quota wait/restart/latest-reset/exactly-once resume drill passes.
- [ ] Codex account-change wait drill blocks cross-account auto-resume.
- [ ] Durable-claim and uncertain `thread/start`/`turn/start` crash-window drills prove exactly-once reconciliation.
- [ ] Local pairing code expiry, single use, session revocation, Host/Origin validation, and CSRF protection pass.
- [ ] Issue-contract change and priority-only change drills pass.
- [ ] Model tracker-lifecycle mutation is denied; completion outbox retry/confirmation passes.
- [ ] Approval/input-required fail-closed flow passes.
- [ ] SQLite online backup, integrity check, clean restore, and artifact-hash verification pass.
- [ ] README setup succeeds on a clean machine.
- [ ] Judge guide is tested by another person or clean environment.
- [ ] Showcase mode is clearly labelled, read-only, and functional.
- [ ] `STUDIO_SUBMISSION_ROOT` resolves outside every repository and worktree.
- [ ] Repository and GitHub Release assets contain no raw capture, editing project, narration binary, or final video file.
- [ ] External media manifest binds the final export to the exact stable release tag, commit, and archive checksum.
- [ ] Final MP4, captions, transcript, thumbnail, upload copy, and checksums exist in the external submission workspace.
- [ ] Final export passed duration, audio, redaction, secret, metadata, and full-watch review.
- [ ] Demo is public, under three minutes, and uses clear voiceover.
- [ ] Voiceover explains the product, Codex, GPT-5.6, and the new Build Week work.
- [ ] Owner manually uploaded the reviewed export to YouTube, verified public playback, and recorded the URL in the external manifest and Devpost form.
- [ ] Primary `/feedback` Session ID is recorded.
- [ ] Live smoke and final tracker handoff pass.
- [ ] All required tests pass with no flaky required test.
- [ ] Accessibility and fresh-context UI copy reviews are recorded.
- [ ] Security and secret-canary scans pass.
- [ ] No P0/P1 or unwaived release-impacting P2 issue remains.
- [ ] Submission is not left as a draft.

# 14. Definition of project completion

The Build Week MVP is complete when a new user can take the fork, connect the same verified Codex identity and Linear project, pass the exact-version Doctor, choose a Work pace, and allow an existing issue to move through a GPT-5.6 Sol Ultra conductor without supervising a terminal.

The run must remain bound to an immutable issue contract, respect current eligibility and dependencies, use only enforceable optional-helper capacity, survive quota changes, account-safe reset waits, compaction, App Server restart, Studio restart, and tracker-sync retries, and preserve enough quality capacity for deterministic checks, independent review, and bounded repair.

The product is complete only when the final evidence manifest is current, the deterministic Linear handoff is confirmed, the outcome is understandable through the polished five-route control room, the clean-machine judge paths work, and every Release 1 acceptance criterion has attached proof.

Release 1 must then exist as a remotely verified `v1.0.0` GitHub Release. Release 1.1 must exist as a remotely verified `v1.1.0` GitHub Release, while its final demo media remains in the external submission workspace until the owner manually uploads the reviewed MP4 to YouTube.

Later releases are complete only when they preserve that standard, pass clean install and previous-release upgrade/rollback gates, and publish through the same protected automatic release train instead of weakening quality through added scope.

# 15. Verified references

The implementation team SHALL re-check these sources before relying on version-sensitive behavior:

- OpenAI Symphony repository: https://github.com/openai/symphony
- Symphony service specification: https://github.com/openai/symphony/blob/main/SPEC.md
- Symphony Elixir reference implementation: https://github.com/openai/symphony/tree/main/elixir
- OpenAI Symphony engineering article: https://openai.com/index/open-source-codex-orchestration-symphony/
- OpenAI harness engineering: https://openai.com/index/harness-engineering/
- OpenAI frontend design guidance: https://learn.chatgpt.com/blog/designing-delightful-frontends-with-gpt-5-4
- Codex App Server: https://developers.openai.com/codex/app-server/
- Codex models: https://developers.openai.com/codex/models/
- Codex speed and Fast mode: https://developers.openai.com/codex/speed/
- Codex subagents: https://developers.openai.com/codex/subagents/
- Codex hooks: https://developers.openai.com/codex/hooks/
- Codex skills: https://developers.openai.com/codex/build-skills/
- AGENTS.md guidance: https://developers.openai.com/codex/guides/agents-md/
- GPT-5.6 model guidance: https://developers.openai.com/api/docs/guides/latest-model/
- OpenAI Build Week overview: https://openai.devpost.com/
- OpenAI Build Week rules: https://openai.devpost.com/rules
- OpenAI Build Week FAQ: https://openai.devpost.com/details/faqs
- OpenAI Build Week update: https://openai.devpost.com/updates/45282-openai-build-week-submissions-are-open-plugin-launch
- GitHub auto-merge: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-auto-merge-for-pull-requests-in-your-repository
- GitHub merge queue and `merge_group` CI: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- GitHub protected branches and required checks: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- GitHub Actions token permissions: https://docs.github.com/en/actions/tutorials/authenticate-with-github_token
- GitHub release management: https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository
- GitHub webhook events and payloads: https://docs.github.com/en/webhooks/webhook-events-and-payloads
- GitHub issue forms: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms
- GitHub pull-request and issue linking: https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue
- Linear webhooks and signature verification: https://linear.app/developers/webhooks
- Sentry issue details and diagnostic context: https://docs.sentry.io/product/issues/issue-details/
- Sentry user feedback: https://docs.sentry.io/product/user-feedback/
- Sentry alerts: https://docs.sentry.io/product/alerts/
- Sentry releases and release health: https://docs.sentry.io/product/releases/

When this specification conflicts with the pinned generated App Server schema, the schema controls request shape and the conflict blocks the compatibility manifest until this specification or adapter is reconciled. Current official documentation controls documented capability semantics. When this specification conflicts with the Build Week Official Rules or Devpost website, the Official Rules and website prevail.
