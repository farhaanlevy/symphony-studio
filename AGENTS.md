# Symphony Studio repository guide

- Preserve OpenAI Symphony as the core. Root `SPEC.md` is the untouched upstream engine contract; `STUDIO_SPEC.md` is the downstream product and release contract.
- Implement only Release 0, Release 1, and Release 1.1 in dependency order. Do not add Release 2+ product surface or provider abstractions.
- Work on `release/<version>` branches from the required stable base. Never push to `upstream` or directly to protected `main`.
- Before editing a package, read its exact `STUDIO_SPEC.md` clauses and update `docs/implementation/checkpoints/<package>.md` with acceptance evidence.
- Classify every non-trivial fork change in `docs/architecture/patch-ledger.md`. Preserve the invariants in `docs/architecture/fork-policy.md`.
- Follow the nested `elixir/AGENTS.md` for Elixir changes. Run targeted tests first and `cd elixir && mise exec -- make all` for the full upstream gate.
- Do not persist secrets, private reasoning, raw submission media, or fabricated evidence. Final media belongs outside every Git worktree.
