# Patch ledger

Ledger revision: `3`

This ledger classifies every non-trivial downstream change. Documentation-only
records may be grouped when they establish one coherent package boundary.

| ID | Package | Class | Surface | Purpose | Preservation / removal evidence | Status |
|---|---|---|---|---|---|---|
| STUDIO-0001 | R0-01 | B | Repository metadata and documentation | Lock target/provenance, route the two specifications, document fork policy, governance, preflight, and threat model. | No runtime behavior changes; root `SPEC.md`, `LICENSE`, and `NOTICE` hashes are recorded in R0-01 evidence. Modified upstream README carries a visible downstream notice. | Accepted |
| STUDIO-0002 | R0-01 | A | `elixir/test/symphony_elixir/core_test.exs`, `orchestrator_status_test.exs` | Make retry scheduling and dashboard semantics deterministic by using the memory tracker, an exact scheduling bracket, explicit render width, and a raw sanitizer oracle. | Test-only; production modules are unchanged and no upstream test is removed or disabled. Both files carry downstream notices. Narrow/wide focused tests, three retry seeds, and full upstream `make all` pass. | Accepted |

Class C entries additionally require all of: triggering version, reason,
removal condition, regression test, owner, and upstream issue URL. A Class C
change cannot be accepted with any field omitted.

## Revision history

- Revision 1 — 2026-07-14: opened for the R0-01 metadata and provenance slice.
- Revision 2 — 2026-07-14: classified deterministic upstream test-harness hardening as Class A.
- Revision 3 — 2026-07-14: recorded Apache-2.0 per-file notices, target release, and stronger sanitizer oracle.
