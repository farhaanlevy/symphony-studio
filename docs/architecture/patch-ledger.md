# Patch ledger

Ledger revision: `8`

This ledger classifies every non-trivial downstream change. Documentation-only
records may be grouped when they establish one coherent package boundary.

| ID | Package | Class | Surface | Purpose | Preservation / removal evidence | Status |
|---|---|---|---|---|---|---|
| STUDIO-0001 | R0-01 | B | Repository metadata and documentation | Lock target/provenance, route the two specifications, document fork policy, governance, preflight, and threat model. | No runtime behavior changes; root `SPEC.md`, `LICENSE`, and `NOTICE` hashes are recorded in R0-01 evidence. Modified upstream README carries a visible downstream notice. | Accepted |
| STUDIO-0002 | R0-01 | A | `elixir/test/symphony_elixir/core_test.exs`, `orchestrator_status_test.exs` | Make retry scheduling and dashboard semantics deterministic by using the memory tracker, an exact scheduling bracket, explicit render width, and a raw sanitizer oracle. | Test-only; production modules are unchanged and no upstream test is removed or disabled. Both files carry downstream notices. Narrow/wide focused tests, three retry seeds, and full upstream `make all` pass. | Accepted |
| STUDIO-0003 | R0-02 | B | `CODEX_VERSION`, `CODEX_LOCK.json`, generated schema bundle, method/field matrix, schema loader, and verifier | Pin the exact Codex 0.144.3 App Server contract and make stable/experimental protocol presence machine-verifiable without inventing runtime capabilities. | Raw Codex-generated files are retained. JSON uses a documented semantic hash because aggregate definition order is nondeterministic; TypeScript uses raw hashes. Clean regeneration, exact executable checksums, matrix assertions, and the package-local loader pass. | Accepted |
| STUDIO-0004 | R0-02 | A | Strict fake App Server, stateful loopback fake Linear, network-hermetic test startup, supervised test lifecycle, and `make schema` | Replace weak line-count/external-network/lifecycle assumptions with reusable ordered protocol fixtures, a real-client loopback boundary, and deterministic supervisor ownership. | Production tracker and orchestration behavior is unchanged. Ordinary tests cannot address the real Linear endpoint; the separately gated live E2E opts in explicitly. Strict method/ID/schema, mismatch, isolation, pagination, blocker, mutation, uncertainty, lifecycle stress, and full-suite gates pass. | Accepted |
| STUDIO-0005 | R0-02 | A | `Config.Schema`, Codex App Server startup requests, and dynamic-tool declarations | Reconcile production outbound requests, sandbox policy, callback decisions, and dynamic-tool responses with the pinned Codex 0.144.3 generated contract. | Initialization order and Symphony orchestration remain intact. Exact fixtures prove the request and response envelopes; legacy `reject` policy normalizes to granular booleans, unsupported policy shapes fail closed, `never` cannot approve callbacks, and only pinned sandbox variants reach the wire. | Accepted |

Class C entries additionally require all of: triggering version, reason,
removal condition, regression test, owner, and upstream issue URL. A Class C
change cannot be accepted with any field omitted.

## Revision history

- Revision 1 — 2026-07-14: opened for the R0-01 metadata and provenance slice.
- Revision 2 — 2026-07-14: classified deterministic upstream test-harness hardening as Class A.
- Revision 3 — 2026-07-14: recorded Apache-2.0 per-file notices, target release, and stronger sanitizer oracle.
- Revision 4 — 2026-07-14: pinned Codex 0.144.3 and classified the generated compatibility contract as a Studio extension.
- Revision 5 — 2026-07-14: opened deterministic App Server/Linear fixtures and the network-hermetic test baseline for independent review.
- Revision 6 — 2026-07-14: bound fixture evidence to source, reconciled production request shapes, expanded the exact method/field matrix, and repaired deterministic supervised test ownership.
- Revision 7 — 2026-07-14: reclassified generic App Server conformance fixes as Class A and made fail-closed callback and exact sandbox behavior explicit.
- Revision 8 — 2026-07-15: accepted R0-02 after the source-bound seal, exact 67-test schema gate, deterministic regeneration, 266-test/100%-coverage full gate, Dialyzer, and independent adversarial review all passed.
