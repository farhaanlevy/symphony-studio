# Release 0 third-party provenance

Status: **R0-03 accepted; final R0-07 release/SBOM gates pending**

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

## Downstream build-only patch

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

## Acceptance and later release work

- R0-03 passed the complete compile, test, coverage, lint, specs, and Dialyzer
  gate with the vendored source on 2026-07-16. The final source-bound seal
  includes the exact 24-file vendor inventory, and independent runtime/build
  review found no remaining P0/P1/P2 issue.
- R0-07 will include erlexec in the complete SBOM, archive inventory,
  third-party notice check, clean-install build, and downloaded-package hash
  verification.
- Any erlexec version or patch change invalidates this record and the R0-03
  source-bound compatibility seal.
