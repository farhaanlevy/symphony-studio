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
  valid granular flags and non-map rejection; reported measured-module
  coverage is again 100%.
- A later full gate correctly stopped at 98.69% after sandbox-policy helpers
  were refactored. Six meaningful deny/optional branches gained behavioral
  assertions; one duplicate remote-path error arm was removed only after two
  independent reviews proved it unreachable behind the identical immutable
  pre-validation. Fresh reported measured-module coverage is 100.00% without
  lowering the threshold or excluding that module.
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

## 2026-07-15–16 — R0-03 implementation and acceptance

### Decisions

- Preserve Symphony's App Server runner while replacing the mixed line-buffered
  boundary with strict bounded JSONL framing, a separate bounded content-free
  stderr channel, exact response correlation, absolute monotonic deadlines,
  and typed transport failures.
- Retry JSON-RPC overload `-32001` only for an explicit idempotent-read
  allowlist. Prepared in-memory operation envelopes and canonical request
  hashes prevent blind replay once transmission may have occurred; durable
  operation persistence and crash reconciliation remain owned by R1-07.
- Persist a small source-identity-bound `0600` compatibility-circuit marker
  after protocol corruption, and reject stale/unsupported remote-worker
  configuration before SSH or process side effects.
- Vendor erlexec 2.3.4 as an offline path dependency. Its downstream patch is
  build-only: safe native-output paths for this checkout and removal of
  publisher/documentation plugins. Runtime source and the complete shipped
  license remain intact.
- Use util-linux user/PID/mount namespaces plus a two-stage target barrier.
  Capture the outer group and exact blocked namespace root/target before
  releasing target code; send only the bounded target environment; keep
  pidfd-bound cleanup authority; and accept cleanup only when the linked
  manager is absent, anchored group membership is empty, and the exact root is
  retired.
- Bind fixture and transport-conformance states to one atomic source seal while
  leaving runtime capability evidence `not_run` and overall readiness
  `pending_r0_06`.
- Keep the coverage threshold at 100% for measured modules. R0-03 adds explicit
  line-instrumentation exclusions for five structural process/transport
  modules that depend on opaque OS ports, PIDs, namespaces, or GenServer
  scheduling; they are covered by direct deterministic and adversarial suites.
  Pre-existing exclusions remain separately visible in `mix.exs`.

### Validation result

- Final fixture seal: 113 source files, 276 tests at seed 0, zero failures;
  source SHA-256
  `fc44e9692d6f443256ee304ae7ccd9df8e7267eaa1e5d453648956143eb47f91`;
  manifest SHA-256
  `8779fd265fcf16c73535e4638110637aceec4afb2934dbaf487236f58efc164e`.
  The same 276-test fixture suite passes at seed 42 with zero failures in 158.4
  seconds.
- Compatibility evidence is exactly `fixtures=pass`,
  `transportConformance=pass`, `runtimeCapabilities=not_run`, and
  `overall=pending_r0_06` for Codex 0.144.3.
- The schema verifier confirms 1,873 artifacts, artifact bundle SHA-256
  `d96f8d427cf68655b5658ebea0e9e2332986e8b4b9c1f0ff078957e2ceb70d69`,
  and schema bundle SHA-256
  `5044e15b8aa187e7deec44ee16b0848a4f9a20aa25e6ec66f10c1d5bcc40141a`.
  Installed-pin verification and a clean raw/semantic regeneration pass.
- The exact 24-file erlexec inventory is independently bound as repository-
  path-prefixed SHA-256
  `df41fcbc2eb8b06bb1bae60386a8b9273cc6bc25b4e16a45a30c7a9b8dc7b4b2`
  and as the schema tool's vendor-root-relative 317,091-byte proof SHA-256
  `604b313f10bd73f5da0a509e0ea8c5517a29a343bc6e821c38d39c7a9e74c539`.
- The Python schema-tool runner passes all 73 tests in 335.035 seconds,
  including the real private-snapshot Mix gate.
- `cd elixir && mise exec -- make all` passes end to end: build, format,
  public-spec enforcement, strict Credo on 79 source files, 398 ExUnit tests in
  170.9 seconds with zero failures and two intentional skips (the credentialed
  live E2E opt-in and the Release 5 remote-worker live path), 100.00% of
  measured modules at coverage seed `992638`, and Dialyzer with zero errors,
  zero skips, and no warning suppression.
