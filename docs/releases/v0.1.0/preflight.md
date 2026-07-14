# v0.1.0 publication preflight

Observed at: `2026-07-14T18:52:54Z`

Stage: Release 0

Branch: `release/v0.1.0`

Overall state: **local implementation may proceed; publication remains gated**

## Repository and identity

| Check | Evidence | Result |
|---|---|---|
| Downstream is a GitHub fork | `farhaanlevy/symphony-studio`, parent `openai/symphony` | Pass |
| Default branch | `main` | Pass |
| Locked base and fork main | both `4cbe3a9699a73b862466c0b157ceca0c1985d6d7` at creation | Pass |
| Authenticated identity | GitHub login `farhaanlevy`; repository permission `ADMIN` | Pass |
| Release capabilities | Admin/push permission plus `repo` and `workflow` interactive scopes support branch pushes, PRs, settings, workflows and releases | Pass for operator; automation still pending |
| Git commit identity | local repository uses GitHub noreply identity for `Farhaan Levy` | Pass |

The required named fork did not exist. Creating it was the unavoidable first
remote provisioning write; no source or release branch was pushed before the
parent, permissions, main SHA, remotes, and governance were verified.

## Remotes

| Remote | Fetch | Push | Result |
|---|---|---|---|
| `origin` | `https://github.com/farhaanlevy/symphony-studio.git` | same credential-free URL | Pass |
| `upstream` | `https://github.com/openai/symphony.git` | `DISABLED` | Pass |

No credential is embedded in either remote URL.
Local branch `main` tracks `origin/main`; upstream movement requires the
intentional fetch/review workflow and cannot arrive through a routine main pull.

## Merge and main protection

| Check | Effective setting | Result |
|---|---|---|
| Auto-merge | enabled | Pass |
| Merge commits | enabled | Pass |
| Squash/rebase merge | disabled to remove candidate ambiguity | Pass |
| Pull request required | enabled, zero human approvals for single-owner profile | Pass |
| Required status | strict `studio/release-gate`, bound to GitHub Actions app ID `15368` | Pass, workflow pending R0-07 |
| Admin enforcement | enabled | Pass |
| Conversation resolution | required | Pass |
| Force push | disabled | Pass |
| Branch deletion | disabled | Pass |
| Linear history | disabled because release policy requires merge commits | Pass |
| Bypass actors | none configured; admin enforcement applies to release identity | Pass |

The classic protection API initially rejected an empty organization-only bypass
allowance on this user-owned repository. The accepted rule omits that invalid
field and configures no bypass actor.

Binding a check name to GitHub Actions app ID `15368` is necessary but not
sufficient: candidate code could otherwise add or alter a workflow that emits
the same check. R0-07 publication is blocked until a trusted base-controlled
gate or equivalent immutable attestation proves workflow provenance, binds the
exact head/base/candidate manifest, and never executes candidate code with write
credentials. This is tracked explicitly in the threat model.

## Credential and workflow posture

- The interactive `gh` credential has scopes `repo`, `workflow`, `read:org`,
  and `gist`. It is operator tooling, not a release-automation credential.
- R0-07 candidate workflows will declare read-only repository permissions and
  receive no publication secret.
- R0-07 publication will use the ephemeral GitHub Actions token only from
  protected `main`, with the minimum contents/release permissions for its job.
- Repository Actions default to read-only contents, cannot approve pull
  requests, and require actions to be pinned to full commit SHAs.
- `pull_request_target` is forbidden for candidate-code execution.
- Credential and archive scans are mandatory before every candidate seal.

## Installed compatibility points

| Component | Observed value | Impact |
|---|---|---|
| Codex CLI | `codex-cli 0.144.3`, authenticated with ChatGPT | Pin/hash/schema discovery required in R0-02/R0-06. |
| Codex App Server schema | Generated live in preflight; bundle evidence not yet committed | Must be regenerated from the pinned executable and compatibility-tested. |
| Erlang | OTP 28 / ERTS 16.4 | Matches repository pin. |
| Elixir / Mix | 1.19.5, OTP 28 | Matches repository pin. |
| mise | 2026.6.12 | Tool reports 2026.7.6 available; no unreviewed upgrade. |
| Node.js | v18.20.4 | Schema helper works; packaging support must be claimed explicitly. |
| Host | Debian GNU/Linux 12, x86_64 | Initial claimed platform candidate; clean-package proof pending. |
| Linear connector | OAuth read access to team/project metadata works | Connector token is not a runtime credential. |
| Linear runtime key | `LINEAR_API_KEY` and `~/.linear_api_key` absent | Blocks live runtime smoke later, not deterministic R0 implementation now. |

Generated schema inspection found the required account, rate-limit, model, thread,
turn, review, goal and compaction families in the installed App Server schema.
Exact fields, hashes, service tiers, models, efforts and cap enforcement remain
R0-02/R0-06 acceptance work; no capability is inferred from memory.

## Present before downstream edits

- OpenAI Symphony root contracts, Apache-2.0 license and notice
- Elixir/Phoenix implementation and nested contributor instructions
- `mise` toolchain pin and `make all` quality gate
- unit/integration tests and upstream GitHub Actions workflow
- upstream demo poster/video assets already present at the locked base

The inherited upstream media files are provenance-preserved baseline content,
not final Studio submission media. Release archive/media-exclusion policy will
enumerate this baseline explicitly rather than misclassify it as new submission
capture.

## Missing at preflight

- Green deterministic upstream suite on the locked base
- Pinned/generated Codex schema artifacts and fake fixtures
- R0 transport/event/recovery/capability conformance implementation
- Machine-readable green implementation-readiness manifest
- Minimum-permission release workflows, release scripts and manifests
- Independent exact-SHA review evidence
- Package, clean-install, baseline-return and published-asset verification
- Runtime Linear credential for live smoke

## Exact first package and blockers

The first package is **R0-01: fork metadata, remote policy, baseline lock, patch
ledger, licensing proof, and a green original suite**.

There is no hard blocker to deterministic R0 implementation. R0-01 remains open
on inherited baseline test debt. Release completion will also remain blocked
until `studio/release-gate` exists and passes, minimum-permission automation is
verified, independent review is current, packaging passes, and runtime Linear
authentication is available for the applicable live gate.
