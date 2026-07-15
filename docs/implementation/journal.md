# Implementation journal

## 2026-07-14 — R0 preflight and R0-01 start

### Decisions

- Recorded the user-selected `TARGET_RELEASE=R1.1` before advancing beyond the
  first package. The run stops after verified v1.1.0 and external media prep.
- Locked upstream base to `4cbe3a9699a73b862466c0b157ceca0c1985d6d7`, the exact current `openai/symphony/main` commit observed before edits.
- Kept upstream root `SPEC.md` intact and imported the product contract as
  `STUDIO_SPEC.md`.
- Provisioned `farhaanlevy/symphony-studio` as a real GitHub fork because the
  required named fork did not exist. This was the unavoidable provisioning
  write; immediately afterward all fork identity and governance checks were
  performed before any release-branch push.
- Disabled the local upstream push URL, enabled only merge commits and
  auto-merge in the fork, and protected `main` with a zero-human-approval pull
  request rule plus strict `studio/release-gate` and administrator enforcement.
  Bound that check to GitHub Actions app ID `15368`, set the repository Actions
  token default to read-only, disabled workflow PR approval, and required full
  action commit-SHA pinning.
- Treat the inherited timing and terminal-width failures as upstream baseline
  debt. R0-01 remains open until a minimal Class A deterministic-test hardening
  change makes the full original suite green; the red baseline is not waived.
- Resolved the live-base contradiction as `ADAPT-R0-01-001`: retain the exact
  current upstream SHA and original 241-test command/inventory, while permitting
  a Class A test-only hermeticity patch because the exact untouched SHA is red
  in upstream CI. No test is removed, renamed, skipped, or weakened; an older
  base or shell-level network mask would provide less truthful evidence.
- Keep the currently authenticated interactive GitHub credential outside all
  automation. Candidate and publication workflows will use job-scoped minimum
  `GITHUB_TOKEN` permissions.
- Use the existing disposable Linear project `Symphony Blank Test` for later
  smoke tests. Runtime Linear authentication is not yet present locally, so no
  live runtime claim is made.

### Failed approaches and adaptations

- The first classic branch-protection API payload included an empty
  `bypass_pull_request_allowances` object. GitHub rejected it with HTTP 422
  because user-owned repositories cannot configure organization user/team
  restrictions. Retrying without that object succeeded; no bypass actor is
  configured.
- Untouched `make all` initially exposed two dashboard assertions that depend
  on pseudo-terminal width and two retry assertions whose lower bound is
  consumed by synchronous real Linear polling. Increasing `COLUMNS` repaired
  only the rendering assertions. Serializing the timing tests did not repair
  the retry assertions, ruling out ordinary test concurrency as the root cause.

### Evidence

- Preflight: `docs/releases/v0.1.0/preflight.md`
- Untouched baseline: `docs/releases/v0.1.0/upstream-baseline.md`
- Fork policy and ledger: `docs/architecture/`
- R0-01 checkpoint: `docs/implementation/checkpoints/R0-01.md`

### R0-01 validation result

- Focused dashboard semantic tests: pass at `COLUMNS=40` and `COLUMNS=240`.
- Focused retry scheduling tests: pass serially at seeds 11, 22, and 33.
- `COLUMNS=80 mise exec -- make all`: pass; 241 tests, zero failures, two
  skips, 100% reported coverage, Credo clean, public specs complete, Dialyzer
  zero errors.
- Credential-pattern scan: clean.
- Root `SPEC.md`, `LICENSE`, and `NOTICE`: byte-identical to `UPSTREAM_BASE`.
- `STUDIO_SPEC.md`: byte-identical to the attached product specification.
- Test declaration inventory in the two modified upstream files: 91 before and
  after, normalized SHA-256
  `ac8d1f10500174124dbd65ca130cca5e673dadac2bdd8a1c62863f36d284f513`.

### Unresolved risk

- Independent R0-01 review initially found inaccurate spec anchors, missing
  target/license notices, a weak ANSI oracle, stale checkpoint facts, unsafe
  local main tracking, and required-check self-spoofing. All findings were
  repaired or explicitly resolved; the re-review reported no remaining blocker.
- R0-01 is accepted. Its containing commit and matching
  `origin/release/v0.1.0` ref form the durable checkpoint seal.
- `studio/release-gate` is configured as required but cannot report until its
  R0-07 workflow exists.
- A runtime Linear API credential is absent. Deterministic fake-based R0 work
  can proceed; live Linear smoke and release readiness cannot be declared until
  a supported credential path is configured and redaction-tested.

## 2026-07-14–15 — R0-02 implementation and acceptance

### Decisions

- Pin the currently installed `codex-cli 0.144.3` and retain stable plus
  experimental JSON Schema and TypeScript generator output.
- Compare generated JSON semantically because the generator emits
  nondeterministic object-member order in its aggregate V2 schema; compare
  TypeScript byte-for-byte and preserve all raw generated files.
- Separate R0-02 schema-presence evidence from R0-06 runtime capability proof.
- Replace line-count App Server fakes with a strict method/ID scenario runner
  and add a stateful, loopback-only fake Linear service exercised through the
  real client and adapter.
