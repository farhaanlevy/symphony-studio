# Symphony Studio v0.1.0 foundation

> **Publication status:** this source document describes the prepared R0-07
> candidate. It does not claim that `v0.1.0` is published. The release is
> authoritative only after the protected workflow exposes a non-draft,
> immutable `v0.1.0` GitHub Release and its checks below pass. At candidate
> preparation time, the complete gate, two fresh reviews, protected merge,
> supported-platform clean install, immutable publication, and downloaded-asset
> verification remain pending.

Symphony Studio v0.1.0 is the independently usable Release 0 foundation. It
preserves OpenAI Symphony as the core Linear-to-Codex runner and adds the
downstream security, compatibility, evidence, workspace, cleanup, and release
hardening implemented in R0-01 through R0-07.

This release does **not** claim the Symphony Studio Build Week interface. The
authoritative New Work, Mission Control, Run Detail, validation, and review
journey ships separately as an honestly labelled preview.

## What changed

- The Linear-to-Codex runner remains the upstream Symphony engine and workflow
  contract.
- Codex App Server compatibility is pinned to Codex CLI `0.144.3` and its
  source-bound schema bundle.
- Local workspaces, hook execution, App Server children, timeouts, and cleanup
  use the Release 0 fail-closed Linux containment boundary.
- Runtime readiness and release evidence are canonical, redacted, and bound to
  the exact source and protected-main merge.
- The release archive is reproducible and includes an exact lock-bound runtime
  inventory, complete third-party notices, and an SPDX 2.3 SBOM.
- Release 0 has no database schema, migration, or data upgrade.

## Supported platform

- Debian GNU/Linux 12 on Linux x86_64
- Erlang/OTP **28.5** and Elixir **1.19.5-otp-28**, installed from the exact
  `elixir/mise.toml` pin
- Codex CLI **0.144.3**
- Linux user/PID/mount namespaces, pidfds, procfs, and the util-linux
  capabilities documented in `elixir/README.md`

Other operating systems and architectures are not claimed by this package.
Disabled unprivileged namespaces, unavailable pidfds, or a different Codex
binary fail readiness rather than selecting a weaker execution mode.

## 1. Install clean-host prerequisites

On a clean Debian 12 x86_64 host:

```bash
sudo apt-get update
sudo apt-get install --yes --no-install-recommends \
  build-essential ca-certificates curl git gzip libncurses-dev libssl-dev \
  nodejs npm passwd procps python3 unzip util-linux

install -d -m 0755 "$HOME/.local/bin"
curl --fail --silent --show-error --location \
  --output /tmp/mise-v2026.7.11-linux-x64 \
  https://github.com/jdx/mise/releases/download/v2026.7.11/mise-v2026.7.11-linux-x64
printf '%s  %s\n' \
  d31578a16ae2708385249b439c95533068e04b9507a118e905aa6768905671fc \
  /tmp/mise-v2026.7.11-linux-x64 | sha256sum --check --strict
install -m 0755 /tmp/mise-v2026.7.11-linux-x64 "$HOME/.local/bin/mise"

export PATH="$HOME/.local/bin:$PATH"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
```

## 2. Download without a GitHub login

GitHub Release assets for a public repository can be downloaded over HTTPS
without an account or token. These commands fail with HTTP status 404 while
the candidate is unpublished; do not substitute a branch archive or an
unverified locally built package.

```bash
install -d -m 0755 symphony-studio-v0.1.0-download
cd symphony-studio-v0.1.0-download
release_url=https://github.com/farhaanlevy/symphony-studio/releases/download/v0.1.0

curl --fail --silent --show-error --location --remote-name \
  "$release_url/SHA256SUMS"
curl --fail --silent --show-error --location --remote-name \
  "$release_url/release-manifest.json"
curl --fail --silent --show-error --location --remote-name \
  "$release_url/symphony-studio-0.1.0-linux-x86_64.tar.gz"

test -s SHA256SUMS
test -s release-manifest.json
test -s symphony-studio-0.1.0-linux-x86_64.tar.gz
sha256sum --check --strict --ignore-missing SHA256SUMS

tar -xzf symphony-studio-0.1.0-linux-x86_64.tar.gz
cd symphony-studio-0.1.0/elixir
mise trust mise.toml
mise install
mise exec -- ./bin/symphony --version
```

The final command must report `Symphony 0.1.0`, the exact protected-main
commit, locked upstream base, Codex compatibility hash, and
`provenance: github-release-verified` without starting the runner.

## 3. Install and authenticate Codex

Install the exact compatible Codex release into the current user's local npm
prefix. The `npm install` command is intentionally version-pinned:

```bash
export NPM_CONFIG_PREFIX="$HOME/.local"
npm install --global @openai/codex@0.144.3
test "$(codex --version)" = "codex-cli 0.144.3"
python3 ../scripts/codex_schema.py verify --installed

codex login
codex login status
```

`codex login` is interactive and stores Codex authentication in Codex's normal
user-scoped store. Do not copy Codex authentication into `WORKFLOW.md`, the
release directory, screenshots, or issue text. The preceding source-bound
`verify --installed` command validates both the npm launcher and its native
Linux x86_64 executable, not only the displayed version. That verified
executable is the supported runner input; the runner separately loads the
packaged compatibility manifest.

## 4. Configure Linear without exposing the key

Copy the packaged workflow before editing it. Set `tracker.project_slug`, the
workspace root, and `hooks.after_create` repository URL to a disposable project
and repository you are authorized to use. Keep `tracker.api_key` unset or set
to `$LINEAR_API_KEY`; never paste the key into YAML. The configured Linear team
must provide the workflow states named by the file.

