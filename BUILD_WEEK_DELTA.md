# Build Week delta

## Provenance

- Upstream repository: <https://github.com/openai/symphony>
- Downstream repository: <https://github.com/farhaanlevy/symphony-studio>
- Fork date: 2026-07-14
- Locked upstream base: `4cbe3a9699a73b862466c0b157ceca0c1985d6d7`
- Upstream base subject: `[web] Add Symphony favicon (#90)`
- Upstream engine specification: [`SPEC.md`](SPEC.md)
- Studio product specification: [`STUDIO_SPEC.md`](STUDIO_SPEC.md)

## Upstream work

OpenAI Symphony supplies the language-agnostic orchestration contract and the
experimental Elixir/Phoenix reference runner: Linear polling, bounded issue
admission, isolated workspaces, Codex App Server sessions, retry/recovery,
terminal-state cleanup, CLI operation, and the existing `/api/v1/*` surface.
Those capabilities predate this Build Week fork.

## Build Week additions

The stable downstream contract remains staged: Release 0 hardens the
upstream-compatible runner, Release 1 builds the production Studio MVP, and
Release 1.1 completes submission hardening. The deadline override also permits
one honestly labelled Build Week Preview without representing it as complete
Release 1 or 1.1.

Release 0 packages R0-01 through R0-06 are accepted at foundation commit
`25f4d78e1eb3102dd8d1aa72413988b36b72fd71`. Their downstream additions include:

- exact Codex CLI `0.144.3` pinning and 1,873 generated schema artifacts;
- strict bounded JSONL transport, request correlation, conservative uncertain
  outcomes, and no-model capability discovery;
- shell-free App Server launch, PID/process cleanup containment, cancellation
  convergence, isolated workspace/path safety, and bounded hook execution;
- one-operation parsed GraphQL enforcement, a separate read-only Linear
  capability broker, and explicit managed authorization seams;
- normalized run/attempt/operation/event identity with bounded process-local
  replay; and
- atomic redacted readiness evidence, reproducible package/archive checks, and
  independent exact-tree review.

R0-07 protected `v0.1.0` publication is still pending and is not claimed by the
Build Week branch.

The public `release/v0.2.0-buildweek-preview.1` branch pulls forward only the
submission-critical owner experience:

- prompt or pasted Markdown intake, bounded repository inspection, at most two
  clarification questions, and a three-to-five-task proposal;
- one canonical owner-local Intent Service shared by Phoenix LiveView and a
  five-tool STDIO MCP liaison;
- production Setup, New Work, Mission Control, and Run Detail routes backed by
  current Store and runtime-event state, not fixture-only success;
- latest-attempt and revision-bound completion truth for deterministic checks,
  detached review, sealed evidence, delivery, tracker handoff, terminal state,
  and actual model/effort attestation; and
- strict launch/reset/browser/accessibility/public-artifact verification.

Production Linear publication and Start are hard-disabled. The accepted R0
credential boundary cannot be preserved by loading either credential into the
preview BEAM, so a distinct trusted out-of-process write broker is required.
No demo issue, live Linear mutation, admitted preview run, GPT-5.6 execution,
completed golden path, or evidence-backed outcome is claimed.

## Codex and GPT-5.6 use

Codex served as the accountable implementation conductor. Bounded supporting
threads handled independent code review, security/release audits, deterministic
test work, browser verification, and submission copy where file ownership was
disjoint. Model conclusions never substitute for deterministic gates.

The committed runtime policy requests GPT-5.6 Sol Ultra with Ultra reasoning,
and R0-06 verifies that the pinned Codex installation advertises the required
capability without starting model work. The current preview has not admitted a
demo issue or executed GPT-5.6 end to end. UI and submission copy therefore
separate configured policy from current-attempt runtime attestation.

## Security and judge boundary

- Loopback-only, one trusted local operator, Linux x86_64 candidate.
- Every supported preview helper/build/browser/runtime child receives a strict
  environment allowlist; Linear keys, pointers, tokens, passwords, and session
  material are not inherited.
- The local MCP liaison persists owner-local planning state but exposes no
  approval, publication, Start, or Linear mutation tool.
- Production external-action controls are absent while the trusted write broker
  is unavailable; the UI renders `external_write_broker_required` instead.
- `SYM-1` and `SYM-2` remain protected. No media or credential belongs in Git
  or GitHub Release assets.
- A fresh machine currently builds from source once. A local repeat can use the
  documented `--no-build` path, but no public binary, sandbox, or demo account
  is claimed.

## Evidence index

- Implementation journal: [`docs/implementation/journal.md`](docs/implementation/journal.md)
- Work-package checkpoints: [`docs/implementation/checkpoints/`](docs/implementation/checkpoints/)
- Release evidence: [`docs/releases/`](docs/releases/)
- Readiness manifest: `artifacts/readiness/implementation-readiness.json` after R0-06
- Build Week `/feedback`: the owner reports that the primary upload was
  generated and saved in Devpost. Its public-safe identifier remains an
  external Devpost field; no unverified or side-task identifier is substituted
  in repository history.
- Preview owner/browser evidence: [`docs/buildweek/owner-testing.md`](docs/buildweek/owner-testing.md)
- Preview limitations: [`docs/buildweek/preview-limitations.md`](docs/buildweek/preview-limitations.md)

Final video, raw captures, narration, thumbnails, and editor projects are
excluded from this repository and every release archive.
