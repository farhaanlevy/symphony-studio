# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.CodexSchemaBundleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.SchemaBundle
  alias SymphonyElixir.Config.Schema, as: ConfigSchema

  @test_manifest_env "SYMPHONY_CODEX_SCHEMA_TEST_MANIFEST"
  @sha256_regex ~r/\A[0-9a-f]{64}\z/

  @required_methods MapSet.new([
                      "initialize",
                      "initialized",
                      "account/read",
                      "account/rateLimits/read",
                      "model/list",
                      "thread/start",
                      "thread/resume",
                      "turn/start",
                      "turn/interrupt",
                      "review/start",
                      "account/rateLimits/updated",
                      "account/updated",
                      "thread/status/changed",
                      "turn/started",
                      "turn/completed",
                      "item/started",
                      "item/completed",
                      "thread/tokenUsage/updated",
                      "serverRequest/resolved",
                      "error",
                      "item/commandExecution/requestApproval",
                      "item/fileChange/requestApproval",
                      "execCommandApproval",
                      "applyPatchApproval",
                      "item/permissions/requestApproval",
                      "item/tool/requestUserInput",
                      "mcpServer/elicitation/request"
                    ])

  test "pinned manifest and matrix expose the source-bound compatibility contract" do
    assert SchemaBundle.version() == "0.144.3"
    assert File.dir?(SchemaBundle.bundle_path())

    assert {:ok, manifest} = manifest()
    assert get_in(manifest, ["codex", "versionOutput"]) == "codex-cli 0.144.3"

    assert get_in(manifest, ["codex", "executable", "installedPackageAlias"]) ==
             "@openai/codex-linux-x64"

    assert get_in(manifest, ["codex", "executable", "platformPackage"]) ==
             "@openai/codex@0.144.3-linux-x64"

    assert get_in(manifest, ["artifacts", "json", "fileCount"]) == 267
    assert get_in(manifest, ["artifacts", "typescript", "fileCount"]) == 598
    assert get_in(manifest, ["artifacts", "experimentalJson", "fileCount"]) == 337
    assert get_in(manifest, ["artifacts", "experimentalTypescript", "fileCount"]) == 671
    assert get_in(manifest, ["compatibility", "overall"]) == "pending_r0_06"

    assert compatibility = manifest["compatibility"]
    assert compatibility["schemaContract"] == "pass"

    expected_fixture_status =
      if System.get_env(@test_manifest_env), do: "under_test", else: "pass"

    assert compatibility["fixtures"] == expected_fixture_status

    expected_test_count =
      case {compatibility["fixtures"], compatibility["transportConformance"]} do
        {"pass", "not_run"} -> 55
        {status, status} when status in ["under_test", "pass"] -> 276
        statuses -> flunk("unexpected fixture/transport transition state: #{inspect(statuses)}")
      end

    if System.get_env(@test_manifest_env) do
      expected_log_file = Path.join(System.fetch_env!("TMPDIR"), "symphony.log")
      assert System.fetch_env!("SYMPHONY_FIXTURE_LOG_FILE") == expected_log_file
      assert Application.fetch_env!(:symphony_elixir, :log_file) == expected_log_file
      assert {:ok, handler} = :logger.get_handler_config(:symphony_disk_log)
      assert handler.config.file |> List.to_string() |> Path.expand() == expected_log_file
    end

    assert compatibility["fixtureEvidence"]["sourceFileCount"] >= 50

    assert compatibility["fixtureEvidence"]["sourceHashAlgorithm"] ==
             "sha256-text-lf-binary-raw-relative-path-v2"

    evidence = compatibility["fixtureEvidence"]
    assert evidence["sourceSha256"] =~ @sha256_regex
    assert evidence["testCount"] == expected_test_count

    assert evidence["dependencyCommand"] == [
             "mise",
             "exec",
             "--",
             "mix",
             "deps.get",
             "--check-locked"
           ]

    assert evidence["dependencyCompileCommand"] == [
             "mise",
             "exec",
             "--",
             "mix",
             "deps.compile"
           ]

    assert evidence["codexVersion"] == get_in(manifest, ["codex", "version"])
    assert evidence["artifactBundleSha256"] == get_in(manifest, ["artifacts", "artifactBundleSha256"])
    assert evidence["schemaBundleSha256"] == get_in(manifest, ["artifacts", "schemaBundleSha256"])
    assert evidence["matrixSha256"] == get_in(manifest, ["matrix", "sha256"])
    assert evidence["artifactBundleSha256"] =~ @sha256_regex
    assert evidence["schemaBundleSha256"] =~ @sha256_regex
    assert evidence["matrixSha256"] =~ @sha256_regex
    assert compatibility["runtimeCapabilities"] == "not_run"

    assert {:ok, matrix} = SchemaBundle.matrix()
    assert matrix["r002Status"] == "schema_only"
    assert matrix["r006Status"] == "pending"
    assert length(matrix["methods"]) == 43
    assert length(matrix["fields"]) == 302
    assert length(matrix["definitionEqualities"]) == 6
    assert length(matrix["negativeCapabilities"]) == 3

    required_methods =
      matrix["methods"]
      |> Enum.filter(&(&1["requirement"] == "required"))
      |> MapSet.new(& &1["method"])

    assert MapSet.subset?(@required_methods, required_methods)
    assert Enum.any?(matrix["methods"], &(&1["method"] == "collaborationMode/list"))
    assert Enum.any?(matrix["fields"], &(&1["id"] == "account.type.chatgpt"))
    assert Enum.any?(matrix["fields"], &(&1["id"] == "account.type.api_key"))
    assert Enum.any?(matrix["fields"], &(&1["id"] == "models.service_tier_id"))

    assert Enum.any?(matrix["fields"], fn field ->
             field["id"] == "turn_start.multi_agent_mode" and
               field["r002Assertion"] == "present_but_deprecated_ignored" and
               field["descriptionContains"] == "@deprecated Ignored" and
               field["r006Probe"] == "conformance"
           end)

    assert Enum.any?(matrix["fields"], fn field ->
             field["id"] == "thread_start.multi_agent_mode" and
               field["r002Assertion"] == "present_but_deprecated_ignored" and
               field["r006Probe"] == "conformance"
           end)

    assert Enum.any?(matrix["fields"], fn field ->
             field["id"] == "dynamic_tool.response_content_items" and
               field["schemaRequired"] == true
           end)

    assert Enum.any?(matrix["fields"], fn field ->
             field["id"] == "turn_start.workspace_write_exclude_slash_tmp" and
               field["schemaRequired"] == false
           end)

    assert Enum.any?(matrix["fields"], fn field ->
             field["id"] == "notifications.item_started_item" and
               field["schemaRequired"] == true
           end)

    assert Enum.any?(matrix["negativeCapabilities"], fn capability ->
             capability["id"] == "collaboration.no_multi_agent_v2" and
               capability["expect"] == "absent"
           end)

    assert Enum.any?(matrix["negativeCapabilities"], fn capability ->
             capability["id"] == "dynamic_tool.no_legacy_output_response_field" and
               capability["expect"] == "absent"
           end)
  end

  test "schemas load through a path-safe bundle boundary" do
    assert {:ok, turn_start} = SchemaBundle.schema("json/v2/TurnStartParams.json")
    assert turn_start["required"] == ["input", "threadId"]
    assert Map.has_key?(turn_start["properties"], "clientUserMessageId")

    assert {:ok, review} = SchemaBundle.schema("json/v2/ReviewStartParams.json")
    assert get_in(review, ["definitions", "ReviewDelivery", "enum"]) == ["inline", "detached"]

    assert {:error, :absolute_schema_path} = SchemaBundle.schema("/tmp/schema.json")
    assert {:error, :schema_path_escape} = SchemaBundle.schema("../../manifest.json")
    assert {:error, :enoent} = SchemaBundle.schema("json/missing.json")
  end

  test "pinned granular approval policy accepts only supported boolean flags" do
    policy = %{
      "sandbox_approval" => false,
      "rules" => true,
      "mcp_elicitations" => false,
      "skill_approval" => false,
      "request_permissions" => false
    }

    assert ConfigSchema.validate_approval_policy(:approval_policy, %{"granular" => policy}) == []

    assert ConfigSchema.validate_approval_policy(:approval_policy, %{"granular" => "never"}) == [
             approval_policy: "approval policy flags must be a map"
           ]
  end

  test "committed metadata contains no checkout path or credential-shaped value" do
    metadata =
      ["manifest.json", "method-field-matrix.json"]
      |> Enum.map_join("\n", fn relative ->
        SchemaBundle.bundle_path()
        |> Path.join(relative)
        |> File.read!()
      end)

    refute metadata =~ "/home/"
    refute metadata =~ "\\Users\\"
    refute metadata =~ "sk-proj-"
    refute metadata =~ "Bearer "

    typescript =
      SchemaBundle.bundle_path()
      |> Path.join("typescript/ClientRequest.ts")
      |> File.read!()

    assert typescript =~ "GENERATED CODE"
  end

  defp manifest do
    case System.get_env(@test_manifest_env) do
      nil ->
        SchemaBundle.manifest()

      test_manifest_path ->
        with {:ok, contents} <- File.read(test_manifest_path),
             {:ok, value} when is_map(value) <- Jason.decode(contents) do
          {:ok, value}
        else
          {:ok, _other} -> {:error, :expected_json_object}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
