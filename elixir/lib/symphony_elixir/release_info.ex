# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.ReleaseInfo do
  @moduledoc """
  Public build provenance embedded in the installable Symphony executable.

  Release packaging supplies these non-secret values at compile time. Ordinary
  development builds remain explicit rather than pretending to be a published
  artifact.
  """

  @version System.get_env("SYMPHONY_BUILD_VERSION", "0.1.0-dev")
  @commit System.get_env("SYMPHONY_BUILD_COMMIT", "development")
  @upstream_base System.get_env("SYMPHONY_BUILD_UPSTREAM_BASE", "development")
  @codex_compatibility_hash System.get_env(
                              "SYMPHONY_BUILD_CODEX_COMPATIBILITY_SHA256",
                              "development"
                            )
  @provenance System.get_env("SYMPHONY_BUILD_PROVENANCE", "local-unverified")

  @doc "Returns the public, non-secret build identity embedded at compile time."
  @spec as_map() :: %{required(String.t()) => String.t()}
  def as_map do
    %{
      "codexCompatibilitySha256" => @codex_compatibility_hash,
      "commit" => @commit,
      "provenance" => @provenance,
      "upstreamBase" => @upstream_base,
      "version" => @version
    }
  end

  @doc "Formats the build identity for `symphony --version`."
  @spec format() :: String.t()
  def format do
    info = as_map()

    [
      "Symphony #{info["version"]}",
      "commit: #{info["commit"]}",
      "upstream-base: #{info["upstreamBase"]}",
      "codex-compatibility-sha256: #{info["codexCompatibilitySha256"]}",
      "provenance: #{info["provenance"]}"
    ]
    |> Enum.join("\n")
  end
end
