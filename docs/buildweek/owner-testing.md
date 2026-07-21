# Build Week Preview owner testing

This is the fail-closed owner and judge verification path for the clearly
labelled Symphony Studio Build Week Preview. A passing harness contract proves
only that the verification oracles work. The preview is ready only when the
live golden path, state matrix, clean launch, public-artifact audit, and final
review all pass against one committed candidate.

## Current support boundary

- Candidate platform: Linux x86_64 with the containment capabilities listed in
  `elixir/README.md`. Other platforms are unverified and preflight blocks them.
- Runtime: the repository-pinned Erlang 28, Elixir 1.19.5-otp-28, Codex CLI
  0.144.3, Python 3.10 or newer, Node.js 18 or newer, and Chromium installed by
  Playwright.
- Network surface: loopback HTTP only. The owner preview command rejects a
  non-loopback or credential-bearing URL.
- Data and evidence: an owner-owned mode-0700 directory outside every Git
  worktree. Handoff files are owner-owned mode-0600 regular files outside Git.
- Tracker: the dedicated Symphony Studio project and team `SYM`. The R0
  fixtures `SYM-1` and `SYM-2` are permanently excluded from demo/reset logic.

Linux x86_64 remains a candidate, not a published support claim, until the
clean-launch command below passes on the exact preview release commit.

## Install verification dependencies

From the repository root:

```bash
mise trust
mise install
cd tests/preview/browser
npm ci
npm run install-browser
cd ../../..
python3 -m unittest -v tests.preview.test_preview_cli
npm --prefix tests/preview/browser run test:contract
```

The locked browser test dependencies are `@playwright/test` 1.61.1,
`@axe-core/playwright` 4.12.1, and `pngjs` 7.0.0. `npm ci` must use the committed
lockfile; do not update these packages during candidate verification.

## Preflight and launch

The read-only owner path requires no Linear credential and no browser pairing.
The application binds to loopback and its verification endpoint is GET-only.
Never put a raw credential, browser storage state, or protected
environment-file path in shell history, Git, screenshots, evidence, or a
command argument. Live task publication remains disabled unless the separate
preview-write credential contract is satisfied and the protected R0 query
authority is simultaneously available for the in-memory distinctness check.

Run the non-secret preflight:

```bash
./scripts/preview/run preflight --live --json
```

Launch the production runtime on loopback:

```bash
./scripts/preview/run launch --live-preflight --port 4000
```

Open `http://127.0.0.1:4000/setup`. The launcher uses the production Symphony
runtime and the committed workflow; it does not start a demo-only application.
Keep the terminal open while testing.

## Verification modes

### Harness contract (safe at any time)

```bash
npm --prefix tests/preview/browser run test:contract
```

This executes only negative and positive controls for the screenshot oracle
and fixture guards. It performs no Linear or Studio mutation.

### Read-only owner route check

With the runtime still open in the first terminal, run in a second terminal:

```bash
SYMPHONY_PREVIEW_BASE_URL=http://127.0.0.1:4000 \
  npm --prefix tests/preview/browser run test:owner-readonly
```

This credential-free suite verifies the real Setup, Mission Control, and Run
Detail routes at desktop and mobile widths, reads the authoritative projection,
checks keyboard focus, runs WCAG A/AA automated checks, and fails on browser
console, page, or request errors. If no run has been admitted, Mission Control
truthfully renders its empty state instead of inventing completion.

The broader state matrix runs after the live golden path creates a private
handoff. It verifies reconnect replay and the current production state domain
(`active`, `queued`, `blocked`, `validating`, `reviewing`, `completed`, and
`incomplete`) at 1440, 1024, 390, and 360 CSS-pixel widths. It also verifies an
explicit unavailable-run failure route. A state the real run never enters has
no synthetic fixture: missing authoritative run evidence is reported as
`BLOCKED`, never counted as passing.

### One explicitly authorized live golden path

The live mode publishes the approved 3-5 task proposal and starts its first
ready task. Run it only with the dedicated, separately scoped preview-write
authority and the exact acknowledgement:

```bash
./scripts/preview/run verify \
  --base-url http://127.0.0.1:4000 \
  --live-write \
  --live-write-ack publish-one-dedicated-demo-issue \
  --json
```

The test proves this order from the authoritative Studio projection:

1. inspect the current project and submit the safe owner-intent fixture;
2. answer no more than two high-value questions;
3. inspect 3-5 proposed tasks and side effects with zero Linear writes;
4. explicitly approve duplicate-free, idempotent Backlog publication;
5. start the first ready task and observe Symphony admission;
6. observe the requested GPT-5.6 Sol Ultra policy, then require exact-current-
   attempt runtime evidence before claiming the effective model and effort;
7. accept completion only after required checks, detached review, current
   sealed evidence, delivery reference, and confirmed tracker handoff.

The test writes a private handoff and screenshot/evidence records under the
external preview data root. It never stores credentials or browser state there.

The local STDIO MCP integration is intentionally limited to attach, submit,
answer, present, and status. It cannot approve, publish, or start work. Perform
those three human-authority actions only through the trusted local Studio UI;
then use MCP status to observe the same canonical intent state.

## Deterministic demo and reset

The committed demo intent is
`tests/preview/fixtures/owner-intent.md`. It asks for a small, visible,
keyboard-accessible copy-evidence-hash action with focused deterministic tests.
It forbids credentials, authentication, persistence, migrations,
infrastructure, tracker lifecycle, and broad layout work.

