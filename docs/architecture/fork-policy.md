# Fork policy

## Relationship and locked base

Symphony Studio is a downstream GitHub fork of OpenAI Symphony, not a
reimplementation. `origin` is `farhaanlevy/symphony-studio`; `upstream` is
`openai/symphony`. Release 0 starts from the exact commit in `UPSTREAM_BASE`.
The local `upstream` remote has fetch URL
`https://github.com/openai/symphony.git` and push URL `DISABLED` so an ordinary
push cannot target OpenAI's repository.

The root upstream `SPEC.md` remains byte-for-byte intact at this base. The
downstream product contract lives in root `STUDIO_SPEC.md`.

## Change classes

- **Class A — upstreamable hardening:** generic bug fixes, safety improvements,
  event boundaries, deterministic identifiers, conformance tests, fake
  fixtures, cancellation/retry correctness, and path safety.
- **Class B — Studio extension:** persistence, evidence, quota and model-role
  policy, detached review, the Studio UI, diagnostics, showcase support, and
  release evidence.
- **Class C — temporary compatibility:** a pinned-version workaround with a
  triggering version, reason, removal condition, regression test, owner, and
  upstream issue link.

Every non-trivial change is entered in `patch-ledger.md` before it is accepted.
Every modified upstream source or test file also carries a prominent downstream
change notice as required by Apache-2.0 section 4(b); the central ledger does not
replace that per-file notice.

## Preserved upstream invariants

The fork preserves:

- scheduler semantics unless an explicit Studio policy narrows them;
- existing `WORKFLOW.md` keys, defaults, and dynamic reload;
- Linear normalization and tracker-of-record behavior;
- per-issue workspace layout, bounded concurrency, cancellation, and cleanup;
- restart recovery from the tracker and filesystem;
- current CLI behavior and existing `/api/v1/*` fields;
- independent operation of the runner without Studio persistence or UI; and
- tolerance for unknown Studio front-matter keys in upstream-compatible paths.

Prefer injected sinks, behaviours, callbacks, wrapper modules, optional
supervisors, new namespaces, and additive fields. Do not rename the core,
replace the orchestration state machine, introduce other agent providers, or
make Studio persistence necessary for scheduler correctness.

## Upstream synchronization

Upstream movement is intentional, never automatic:

1. fetch `upstream/main` and report commits since `UPSTREAM_BASE`;
2. inspect a range diff and conflicts;
3. select and record the new base only when explicitly accepted;
4. rerun the untouched upstream suite, Studio conformance, and live smoke;
5. update `UPSTREAM_BASE` and every affected ledger/evidence record together.

New upstream commits alone are informational; actual incompatibility fails the
compatibility job.

## Release branches and publication

Release 0 uses `release/v0.1.0`. Later release branches start from the prior
published stable tag. Incomplete work is pushed only to `origin` release
branches. GitHub merges the sealed candidate through protected `main`; neither
the implementation conductor nor release automation pushes directly to main.

Candidate code runs read-only without publication credentials. Privileged
publication runs only from protected main after exact-merge verification.

## Licensing and attribution

The Apache-2.0 `LICENSE` and upstream `NOTICE` remain present. Documentation and
submission material identify OpenAI Symphony as upstream and distinguish its
work from the Build Week additions.
