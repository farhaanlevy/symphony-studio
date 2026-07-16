# Symphony Studio erlexec patch

This directory vendors the complete source distribution of `erlexec` 2.3.4
from Hex. The upstream code is licensed under a three-clause BSD license; see `LICENSE` in
this directory.

The exact package was originally resolved with these Mix lock values:

- package checksum: `91e8374e269d82cce0d5cbb47ebc8a4810d56474a767a5575ab22b40cf6ff5f9`
- registry checksum: `ab0c6c3569a9f991fbfe6624961a88688610738589ff9dbad24db9bb27ae233b`
- source: <https://hex.pm/packages/erlexec/2.3.4>
- upstream: <https://github.com/saleyn/erlexec/tree/2.3.4>

Symphony Studio carries two build-only patches:

1. In `c_src/Makefile`, keep `EXE_OUTPUT` relative to the `c_src` working
   directory and quote the clean, output, and output-directory recipe
   arguments.
2. In `rebar.config`, remove the `rebar3_hex` and `rebar3_ex_doc` publisher
   plugins plus their Hex documentation configuration. Those plugins are used
   to publish the upstream package and generate package documentation; they are
   not needed to compile or run `erlexec` as a vendored Mix path dependency.

Upstream's default expands the absolute repository path into a Make target.
GNU Make tokenizes that target when the checkout path contains spaces, and the
unquoted shell recipe also fails on parentheses. The relative target preserves
the same output location while making builds reproducible from supported paths
such as `Symphony Studio (OpenAI build-week)`.

Removing the publisher-only plugins keeps dependency compilation offline and
prevents a runtime build from resolving tools that are outside the vendored
source inventory. The upstream README, license, changelog, and source files
remain present in the vendored distribution.

No runtime source behavior is changed.

The helper remains an ordinary unprivileged build artifact. Symphony Studio
does not expose erlexec's privileged user-switching, resource-limit, or
helper-path controls to WORKFLOW or user jobs. The helper path and startup
options are trusted operator/runtime configuration. Runtime preparation accepts
only the exact bundled helper or a validated, trusted operator-preconfigured
absolute regular executable in `:erlexec, :portexe`.