Reset is deliberately local-only and requires both the dedicated demo issue
identifier and the exact canonical `intent_id` returned by
`studio_submit_intent` or `studio_get_intent_status`. The ID has the persisted
shape `intent_` followed by 24 lowercase hexadecimal characters; a friendly
label is not a safe storage selector.

Stop the preview runtime before reset so its process-local event projection is
discarded and the Intent Store is not concurrently active. Then run:

```bash
./scripts/preview/run reset \
  --issue SYM-<dedicated-demo-number> \
  --intent-id intent_<24-lowercase-hex-characters> \
  --dry-run \
  --json

./scripts/preview/run reset \
  --issue SYM-<dedicated-demo-number> \
  --intent-id intent_<24-lowercase-hex-characters> \
  --json
```

The first command must pass before the second is considered. It inventories the
bounded owner-only store before sorting, validates exactly one intent document,
and requires its selected start task to bind the same issue ID and identifier.
Missing, ambiguous, malformed, symlinked, oversized, or fixture-bound data
fails closed before removal. `SYM-1` and `SYM-2` are rejected unconditionally.

The second command atomically quarantines and deletes only the exact intent
document plus any prior receipt bound to the same issue and intent. It then
publishes a mode-0600 local receipt containing `linearMutations: 0`. The reset
path uses only bounded local filesystem operations after the existing Git
worktree-boundary check; it invokes no Linear client and performs no network
operation. It does not remove the attached project, general logs, or evidence;
process-local run projection is cleared by the required runtime restart. It
never moves, edits, deletes, comments on, or otherwise mutates a Linear issue,
and it cannot reverse Linear history. Restart the preview after the receipt is
written.

## Candidate gates

Run these once on one coherent, committed preview candidate:

```bash
python3 -m unittest -v tests.preview.test_preview_cli
npm --prefix tests/preview/browser run test:contract
./scripts/preview/run audit --json
./scripts/preview/run clean-launch --execute --json
```

Then run the live golden path and state matrix once, followed by the required
fresh independent review and checksum/provenance record. A material repair
requires the affected targeted checks and one final coherent candidate gate;
cosmetic findings do not justify repeating external work.

The audit scans tracked and candidate-untracked public files for secret-shaped
content, protected browser material, local developer paths, oversized files,
and submission media. It excludes dependency/build directories and permits
only the exact, hash-pinned upstream Symphony demo video already present in the
locked base. Any changed or additional video/audio/editor file fails.

The clean-launch gate archives exact `HEAD`, extracts into a private temporary
directory with link/traversal rejection, audits it, builds it with an isolated
home and empty memory tracker, starts the production loopback runtime, reads
its authoritative state endpoint, and terminates the process group. It uses no
Linear credential and performs zero external mutation.

## Manual owner checklist

- Setup truthfully identifies the repository, dedicated Linear project, Codex
  authentication, pinned compatibility, requested GPT-5.6 Sol Ultra policy,
  separately attested effective runtime selection when available, and any
  blocker. A missing dependency does not render as ready.
- New Work accepts the Markdown intent, asks at most two useful questions,
  shows 3-5 tasks and exact side effects, and performs no write before approval.
- Reloading or repeating approval does not duplicate Linear issues.
- The first published issue begins in Backlog and moves into Symphony admission
  only after the explicit Start action.
- Mission Control shows identifier, objective, real phase, elapsed time,
  meaningful activity, genuine usage when available, and next action/blocker.
- Run Detail shows objective, criteria, plan, commands, changed files, checks,
  independent review, evidence, delivery reference, and the exact complete or
  incomplete reason.
- Disconnect/reconnect shows `Reconnecting`, then replays the authoritative
  sequence without inventing progress.
- Tab and Enter reach and activate the primary route actions at desktop and
  mobile widths; focus is visible; no essential content clips or overlaps.
- Every state produced by a real run remains visually distinct and matches the
  authoritative probe for the same run ID; an unavailable run renders an
  explicit failure and never completion.
- Browser console errors, uncaught page errors, unexpected failed requests,
  axe violations, black/transparent screenshots, and missing state evidence
  fail or explicitly block the suite.
- No credential, storage state, private path, raw response, recording, or
  thumbnail appears in Git, release assets, screenshots, or evidence.

## Required application integration contract

The production application provides a loopback-only, read-only
`GET /api/preview/v1/verification` composite projection backed by the Symphony
orchestrator, Intent Store, and runtime EventSink. It returns schema version 1,
`authoritative: true`, `mode: "live"`, `source: "symphony_runtime"`, the exact
dedicated project/team, dependency readiness, intent/publication/start state,
run truth, and optional authoritative run IDs for state coverage.

The live golden path additionally requires production routes `/work/new`,
`/setup`, `/mission-control`, and `/runs/:run_id`, plus stable accessible names
and `data-testid` hooks defined in the Playwright specs. These hooks are test
contracts only; they must expose the same state rendered to the owner and must
not create a second fixture or mock-success data source.

The local reset integration point is `./scripts/preview/run reset`. It operates
directly on the owner-only `<data-root>/intent` Store boundary and requires the
exact persisted intent ID plus selected issue binding. Its strict zero-mutation
receipt, ambiguity guards, bounded inventory, and stale-runner launch guard are
tested in `tests/preview/test_preview_cli.py`.
