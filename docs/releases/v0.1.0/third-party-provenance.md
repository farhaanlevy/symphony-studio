# Release 0 third-party provenance

Status: **R0-03 vendoring accepted; R0-07 runtime-closure implementation
prepared; final gates and publication pending**

## Release runtime closure

Release 0's production closure is declared in
[`runtime-dependencies.json`](runtime-dependencies.json). It binds 31 runtime
components to the exact 34 applications expected in the normalized escript:
the Symphony application, 29 locked Hex runtime components, the bundled
Elixir/EEx/Logger applications, and vendored erlexec. Erlang/OTP is an
external runtime rather than an archive payload; the supported build and run
version is exactly **OTP 28.5**. Development and test-only lock entries are
not represented as shipped runtime dependencies.

The release builder fails closed unless the runtime manifest, `mix.lock`,
license sources, exact committed [`THIRD_PARTY_NOTICES.txt`](../../../THIRD_PARTY_NOTICES.txt),
pinned Elixir 1.19.5 license, vendored erlexec license, and installed OTP 28.5
agree. It then verifies the exact application names and versions inside the
normalized escript. The install archive contains the committed runtime
manifest and notices, and the standalone notice asset must be byte-identical
to the archived copy.

The generated SPDX 2.3 SBOM has one Symphony Studio root package and one
package for every other bundled application. It records the declared and
concluded SPDX license, locked Hex content checksum and registry checksum,
package URL, scope, and any build-only patch record. `NOASSERTION` and
development/test packages are rejected. Package verification reconstructs
the expected SBOM from the merged commit and compares the complete canonical
document; clean-install verification repeats the notice, manifest, escript,
and checksum checks before publication.

## Exact dependency build-only determinism patches

OTP 28 exposed nondeterministic compile-time map or AST ordering in three
locked production dependencies. The release build applies only these exact
patches to freshly fetched, temporary dependency sources:

| Dependency | File | Original SHA-256 | Patched SHA-256 | Purpose |
|---|---|---|---|---|
| Bandit 1.10.3 | `lib/bandit.ex` | `3a7bde4381c7ecd4932933671c1de39a987ab92cd32547664f38e877a484b21b` | `c082ceeda7be22095447b9bb55ac617e9aef0aea47198d97ebbb38a7c357f8cd` | Sort compile-time server-option keys under OTP 28. |
| Mint 1.7.1 | `lib/mint/http2/frame.ex` | `c07a9fa324667c2b94392874291c9b74bd254b0e9dcb3a6068bf40b5e52c3d95` | `3c18b8ed239a8c305b8299da808347135a56df4b01a4ec3ecea00a417ffdf394` | Sort compile-time HTTP/2 type and flag maps under OTP 28. |
| Phoenix LiveView 1.1.25 | `lib/phoenix_live_view/engine.ex` | `9ed8b388cc3b09dafefb9eb2dd6eda3bfec4a03e85c594d458a9f5c557d16b03` | `f0d300bb72625e1cc0c7f5e7a7e1b1421c55902770aea518fa6393d5072fed64` | Remove nondeterministic AST metadata from HEEx fingerprints under OTP 28. |

The patcher proves the locked dependency name and version, an owner-controlled
regular non-symlink source path, the exact original file hash, exactly one
match for each declared replacement, and the exact resulting file hash before
compilation. A mismatch aborts the release. The builder uses deterministic
compiler options, performs two isolated clean builds at the same exclusive
fixed path, normalizes both escripts, validates their runtime application
inventories, and requires byte-identical outputs. The six-field patch records
(`dependency`, `version`, `path`, original hash, patched hash, and purpose)
are reproduced in `provenance.json` and in the affected SBOM package comments.

## Vendored erlexec

- Package: `erlexec` 2.3.4
- Purpose: shell-free App Server argv ownership and stdio transport for the
  local Codex containment adapter