Capture the key without placing it in shell history or a command argument:

```bash
cp WORKFLOW.md WORKFLOW.local.md
# Edit only non-secret project, repository, state, and workspace settings.

read -r -s -p 'Linear API key: ' LINEAR_API_KEY
printf '\n'
export LINEAR_API_KEY
test -n "$LINEAR_API_KEY"
```

Use a dedicated test project and an eligible issue you are willing to let
Symphony update. Starting the runner can change issue state and add Linear
comments according to the selected workflow. Revoke or rotate the key after a
temporary judge run, and run `unset LINEAR_API_KEY` after stopping Symphony.

## 5. Start the runner

From the extracted `symphony-studio-0.1.0/elixir` directory:

```bash
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  WORKFLOW.local.md
```

Open <http://127.0.0.1:4000/>. Release 0 exposes the original Symphony
observability dashboard and `/api/v1/state`; it does not expose the later
Studio Mission Control interface. Stop the foreground process with `Ctrl-C`,
then clear the key from the shell:

```bash
unset LINEAR_API_KEY
```

## Optional: exact GitHub CLI verification

The no-login HTTPS procedure above is sufficient to download and checksum the
public assets. To verify GitHub's release and per-asset attestations, install
the exact GitHub CLI 2.96.0 Debian package and its published checksum:

```bash
curl --fail --silent --show-error --location \
  --output /tmp/gh_2.96.0_linux_amd64.deb \
  https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_linux_amd64.deb
printf '%s  %s\n' \
  11a731f4e0ca8c3db96ef6d2cc404dcab3d78247ce0e07c53e07117e7627d6a1 \
  /tmp/gh_2.96.0_linux_amd64.deb | sha256sum --check --strict
sudo dpkg --install /tmp/gh_2.96.0_linux_amd64.deb
test "$(gh --version | sed -n '1p')" = \
  "gh version 2.96.0 (2026-07-02)"
```

The no-login `curl` procedure remains the public download and checksum path.
The optional `gh release verify` commands below require GitHub CLI
authentication. Use the browser flow and verify status; never use
`gh auth status --show-token`:

```bash
gh auth login --hostname github.com --git-protocol https --web
gh auth status --hostname github.com
```

From `symphony-studio-v0.1.0-download`, verify the immutable release and the
already downloaded archive:

```bash
gh release verify v0.1.0 --repo farhaanlevy/symphony-studio
gh release verify-asset v0.1.0 \
  symphony-studio-0.1.0-linux-x86_64.tar.gz \
  --repo farhaanlevy/symphony-studio

gh attestation verify release-manifest.json \
  --repo farhaanlevy/symphony-studio \
  --predicate-type \
  https://github.com/farhaanlevy/symphony-studio/attestations/release-publication/v1 \
  --signer-workflow \
  farhaanlevy/symphony-studio/.github/workflows/publish-release.yml \
  --source-ref refs/heads/main
gh attestation download release-manifest.json \
  --repo farhaanlevy/symphony-studio \
  --predicate-type \
  https://github.com/farhaanlevy/symphony-studio/attestations/release-publication/v1
```

The protected publication workflow downloads and rehashes every draft asset
before publication, verifies GitHub's build provenance for the complete asset
set, makes the release immutable and Latest, and then binds the canonical
post-publication receipt to `release-manifest.json` through the custom
attestation predicate.

## Release evidence

The GitHub Release contains the installable archive, `SHA256SUMS`, SPDX SBOM,
third-party notices, implementation-readiness record, pinned Codex schema
manifest, candidate and final release manifests, migration report, test
summary, public-artifact audit, supported-platform receipt, build provenance,
and upstream-baseline return receipt. The archive itself also contains the
exact committed runtime dependency inventory and a byte-identical copy of the
third-party notices.

## Upstream-baseline return

Release 0 has no database migration. To return to the exact upstream source
baseline:

```bash
git clone https://github.com/openai/symphony.git openai-symphony-baseline
cd openai-symphony-baseline
git checkout --detach 4cbe3a9699a73b862466c0b157ceca0c1985d6d7
test "$(git symbolic-ref -q HEAD || true)" = ""
test "$(git rev-parse HEAD)" = 4cbe3a9699a73b862466c0b157ceca0c1985d6d7
test "$(git status --porcelain=v1 --untracked-files=all)" = ""
printf '%s  %s\n' \
  fa9d7c252cc72d10afdaf4e46e0d890aae28cf4331dc531c94413bc8ea199452 SPEC.md \
  c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4 LICENSE \
  38c76eb8701e52953f63154a77b407667a6ee34c3a2a8785c8f8b2cd5494d09d NOTICE \
  | sha256sum --check --strict
```

Expected hashes are also recorded in
`docs/releases/v0.1.0/upstream-baseline.md` and the release asset
`upstream-baseline-return.json`.

## Known limitations

- Release 0 retains the original Symphony dashboard rather than the Studio
  product interface.
- Runtime event retention is bounded and in memory; durable Studio projections
  arrive after Release 0.
- Remote workers and non-Codex providers are not supported.
- The packaged `WORKFLOW.md` is the fork owner's validation configuration;
  other users must copy it and replace its non-secret project and repository
  bindings before running.
- Linear and Codex are external services and require the user's own authorized
  accounts. No credential is bundled.
- Only Debian 12 on Linux x86_64 is claimed by this package.
