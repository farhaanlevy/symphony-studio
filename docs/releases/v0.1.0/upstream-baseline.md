# Untouched upstream baseline

## Identity

- Repository: `https://github.com/openai/symphony`
- Commit: `4cbe3a9699a73b862466c0b157ceca0c1985d6d7`
- Subject: `[web] Add Symphony favicon (#90)`
- Upstream root `SPEC.md` SHA-256:
  `fa9d7c252cc72d10afdaf4e46e0d890aae28cf4331dc531c94413bc8ea199452`
- `LICENSE` SHA-256:
  `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`
- `NOTICE` SHA-256:
  `38c76eb8701e52953f63154a77b407667a6ee34c3a2a8785c8f8b2cd5494d09d`

## Commands

From `elixir/` on the untouched checkout:

```sh
mise trust
mise install
mise exec -- elixir --version
mise exec -- mix --version
mise exec -- make all
```

Toolchain setup, compilation, formatting, lint/Credo, and public-spec checks
passed. The coverage test phase ran 241 tests with 4 failures and 2 skips.

## Observed failures

1. Two terminal dashboard assertions expected the full completed-turn text but
   the rendered table inherited a narrow pseudo-terminal width and truncated
   the value. Re-running those tests with `COLUMNS=240` passed.
2. The normal and abnormal worker-exit retry tests asserted a lower bound on
   remaining retry delay after state access. Startup's synchronous real Linear
   poll with fake credentials consumed part of that interval, producing values
   below the lower bound. Running the timing tests serially did not repair them.

The exact upstream GitHub Actions run for this same SHA was also red:

- Run: <https://github.com/openai/symphony/actions/runs/27242387371>
- Job: <https://github.com/openai/symphony/actions/runs/27242387371/job/80448818917>
- Result: 241 tests, 1 failure in the abnormal worker-exit retry timing
  assertion (`39497` observed versus `39500` minimum).

This independent upstream evidence confirms inherited timing sensitivity rather
than a Studio source regression.

## Hypothesis loop

- Hypothesis 1 — ordinary test concurrency consumes the delay: rejected by a
  `--max-cases 1` rerun.
- Hypothesis 2 — pseudo-terminal width explains all failures: partially true for
  the dashboard tests, false for retry timing.
- Hypothesis 3 — orchestrator startup/network work blocks state inspection:
  supported by the synchronous fake-token Linear poll and elapsed delay.

After three bounded checks the baseline was recorded rather than weakening the
assertions ad hoc.

## Gate status

The untouched base was **red**. This record is evidence, not a waiver. R0-01 cannot exit until a minimal
Class A hardening change isolates the tests from ambient terminal width and real
network timing, preserves production behavior, and makes the full original
`make all` gate pass repeatedly.

## Class A resolution

The R0-01 branch applies a test-only hardening patch:

- the three retry scheduling tests explicitly select the in-memory tracker;
- the timing oracle brackets the exact scheduled timestamp between the send and
  observation timestamps instead of subtracting arbitrary elapsed wall time;
- the two dashboard semantic tests pass an explicit 140-column width; and
- the affected ANSI-stripping regex accepts decimal SGR parameters correctly.

Focused verification passed at `COLUMNS=40` and `COLUMNS=240`. Retry tests
passed serially with seeds 11, 22, and 33. The complete command
`COLUMNS=80 mise exec -- make all` then passed: setup, escript build, format,
public-spec lint, Credo (56 files / 1,199 functions), 241 tests with zero
failures and two skips, 100% reported coverage, and Dialyzer with zero errors.

No production module changed. The original upstream quality-gate command is
green on the accepted R0-01 branch while this section retains the inherited
untouched-base failure for provenance.