- Hex release: <https://hex.pm/packages/erlexec/2.3.4>
- Upstream tag: <https://github.com/saleyn/erlexec/tree/2.3.4>
- Hex package checksum:
  `91e8374e269d82cce0d5cbb47ebc8a4810d56474a767a5575ab22b40cf6ff5f9`
- Hex registry checksum:
  `ab0c6c3569a9f991fbfe6624961a88688610738589ff9dbad24db9bb27ae233b`
- Vendored source inventory: 24 non-ignored source/metadata files
- Repository-path-bound source inventory SHA-256:
  `df41fcbc2eb8b06bb1bae60386a8b9273cc6bc25b4e16a45a30c7a9b8dc7b4b2`
- Vendor-root-relative schema-tool source proof: 317,091 bytes; SHA-256
  `604b313f10bd73f5da0a509e0ea8c5517a29a343bc6e821c38d39c7a9e74c539`
- Shipped license SHA-256:
  `4fa3fe63742b9f9fe89e4fe7e4ec52f3775c8cb78480ca455e57b9d64b04976f`

The repository-path-bound hash is computed from sorted SHA-256 records whose
paths include the `elixir/vendor/erlexec/` prefix. The separate schema-tool
proof uses the same ordered 24 files with paths relative to the vendor root and
also binds the total byte count. The schema tool enforces that exact inventory
in both the read-only fixture snapshot and its writable runtime copy. Ignored
`_build`, object, dependency, and compiled `exec-port` artifacts are not source
inputs and are not committed.

Root `.gitattributes` exempts only ten unchanged upstream files from Git's
whitespace diagnostic, avoiding any need to edit or normalize their verified
bytes merely to satisfy that gate. Their staged blobs remain byte-identical to
the Hex package. Downstream-authored `SYMPHONY_PATCH.md` and the two patched
build files remain under the ordinary whitespace check.

The package metadata labels the license `BSD-2-Clause`, while the shipped
`LICENSE` contains three numbered conditions, including the no-endorsement
condition. Symphony Studio conservatively retains the complete shipped license
verbatim in `elixir/vendor/erlexec/LICENSE`; root `NOTICE` reproduces its
copyright notice, all three conditions, and disclaimer. It does not rely on the
shorter metadata label.

## Vendored erlexec build-only patch

[`elixir/vendor/erlexec/SYMPHONY_PATCH.md`](../../../elixir/vendor/erlexec/SYMPHONY_PATCH.md)
records the complete patch and upstream checksums. The patch:

1. makes the native Make target relative and quotes output paths so a checkout
   containing spaces and parentheses builds deterministically; and
2. removes upstream publisher/documentation plugins that are unnecessary for
   an offline path-dependency build.

No erlexec runtime source behavior is changed. The helper is built as an
ordinary unprivileged artifact. Symphony Studio does not enable erlexec's
SUID, user-switching, capability, or resource-limit modes, and exposes no
WORKFLOW or user-job helper-path setting. Runtime preparation accepts only the
exact bundled helper or a trusted operator-preconfigured absolute, regular,
executable `:erlexec, :portexe` path. The long-lived `exec-port` startup remains
an upstream trusted-runtime boundary; per-attempt App Server argv execution is
the shell-free boundary proven by R0-03.

## Acceptance and remaining release work

- R0-03 passed the complete compile, test, coverage, lint, specs, and Dialyzer
  gate with the vendored source on 2026-07-16. The final source-bound seal
  includes the exact 24-file vendor inventory, and independent runtime/build
  review found no remaining P0/P1/P2 issue.
- The R0-07 candidate now includes erlexec and the complete production closure
  in its SBOM, archive inventory, third-party notices, clean-install checks,
  and downloaded-package verification. These are implemented candidate
  controls, not yet accepted or published release results.
- Any erlexec version or patch change invalidates this record and the R0-03
  source-bound compatibility seal.
- R0-07 remains pending until the coherent candidate passes the complete gate,
  current package and supported-platform clean-install rehearsal, two fresh
  independent reviews, protected pull request and auto-merge, immutable
  publication, and downloaded-asset checksum and attestation verification.