- Remove the real Linear endpoint from ordinary generated test workflows.
- Treat the generated schema as the production outbound-request contract:
  remove invented initialization/turn fields, add required dynamic-tool type,
  normalize approval policy to Codex 0.144.3's granular representation, send
  only schema-defined callback denials under `never`, and accept only the four
  exact tagged turn-sandbox variants with validated values.
- Expand the static compatibility matrix across lifecycle correlation, quota,
  dynamic-tool response, sandbox/network, callback, and deprecated/ignored
  collaboration fields. Bind its full semantic content with one canonical hash
  while keeping runtime capability claims deferred to R0-06.
- Bind fixture compatibility evidence to an immutable private snapshot of its
  exact source/schema inputs and fixed nonzero test count. The pre-test record
  is deliberately non-publishable, and an external lock plus identity fences
  serialize generation, verification, sealing, and rollback.

### Evidence

- Package checkpoint: `docs/implementation/checkpoints/R0-02.md`
- Installed launcher and native executable hashes are recorded in that
  checkpoint.

### R0-02 validation result

- Stable plus experimental JSON/TypeScript generation: 1,873 generated files.
- Artifact bundle SHA-256:
  `d96f8d427cf68655b5658ebea0e9e2332986e8b4b9c1f0ff078957e2ceb70d69`.
- JSON schema bundle SHA-256:
  `5044e15b8aa187e7deec44ee16b0848a4f9a20aa25e6ec66f10c1d5bcc40141a`.
- Method/field matrix SHA-256:
  `f102c992bc99faaa7442f1bc22b6f41cce70e0f1a5d2ba56e99a8dabafdd8b25`;
  canonical semantic lock
  `c0d1c5bfaa5105a9a785b44858767c999f5f3462490366778a1f5f933daabf24`.
- Compatibility manifest SHA-256:
  `aae61687688aa20d3d9ed5307c0c38fffceb6f62888b577482c42b9dcc594782`.
- The matrix validates 43 methods, 302 fields, six cross-schema definition
  equalities, and three negative capabilities against exact stable or
  experimental request/notification schema bindings.
- Installed-pin verification and clean semantic/raw regeneration: pass.
- Source-bound deterministic fixture suite: 71 bound files and 55 tests, zero
  failures at seeds 0 and 42; sealed source SHA-256
  `4a59a423518e2db4f92bb4f0ba36a90d23eec851034e19bfb217ef584f54309e`.
  Fixture execution is dated `2026-07-15`; schema generation remains dated
  `2026-07-14`.
- Exact Python schema-tool runner: 67 tests, zero failures, including its real
  private-snapshot Mix gate.
- Fake App Server final-trace race and WorkflowStore supervisor-ownership stress
  loops: 10 consecutive passes each.
- Complete ExUnit suite: 266 tests, zero failures, two opt-in skips at the
  formerly failing seed `792883`.
- `COLUMNS=80 mise exec -- make all`: pass end to end at coverage seed
  `752982`; build, format, specs, strict Credo, 67 schema-tool tests, installed
  verification, regeneration, 266 ExUnit tests, 100.00% measured coverage, and
  Dialyzer with zero errors are all green.
- Independent adversarial reviews closed the fake App Server terminal-failure
  path, fixture/seal integrity, production compatibility refactors, and the
  final coverage repair with no remaining P0/P1 finding. They also confirmed
  that canonical remote-root/symlink containment is explicitly deferred to
  R0-05 rather than claimed by R0-02.

### R0-02 failed approaches and adaptations

- The first fixture seal could verify a fresh seal but could not refresh a
  valid stale seal after an evidence-source edit. Preflight now permits stale
  evidence only inside `seal-fixtures`; the command then reruns the fixed suite
  and ordinary verification again requires the exact current source hash.
- The first full gate reported 99.58% coverage because two granular approval-
  policy validation branches were untested. A pinned-contract test now covers
  valid granular flags and non-map rejection; total coverage is again 100%.
- A later full gate correctly stopped at 98.69% after sandbox-policy helpers
  were refactored. Six meaningful deny/optional branches gained behavioral
  assertions; one duplicate remote-path error arm was removed only after two
  independent reviews proved it unreachable behind the identical immutable
  pre-validation. Fresh full coverage is 100.00% without lowering or excluding
  the measured module.
- An attempted lexical remote-root containment patch was rejected before seal:
  it broke preserved `~/.…` SSH roots and still could not prove remote canonical
  or symlink containment. Only the pinned-contract absolute/normalized returned
  workspace check remains in R0-02; canonical remote containment stays in the
  R0-05 workspace-hardening boundary.
- Randomized full-suite validation exposed a detached WorkflowStore mistaken
  for a supervised restart. The test now synchronously stops the detached
  process and requires a real supervisor-owned child; shared setup/teardown
  repairs that invariant only after restoring the loopback memory workflow.
  Invalid-config tests stop the Orchestrator so its immediate tick cannot
  exhaust supervisor restart intensity on a transient invalid file.

### Remaining package boundary

- The fixture can model stderr, fragmentation, malformed output, overload,
  exit, and uncertainty, but current App Server transport conformance is not
  claimed. R0-03 must separate stderr, remove the one-megabyte line boundary,
  enforce limits/timeouts/ID rules, and prove process-group cleanup.
- Live account/model/quota/tier/identity/multi-agent behavior remains
  `pending_r0_06`; generated schema presence is not live capability evidence.
