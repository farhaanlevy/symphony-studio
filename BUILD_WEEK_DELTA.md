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

At this checkpoint only R0-01 metadata, provenance, governance, and preflight
records are being established. No later-stage feature is claimed complete.

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
