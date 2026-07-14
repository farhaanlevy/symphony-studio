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
