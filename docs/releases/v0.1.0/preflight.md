# v0.1.0 publication preflight

Observed at: `2026-07-14T18:52:54Z`

Stage: Release 0

Branch: `release/v0.1.0`

Overall state: **local implementation may proceed; publication remains gated**

## R0-07 live refresh — 2026-07-21

- R0-06 is accepted and pushed at
  `25f4d78e1eb3102dd8d1aa72413988b36b72fd71`.
- Repository release immutability is enabled for future releases. The
  `enforced_by_owner=false` API field means no organization-owner policy
  enforces this user-owned fork; it does not mean the repository setting is
  disabled.
- Strict `main` protection, merge commits, auto-merge, read-only default
  Actions permissions, administrator enforcement, and the no-force/no-delete
  rules remain configured.
- The sole remaining governance blocker is the expected source of
  `studio/release-gate`: it is still general GitHub Actions App ID `15368`.
  R0-07 will not open the protected merge path until that context is rebound to
  the dedicated external attestor App without removing or weakening the check.
- No `v0.1.0` tag, GitHub Release, or release pull request exists at this
  refresh.

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
| Required status | strict `studio/release-gate`, currently bound to general GitHub Actions App ID `15368` | **Blocker** — must be rebound to the dedicated attestor App |
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
- R0-07 publication uses the ephemeral GitHub Actions token only from protected
  `main` for bounded repository/release operations. Repository Actions store no
  dedicated-App private key or installation token; post-merge failures remain
  visibly action-required instead of minting a pull-request mutation token.
- Repository Actions default to read-only contents, cannot approve pull
  requests, and require actions to be pinned to full commit SHAs.
- `pull_request_target` is forbidden for candidate-code execution.
- Credential and archive scans are mandatory before every candidate seal.

## Installed compatibility points

| Component | Observed value | Impact |
|---|---|---|
| Codex CLI | `codex-cli 0.144.3`, authenticated with ChatGPT | Pin/hash/schema discovery required in R0-02/R0-06. |
| Codex App Server schema | Source-bound bundle and manifest accepted through R0-06 | Must remain byte-bound to pinned Codex `0.144.3`. |
| Erlang | OTP 28.5 / ERTS 16.4 | Matches the exact repository pin. |
| Elixir / Mix | 1.19.5, OTP 28 | Matches repository pin. |
| mise | Release workflow pin `2026.7.11`, Linux x64 SHA-256 `d31578a16ae2708385249b439c95533068e04b9507a118e905aa6768905671fc` | Supported release path is exact and checksum-verified. |
| Node.js | v18.20.4 | Schema helper works; packaging support must be claimed explicitly. |
| Host | Debian GNU/Linux 12, x86_64 | Initial claimed platform candidate; clean-package proof pending. |
| Linear R0-06 replay | Dedicated downstream project/team, states, labels, two fixture shapes, comment, blocker, and schema-only mutation shape | Accepted: exactly nine queries and zero mutations; no credential, selector, protected path, raw response, or private identity entered public evidence. |

The committed source-bound schema and accepted R0-06 capability evidence prove
the required account, rate-limit, model, thread, turn, review, goal, and
compaction families for installed Codex `0.144.3`. No capability is inferred
from memory or from a version string alone.

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

## Historical initial-preflight gaps — superseded

- Green deterministic upstream suite on the locked base
- Pinned/generated Codex schema artifacts and fake fixtures
- R0 transport/event/recovery/capability conformance implementation
- Machine-readable green implementation-readiness manifest
- Minimum-permission release workflows, release scripts and manifests
- Independent exact-SHA review evidence
- Package, clean-install, baseline-return and published-asset verification
- Runtime Linear credential for live smoke

These were the July 14 starting gaps, not current blockers. R0-01 through
R0-06 are accepted. Current R0-07 acceptance still requires the final coherent
gate and two reviews, dedicated App configuration, protected merge, package and
clean-install proof, immutable publication, and downloaded-asset verification.

## Historical first package and current blockers

The first package is **R0-01: fork metadata, remote policy, baseline lock, patch
ledger, licensing proof, and a green original suite**.

R0-01 was the first package and is accepted; this paragraph supersedes the July
14 planning state. The current external blocker is the dedicated release App:

- install it only on `farhaanlevy/symphony-studio` with Metadata read,
  Contents read, Actions read, Pull requests read, and Checks write; no
  Contents write, Pull requests write, or Administration write;
- set only repository variable `TRUSTED_CHECK_APP_ID` (numeric App ID); keep
  the App private key and every short-lived installation token entirely in the
  owner-operated out-of-band controller, never a repository Actions secret;
- bind required context `studio/release-gate` to that App; and
- require its latest exact-head CheckRun to be completed/success with
  `external_id` equal to the canonical candidate-manifest SHA-256, title
  `Symphony Studio R0-07 trusted candidate`, summary
  `candidate-manifest-sha256:<digest>`, and text
  `candidate-manifest-base64:<canonical-bytes>`.

An older success cannot mask a newer pending or failed CheckRun. Linear
authentication is not an R0-07 blocker.
