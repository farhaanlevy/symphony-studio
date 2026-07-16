# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

import Config

# `mix test` starts the application before loading test/test_helper.exs. Keep
# the initial WorkflowStore and Orchestrator on the hermetic memory tracker so
# no startup poll can fall back to the repository's real Linear workflow.
config :symphony_elixir,
  workflow_file_path: Path.expand("../test/support/network_hermetic_workflow.md", __DIR__),
  codex_child_environment_allowlist: [
    "SYMP_TEST_CODEx_TRACE",
    "SYMP_TEST_CODex_TRACE",
    "SYMP_TEST_SSH_TRACE"
  ]

# The fixture sealer runs this exact config from a read-only source snapshot and
# supplies a private writable runtime path for OTP's disk logger.
if fixture_log_file = System.get_env("SYMPHONY_FIXTURE_LOG_FILE") do
  config :symphony_elixir, log_file: fixture_log_file
end
