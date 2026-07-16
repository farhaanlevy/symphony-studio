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

The downstream scope is deliberately staged and will be updated only as each
package is accepted:

1. Release 0 hardens and pins the upstream-compatible runner, conformance
   boundaries, recovery behavior, capability discovery, and release train.
2. Release 1 adds the local single-project Studio MVP: durable state and
   evidence, quota-safe execution, detached review, and five authoritative
   LiveView route families.
3. Release 1.1 freezes features and completes submission hardening, packaging,
   judge-path verification, and external-media preparation.

Accepted downstream packages currently include R0-01 provenance/governance;
R0-02 Codex 0.144.3 pinning, generated stable/experimental schema contracts,
exact outbound-request validation, and deterministic App Server and loopback
Linear fixtures; and R0-03 strict JSONL transport, bounded content-free stderr
diagnostics, absolute request deadlines, conservative uncertain outcomes,
source-identity compatibility circuit, shell-free App Server argv and
PID-namespace containment, and fail-closed remote release gating. R0-03 passed
its 113-file/276-test source seal, clean regeneration, 73-test schema harness,
full 398-test gate with 100% of measured modules covered, zero-error Dialyzer
analysis, real no-model App Server smoke, and independent adversarial review on
2026-07-16.

R0-04 adds an injectable normalized-event seam, deterministic
event identity, stable run/attempt/operation correlation, bounded process-local
replay, stale-attempt isolation, and allowlisted redacted payloads while
preserving existing Symphony callbacks and `/api/v1/*` fields. Its default sink
retains nothing, and loss of optional sink history cannot block scheduler or
input-safety projection. It passed its 122-file/308-test source seal, installed
pin and clean regeneration, 73-test schema harness, full 432-test gate with
100% of measured modules covered, zero-error Dialyzer analysis, real
initialize-only App Server smoke, hygiene audit, and independent adversarial
review on 2026-07-16. R0-04 is an accepted downstream package.

R0-05 hardens cancellation and retry convergence, binds cleanup to the exact
workspace that ran, contains local hooks, makes guardian cleanup authority
single-owner across runtime and nested-supervisor crashes, repairs upstream raw
GraphQL to exactly one parsed operation, and adds an explicit opt-in managed
authorization/outbox seam without durable tracker claims. Unsupported workflow
features remain blocked before SSH and now produce only a stable, content-free
validation classification rather than a misleading tracker-fetch diagnostic.
Its accepted package binds 133 source files and 411 tests, passes the 535-test
complete gate with 100.00% measured coverage and zero Dialyzer errors, verifies
installed Codex 0.144.3 against 1,873 schema artifacts, and passes a real
initialize-only no-model smoke. The exact pin rejected host drift to 0.144.5,
and acceptance restarted under user-local exact 0.144.3 without resealing.
Provenance, secret/path/media and archive-exclusion scans pass; normalized
package construction is reproducible; and fresh repaired-tree reviews report no
remaining P0/P1/P2. R0-05 is an accepted downstream package.

Runtime capability discovery, durable event history, restart/browser replay,
the durable operation ledger, Studio state, the operator UI, and submission
hardening remain unclaimed until their later packages pass.

## Build Week execution configuration

- Primary implementation thread: accountable root conductor
- Initial work pace: Balanced
- Conductor target: GPT-5.6 Sol, Ultra reasoning
- Bounded explorers: GPT-5.6 Terra, Medium reasoning, read-only by default
- Failure analysis: GPT-5.6 Terra, High reasoning
- Independent review: GPT-5.6 Sol, High or Max reasoning
- Release audit: GPT-5.6 Sol, Max reasoning

The exact available model IDs, effort values, service tiers, and enforceable
subagent caps are discovered from the pinned Codex executable in R0-06. This
document does not invent unavailable capabilities.

## Evidence index

- Implementation journal: [`docs/implementation/journal.md`](docs/implementation/journal.md)
- Work-package checkpoints: [`docs/implementation/checkpoints/`](docs/implementation/checkpoints/)
- Release evidence: [`docs/releases/`](docs/releases/)
- Readiness manifest: `artifacts/readiness/implementation-readiness.json` after R0-06
- Build Week `/feedback` Session ID: `PENDING_FINAL_PRIMARY_THREAD_FEEDBACK`
- Screenshot and test references: added with the packages that produce them

Final video, raw captures, narration, thumbnails, and editor projects are
excluded from this repository and every release archive.
