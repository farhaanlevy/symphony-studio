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
  worktree. Browser state and handoff files are owner-owned mode-0600 regular
  files outside Git.
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

First provision the preview through the repository's protected credential and
local-pairing procedures. Never put a raw credential, browser storage state, or
protected environment-file path in shell history, Git, screenshots, evidence,
or a command argument.

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

The required browser pairing state must be exported by the application to an
owner-only mode-0600 file outside all repositories. This verifier does not
manufacture, weaken, or bypass pairing.

## Verification modes

### Harness contract (safe at any time)

```bash
npm --prefix tests/preview/browser run test:contract
```

This executes only negative and positive controls for the screenshot oracle
and fixture guards. It performs no Linear or Studio mutation.

### Read-only state matrix

Use the application-produced paired browser state:

```bash
./scripts/preview/run verify \
  --storage-state /absolute/outside-git/paired-browser-state.json \
  --base-url http://127.0.0.1:4000 \
  --json
```

The suite verifies Setup, Mission Control, Run Detail, keyboard operation,
WCAG A/AA automated checks, reconnect replay, and loading, blocked, failure,
and completed truth at 1440, 1024, 390, and 360 CSS-pixel widths. Missing
authoritative state fixtures are reported as `BLOCKED`; they are never counted
as passing.

### One explicitly authorized live golden path

The live mode publishes the approved 3-8 task proposal and starts its first
ready task. Run it only with the dedicated, separately scoped preview-write
authority and the exact acknowledgement:

```bash
./scripts/preview/run verify \
  --storage-state /absolute/outside-git/paired-browser-state.json \
  --base-url http://127.0.0.1:4000 \
  --live-write \
  --live-write-ack publish-one-dedicated-demo-issue \
  --json
```

The test proves this order from the authoritative Studio projection:

1. inspect the current project and submit the safe owner-intent fixture;
2. answer no more than three high-value questions;
3. inspect 3-8 proposed tasks and side effects with zero Linear writes;
4. explicitly approve duplicate-free, idempotent Backlog publication;
5. start the first ready task and observe Symphony admission;
6. observe an isolated GPT-5.6 Sol Ultra run in Mission Control and Run Detail;
7. accept completion only after required checks, detached review, current
   sealed evidence, delivery reference, and confirmed tracker handoff.

The test writes a private handoff and screenshot/evidence records under the
external preview data root. It never stores credentials or browser state there.

## Deterministic demo and reset

The committed demo intent is
`tests/preview/fixtures/owner-intent.md`. It asks for a small, visible,
keyboard-accessible copy-evidence-hash action with focused deterministic tests.
It forbids credentials, authentication, persistence, migrations,
infrastructure, tracker lifecycle, and broad layout work.

Reset is deliberately local-only and requires both the dedicated demo issue
identifier and the intent idempotency key:

```bash
./scripts/preview/run reset \
  --issue SYM-<dedicated-demo-number> \
  --intent-key buildweek.copy-evidence-hash \
  --dry-run \
  --json

./scripts/preview/run reset \
  --issue SYM-<dedicated-demo-number> \
  --intent-key buildweek.copy-evidence-hash \
  --json
```

The first command must pass before the second is considered. The authoritative
reset driver must return a strict receipt with `linearMutations: 0`; otherwise
the wrapper fails and publishes no receipt. `SYM-1` and `SYM-2` are rejected
before the driver launches. Reset removes only local preview projections and
idempotency state. It does not move, edit, delete, comment on, or otherwise
mutate any Linear issue.

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
  authentication, pinned compatibility, GPT-5.6 Sol Ultra policy, and any
  blocker. A missing dependency does not render as ready.
- New Work accepts the Markdown intent, asks at most three useful questions,
  shows 3-8 tasks and exact side effects, and performs no write before approval.
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
- Loading, blocked, failure, and completed routes remain visually distinct and
  match the authoritative probe for the same run ID.
- Browser console errors, uncaught page errors, unexpected failed requests,
  axe violations, black/transparent screenshots, and missing state evidence
  fail or explicitly block the suite.
- No credential, storage state, private path, raw response, recording, or
  thumbnail appears in Git, release assets, screenshots, or evidence.

## Required application integration contract

The verifier intentionally blocks until the production application provides a
paired, read-only `GET /api/preview/v1/verification` projection backed by the
Studio store. It must return schema version 1, `authoritative: true`,
`mode: "live"`, `source: "studio_store"`, the exact dedicated project/team,
dependency readiness, intent/publication/start state, run truth, and optional
authoritative fixture run IDs for state coverage.

The live golden path additionally requires production routes `/work/new`,
`/setup`, `/mission-control`, and `/runs/:run_id`, plus stable accessible names
and `data-testid` hooks defined in the Playwright specs. These hooks are test
contracts only; they must expose the same state rendered to the owner and must
not create a second fixture or mock-success data source.

The local reset integration point is executable `elixir/bin/studio preview
reset ... --local-only --json`. Its strict receipt schema is tested in
`tests/preview/test_preview_cli.py`. Until that driver exists, reset reports
`BLOCKED`, not success.