- A real Codex 0.144.3 production-adapter smoke completes only initialize,
  metadata inspection, and close, then proves target/root/wrapper retirement.
  It starts no thread or turn and consumes no model quota.
- Cleanup stress includes ProcessAdapter seeds 0 and 42, 100 TERM-resistant
  hostile-descendant iterations, and 100 exact teardown-race replays.
- Independent reviews of transport, process containment, cleanup evidence,
  compatibility-circuit behavior, coverage policy, Dialyzer repairs, and the
  final teardown change all return GO with no remaining P0/P1/P2 finding.

### Failed approaches and adaptations

- Broad strict Credo exposed pre-existing style debt touched by the package;
  the affected code was repaired without suppressions before acceptance.
- The first coverage gate exposed both unmeasured new boundary modules and a
  real unreachable `Exception` branch. Behavioral coverage was added where a
  deterministic oracle exists, dead logic was removed, and the structural
  OS/process modules were separately declared and adversarially exercised.
- Dialyxir 1.4.7's `short` formatter crashes on OTP 28 while rendering the new
  `:opaque_compare` warning form. Switching to Dialyzer's native formatter
  exposed 32 actual findings. Adding vendored `:erlexec` to the PLT removed six
  false unknown-function warnings; one precise namespace-identity input spec,
  removal of statically unreachable AppServer clauses, and behavior-preserving
  opaque-type comparisons resolved the remainder. The final analysis has no
  ignored warnings.
- A complete gate reached the real private snapshot and then failed in test
  teardown: the named Orchestrator retired between `Process.whereis/1` and
  `GenServer.stop/1`. The helper now accepts only the exact pinned-PID
  `:noproc` stop tuple. All other exits still fail; 100 repetitions and an
  independent review confirm the repair does not mask abnormal termination or
  leave a restart path alive.
- Final runtime review found that a pending sent idempotent read could eclipse
  an already acknowledged active turn when classifying a later timeout. The
  connection now uses one unresolved-operation selector everywhere; a
  regression proves uncertainty remains attributed to the active `turn/start`
  operation and that its private parameters are not exposed.
- The same review found that the direct AppServer entry point validated only
  its explicit `worker_host` option before launch and reread configuration for
  session policy. Startup now uses one settings snapshot and rejects a
  configured SSH worker before workspace or process side effects; a marker
  regression proves no launch occurs.
- Evidence review separated the repository-prefixed erlexec inventory hash
  from the vendor-root-relative schema proof and narrowed shell/environment
  claims to the candidate-controlled per-attempt boundary. The first final
  reseal then failed closed because its independent fixture-count oracle still
  expected 274 tests; synchronizing that second oracle to 276 allowed the exact
  final seal and full gate to pass.
- Final evidence audit found that the vendored patch note still denied custom
  helper-path options even though runtime preparation deliberately accepts a
  validated trusted operator `:erlexec, :portexe`. The note now distinguishes
  unavailable WORKFLOW/user-job controls from trusted operator/runtime
  configuration. Because that note is source-bound, the prior seal was
  invalidated; the 113-file/276-test seal, both erlexec proofs, seed-42 replay,
  complete gate, dependent documentation, and candidate archive were all
  regenerated. The same audit also made the NOTICE reproduction and historical
  measured-coverage wording precise.
- Staging the previously untracked vendor tree exposed legacy CRLF/trailing
  whitespace in ten unchanged upstream files that an unstaged diff cannot see.
  Normalizing those files would invalidate the verified package and unchanged-
  runtime-source proof. Root `.gitattributes` therefore exempts only those ten
  exact upstream paths; downstream-authored and patched vendor files still pass
  the ordinary cached whitespace gate.

### Remaining package boundary

- R0-03 is accepted, but Release 0 is not yet releasable. Structured event IDs
  and replay begin in R0-04; workspace/tracker hardening, live capability and
  quota discovery, readiness, protected publication, SBOM, and install testing
  remain R0-05 through R0-07.
- The durable App Server operation ledger and post-crash reconciliation reducer
  remain R1-07 work, exactly as assigned by the package DAG.
