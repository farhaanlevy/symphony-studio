# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CapabilityDiscoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{CapabilityDiscovery, CapabilityError}
  alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-capability-discovery-#{System.unique_integer([:positive, :monotonic])}"
      )

    cwd = Path.join(root, "repository")
    identity_key_path = Path.join([root, "state", "identity.key"])
    File.mkdir_p!(cwd)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, cwd: cwd, identity_key_path: identity_key_path}
  end

  test "runs one bounded no-model probe with exact request shapes", context do
    parent = self()

    fixture =
      FakeCodex.create!(context.root, [
        expect_initialize(),
        FakeCodex.response(1, FakeCodex.initialize_response()),
        FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
        FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
        FakeCodex.response_for(2, "account/read", chatgpt_account()),
        FakeCodex.expect(
          %{"id" => 3, "method" => "account/rateLimits/read"},
          absent: [["params"]]
        ),
        FakeCodex.response_for(3, "account/rateLimits/read", quota_response()),
        FakeCodex.expect(%{
          "id" => 4,
          "method" => "model/list",
          "params" => %{"includeHidden" => true, "limit" => 100}
        }),
        FakeCodex.response_for(4, "model/list", %{
          "data" => [model("gpt-5.6-sol", ~w(high ultra))],
          "nextCursor" => "opaque-next"
        }),
        FakeCodex.expect(%{
          "id" => 5,
          "method" => "model/list",
          "params" => %{
            "cursor" => "opaque-next",
            "includeHidden" => true,
            "limit" => 100
          }
        }),
        FakeCodex.response_for(5, "model/list", %{
          "data" => [model("gpt-5.6-terra", ~w(medium high))],
          "nextCursor" => nil
        }),
        FakeCodex.expect(%{"id" => 6, "method" => "account/usage/read"},
          absent: [["params"]]
        ),
        FakeCodex.response_error(6, -32_601, "method unavailable: private fixture detail"),
        FakeCodex.expect(%{
          "id" => 7,
          "method" => "experimentalFeature/list",
          "params" => %{"limit" => 100}
        }),
        FakeCodex.response_for(7, "experimentalFeature/list", %{
          "data" => [
            %{
              "defaultEnabled" => true,
              "enabled" => true,
              "name" => "multi_agent",
              "stage" => "stable"
            },
            %{
              "defaultEnabled" => false,
              "enabled" => false,
              "name" => "multi_agent_v2",
              "stage" => "underDevelopment"
            }
          ],
          "nextCursor" => nil
        }),
        FakeCodex.expect(%{"id" => 8, "method" => "collaborationMode/list", "params" => %{}}),
        FakeCodex.response_for(8, "collaborationMode/list", %{
          "data" => [
            %{
              "mode" => "default",
              "model" => "gpt-5.6-sol",
              "name" => "default",
              "reasoning_effort" => "ultra"
            }
          ]
        }),
        FakeCodex.expect(%{"id" => 9, "method" => "account/read", "params" => %{}}),
        FakeCodex.response_for(9, "account/read", chatgpt_account()),
        FakeCodex.exit(0)
      ])

    assert {:ok, result} =
             probe(fixture, context, on_request: fn metadata -> send(parent, {:probe_request, metadata}) end)

    assert result.no_model_work
    assert result.schema_version == "0.144.3"
    assert result.account.auth_mode == :chatgpt
    assert result.account.identity.status == :confirmed
    assert result.account.identity.generation == 1
    assert result.reference_profile.status == :pass
    assert Enum.map(result.models, & &1.model) == ~w(gpt-5.6-sol gpt-5.6-terra)
    assert result.quota.bucket_source == :multi
    assert result.optional.usage == %{status: :unsupported}
    assert result.optional.experimental_features.status == :available
    assert result.optional.collaboration_modes.status == :available

    request_receipts =
      Enum.map(1..9, fn _index ->
        assert_receive {:probe_request, metadata}, 1_000
        metadata
      end)

    assert Enum.map(request_receipts, & &1.method) == [
             "initialize",
             "account/read",
             "account/rateLimits/read",
             "model/list",
             "model/list",
             "account/usage/read",
             "experimentalFeature/list",
             "collaborationMode/list",
             "account/read"
           ]

    assert Enum.map(request_receipts, & &1.classification) == [
             :handshake,
             :idempotent,
             :idempotent,
             :idempotent,
             :idempotent,
             :idempotent,
             :idempotent,
             :idempotent,
             :idempotent
           ]

    assert Enum.all?(request_receipts, fn metadata ->
             Map.keys(metadata) --
               ~w(attempt attempt_id classification method operation_id request_hash request_id run_id send_state)a == []
           end)

    rendered = Jason.encode!(result)
    refute rendered =~ "operator@example.com"
    refute rendered =~ "1234.56"
    refute rendered =~ "private fixture detail"
    refute rendered =~ Path.dirname(context.identity_key_path)

    received = FakeCodex.received!(fixture)

    assert Enum.map(received, & &1["method"]) == [
             "initialize",
             "initialized",
             "account/read",
             "account/rateLimits/read",
             "model/list",
             "model/list",
             "account/usage/read",
             "experimentalFeature/list",
             "collaborationMode/list",
             "account/read"
           ]

    refute Enum.any?(received, fn payload ->
             payload["method"] in [
               "account/rateLimitResetCredit/consume",
               "review/start",
               "thread/start",
               "turn/start"
             ]
           end)

    assert Enum.each(received, &FakeCodex.assert_client_message_valid!/1) == :ok
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "identity key cannot be written into probe or selected-workflow repository roots", context do
    File.mkdir_p!(Path.join(context.root, ".git"))

    unsafe_paths = [
      Path.join([context.root, "sibling-state", "identity.key"]),
      Path.join([Workflow.workflow_directory(), "private-state", "identity.key"])
    ]

    for unsafe_key_path <- unsafe_paths do
      fixture =
        FakeCodex.create!(context.root, [
          expect_initialize(),
          FakeCodex.response(1, FakeCodex.initialize_response()),
          FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
          FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
          FakeCodex.response_for(2, "account/read", chatgpt_account()),
          FakeCodex.exit(0)
        ])

      assert {:error, %CapabilityError{kind: :identity_key_unavailable}} =
               probe(fixture, context, identity_key_path: unsafe_key_path)

      refute File.exists?(unsafe_key_path)
      refute File.exists?(Path.dirname(unsafe_key_path))
      assert :ok = FakeCodex.assert_complete!(fixture)
    end
  end

  test "classifies optional token usage as auth-restricted only for a non-ChatGPT account", context do
    fixture =
      FakeCodex.create!(
        context.root,
        [
          required_prelude(FakeCodex.response_error(3, -32_600, "private quota authentication detail")),
          FakeCodex.expect(%{
            "id" => 4,
            "method" => "model/list",
            "params" => %{"includeHidden" => true, "limit" => 100}
          }),
          FakeCodex.response_for(4, "model/list", %{"data" => [], "nextCursor" => nil}),
          FakeCodex.expect(%{"id" => 5, "method" => "account/usage/read"}, absent: [["params"]]),
          FakeCodex.response_error(5, -32_600, "private authentication detail"),
          FakeCodex.expect(%{
            "id" => 6,
            "method" => "experimentalFeature/list",
            "params" => %{"limit" => 100}
          }),
          FakeCodex.response_error(6, -32_601, "optional feature unavailable"),
          FakeCodex.expect(%{"id" => 7, "method" => "collaborationMode/list", "params" => %{}}),
          FakeCodex.response_error(7, -32_601, "optional collaboration unavailable"),
          FakeCodex.expect(%{"id" => 8, "method" => "account/read", "params" => %{}}),
          FakeCodex.response_for(8, "account/read", api_key_account()),
          FakeCodex.exit(0)
        ]
        |> List.flatten()
      )

    assert {:ok, result} = probe(fixture, context)
    assert result.quota == %{status: :auth_restricted}
    assert result.optional.usage == %{status: :auth_restricted}
    assert result.optional.experimental_features == %{status: :unsupported}
    assert result.optional.collaboration_modes == %{status: :unsupported}
    refute Jason.encode!(result) =~ "private authentication detail"
    refute Jason.encode!(result) =~ "private quota authentication detail"
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "fails closed when the required ChatGPT quota read is rejected", context do
    fixture =
      FakeCodex.create!(context.root, [
        expect_initialize(),
        FakeCodex.response(1, FakeCodex.initialize_response()),
        FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
        FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
        FakeCodex.response_for(2, "account/read", chatgpt_account()),
        FakeCodex.expect(%{"id" => 3, "method" => "account/rateLimits/read"},
          absent: [["params"]]
        ),
        FakeCodex.response_error(3, -32_600, "private required quota detail"),
        FakeCodex.exit(0)
      ])

    assert {:error,
            %CapabilityError{
              kind: :required_method_unavailable,
              method: "account/rateLimits/read"
            } = error} = probe(fixture, context)

    refute inspect(error) =~ "private required quota detail"
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "reports a transient optional telemetry failure without blocking required discovery", context do
    fixture =
      FakeCodex.create!(
        context.root,
        [
          required_prelude(),
          FakeCodex.expect(%{
            "id" => 4,
            "method" => "model/list",
            "params" => %{"includeHidden" => true, "limit" => 100}
          }),
          FakeCodex.response_for(4, "model/list", %{"data" => [], "nextCursor" => nil}),
          FakeCodex.expect(%{"id" => 5, "method" => "account/usage/read"}, absent: [["params"]]),
          FakeCodex.response_error(5, -32_603, "private transient backend detail"),
          FakeCodex.expect(%{
            "id" => 6,
            "method" => "experimentalFeature/list",
            "params" => %{"limit" => 100}
          }),
          FakeCodex.response_error(6, -32_601, "unsupported"),
          FakeCodex.expect(%{"id" => 7, "method" => "collaborationMode/list", "params" => %{}}),
          FakeCodex.response_error(7, -32_601, "unsupported"),
          FakeCodex.expect(%{"id" => 8, "method" => "account/read", "params" => %{}}),
          FakeCodex.response_for(8, "account/read", api_key_account()),
          FakeCodex.exit(0)
        ]
        |> List.flatten()
      )

    assert {:ok, result} = probe(fixture, context)
    assert result.optional.usage == %{status: :unavailable}
    refute Jason.encode!(result) =~ "private transient backend detail"
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "does not relabel a later optional page failure as unsupported", context do
    fixture =
      FakeCodex.create!(
        context.root,
        [
          required_prelude(),
          FakeCodex.expect(%{
            "id" => 4,
            "method" => "model/list",
            "params" => %{"includeHidden" => true, "limit" => 100}
          }),
          FakeCodex.response_for(4, "model/list", %{"data" => [], "nextCursor" => nil}),
          FakeCodex.expect(%{"id" => 5, "method" => "account/usage/read"}, absent: [["params"]]),
          FakeCodex.response_error(5, -32_601, "unsupported"),
          FakeCodex.expect(%{
            "id" => 6,
            "method" => "experimentalFeature/list",
            "params" => %{"limit" => 100}
          }),
          FakeCodex.response_for(6, "experimentalFeature/list", %{
            "data" => [feature("first-page")],
            "nextCursor" => "second-page"
          }),
          FakeCodex.expect(%{
            "id" => 7,
            "method" => "experimentalFeature/list",
            "params" => %{"cursor" => "second-page", "limit" => 100}
          }),
          FakeCodex.response_error(7, -32_601, "inconsistent later failure"),
          FakeCodex.expect(%{"id" => 8, "method" => "collaborationMode/list", "params" => %{}}),
          FakeCodex.response_error(8, -32_601, "unsupported"),
          FakeCodex.expect(%{"id" => 9, "method" => "account/read", "params" => %{}}),
          FakeCodex.response_for(9, "account/read", api_key_account()),
          FakeCodex.exit(0)
        ]
        |> List.flatten()
      )

    assert {:ok, result} = probe(fixture, context)
    assert result.optional.experimental_features == %{status: :unavailable}
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "revalidates account identity after all capability reads", context do
    fixture =
      FakeCodex.create!(
        context.root,
        [
          required_prelude(),
          FakeCodex.expect(%{
            "id" => 4,
            "method" => "model/list",
            "params" => %{"includeHidden" => true, "limit" => 100}
          }),
          FakeCodex.response_for(4, "model/list", %{"data" => [], "nextCursor" => nil}),
          FakeCodex.expect(%{"id" => 5, "method" => "account/usage/read"}, absent: [["params"]]),
          FakeCodex.response_error(5, -32_601, "unsupported"),
          FakeCodex.expect(%{
            "id" => 6,
            "method" => "experimentalFeature/list",
            "params" => %{"limit" => 100}
          }),
          FakeCodex.response_error(6, -32_601, "unsupported"),
          FakeCodex.expect(%{"id" => 7, "method" => "collaborationMode/list", "params" => %{}}),
          FakeCodex.response_error(7, -32_601, "unsupported"),
          FakeCodex.expect(%{"id" => 8, "method" => "account/read", "params" => %{}}),
          FakeCodex.response_for(8, "account/read", %{
            "account" => nil,
            "requiresOpenaiAuth" => true
          }),
          FakeCodex.exit(0)
        ]
        |> List.flatten()
      )

    assert {:error,
            %CapabilityError{
              kind: :identity_changed_during_probe,
              method: "account/read"
            }} = probe(fixture, context)

    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "does not hide invalid-params failures for an optional method", context do
    fixture =
      FakeCodex.create!(
        context.root,
        [
          required_prelude(),
          FakeCodex.expect(%{
            "id" => 4,
            "method" => "model/list",
            "params" => %{"includeHidden" => true, "limit" => 100}
          }),
          FakeCodex.response_for(4, "model/list", %{"data" => [], "nextCursor" => nil}),
          FakeCodex.expect(%{"id" => 5, "method" => "account/usage/read"}, absent: [["params"]]),
          FakeCodex.response_error(5, -32_602, "private invalid params detail"),
          FakeCodex.exit(0)
        ]
        |> List.flatten()
      )

    assert {:error,
            %CapabilityError{
              kind: :optional_method_probe_failed,
              method: "account/usage/read",
              reason: :response_error
            } = error} = probe(fixture, context)

    refute inspect(error) =~ "private invalid params detail"
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "does not hide invalid-request failures for optional probes", context do
    model_list_reply = [
      FakeCodex.expect(%{
        "id" => 4,
        "method" => "model/list",
        "params" => %{"includeHidden" => true, "limit" => 100}
      }),
      FakeCodex.response_for(4, "model/list", %{"data" => [], "nextCursor" => nil})
    ]

    model_reply =
      model_list_reply ++
        [
          FakeCodex.expect(%{"id" => 5, "method" => "account/usage/read"},
            absent: [["params"]]
          ),
          FakeCodex.response_error(5, -32_601, "unsupported")
        ]

    chatgpt_fixture =
      FakeCodex.create!(
        context.root,
        [
          expect_initialize(),
          FakeCodex.response(1, FakeCodex.initialize_response()),
          FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
          FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
          FakeCodex.response_for(2, "account/read", chatgpt_account()),
          FakeCodex.expect(
            %{"id" => 3, "method" => "account/rateLimits/read"},
            absent: [["params"]]
          ),
          FakeCodex.response_for(3, "account/rateLimits/read", %{"rateLimits" => %{}})
        ] ++
          model_list_reply ++
          [
            FakeCodex.expect(%{"id" => 5, "method" => "account/usage/read"},
              absent: [["params"]]
            ),
            FakeCodex.response_error(5, -32_600, "private invalid request detail"),
            FakeCodex.exit(0)
          ]
      )

    assert {:error,
            %CapabilityError{
              kind: :optional_method_probe_failed,
              method: "account/usage/read",
              reason: :invalid_request
            } = chatgpt_error} = probe(chatgpt_fixture, context)

    refute inspect(chatgpt_error) =~ "private invalid request detail"
    assert :ok = FakeCodex.assert_complete!(chatgpt_fixture)

    scenarios = [
      {"experimentalFeature/list",
       [
         FakeCodex.expect(%{
           "id" => 6,
           "method" => "experimentalFeature/list",
           "params" => %{"limit" => 100}
         }),
         FakeCodex.response_error(6, -32_600, "private invalid request detail")
       ]},
      {"collaborationMode/list",
       [
         FakeCodex.expect(%{
           "id" => 6,
           "method" => "experimentalFeature/list",
           "params" => %{"limit" => 100}
         }),
         FakeCodex.response_error(6, -32_601, "unsupported"),
         FakeCodex.expect(%{
           "id" => 7,
           "method" => "collaborationMode/list",
           "params" => %{}
         }),
         FakeCodex.response_error(7, -32_600, "private invalid request detail")
       ]}
    ]

    for {method, scenario} <- scenarios do
      fixture =
        FakeCodex.create!(
          context.root,
          required_prelude() ++ model_reply ++ scenario ++ [FakeCodex.exit(0)]
        )

      assert {:error,
              %CapabilityError{
                kind: :optional_method_probe_failed,
                method: ^method,
                reason: :invalid_request
              } = error} = probe(fixture, context)

      refute inspect(error) =~ "private invalid request detail"
      assert :ok = FakeCodex.assert_complete!(fixture)
    end
  end

  test "rejects malformed probe options and command arguments with typed errors", context do
    assert {:error, %CapabilityError{kind: :invalid_probe_options}} =
             CapabilityDiscovery.probe(:invalid)

    assert {:error, %CapabilityError{kind: :invalid_probe_options}} =
             CapabilityDiscovery.probe([:not_a_keyword])

    assert {:error, %CapabilityError{kind: :codex_command_unavailable}} =
             CapabilityDiscovery.probe(
               command_argv: ["/bin/true", 7],
               cwd: context.cwd,
               identity_key_path: context.identity_key_path
             )
  end

  test "rejects a repeated model cursor and closes the fixture", context do
    fixture =
      FakeCodex.create!(
        context.root,
        required_prelude() ++
          [
            FakeCodex.expect(%{
              "id" => 4,
              "method" => "model/list",
              "params" => %{"includeHidden" => true, "limit" => 100}
            }),
            FakeCodex.response_for(4, "model/list", %{
              "data" => [model("model-page-one", ["high"])],
              "nextCursor" => "cycle"
            }),
            FakeCodex.expect(%{
              "id" => 5,
              "method" => "model/list",
              "params" => %{"cursor" => "cycle", "includeHidden" => true, "limit" => 100}
            }),
            FakeCodex.response_for(5, "model/list", %{
              "data" => [model("model-page-two", ["high"])],
              "nextCursor" => "cycle"
            }),
            FakeCodex.exit(0)
          ]
      )

    assert {:error,
            %CapabilityError{
              kind: :pagination_cycle,
              method: "model/list"
            }} = probe(fixture, context)

    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "rejects model IDs and slugs duplicated across page boundaries", context do
    cases = [
      {
        "duplicate-id",
        model_with_identity("shared-id", "model-page-one"),
        model_with_identity("shared-id", "model-page-two")
      },
      {
        "duplicate-slug",
        model_with_identity("model-id-one", "shared-model"),
        model_with_identity("model-id-two", "shared-model")
      }
    ]

    Enum.each(cases, fn {cursor, first_model, second_model} ->
      fixture =
        FakeCodex.create!(
          context.root,
          required_prelude() ++
            [
              FakeCodex.expect(%{
                "id" => 4,
                "method" => "model/list",
                "params" => %{"includeHidden" => true, "limit" => 100}
              }),
              FakeCodex.response_for(4, "model/list", %{
                "data" => [first_model],
                "nextCursor" => cursor
              }),
              FakeCodex.expect(%{
                "id" => 5,
                "method" => "model/list",
                "params" => %{"cursor" => cursor, "includeHidden" => true, "limit" => 100}
              }),
              FakeCodex.response_for(5, "model/list", %{
                "data" => [second_model],
                "nextCursor" => nil
              }),
              FakeCodex.exit(0)
            ]
        )

      assert {:error,
              %CapabilityError{
                kind: :duplicate_capability,
                method: "model/list"
              }} = probe(fixture, context)

      assert :ok = FakeCodex.assert_complete!(fixture)
    end)
  end

  test "rejects a feature name duplicated across page boundaries", context do
    fixture =
      FakeCodex.create!(
        context.root,
        required_prelude() ++
          [
            FakeCodex.expect(%{
              "id" => 4,
              "method" => "model/list",
              "params" => %{"includeHidden" => true, "limit" => 100}
            }),
            FakeCodex.response_for(4, "model/list", %{"data" => [], "nextCursor" => nil}),
            FakeCodex.expect(%{"id" => 5, "method" => "account/usage/read"},
              absent: [["params"]]
            ),
            FakeCodex.response_error(5, -32_601, "unsupported"),
            FakeCodex.expect(%{
              "id" => 6,
              "method" => "experimentalFeature/list",
              "params" => %{"limit" => 100}
            }),
            FakeCodex.response_for(6, "experimentalFeature/list", %{
              "data" => [feature("shared-feature")],
              "nextCursor" => "feature-page-two"
            }),
            FakeCodex.expect(%{
              "id" => 7,
              "method" => "experimentalFeature/list",
              "params" => %{"cursor" => "feature-page-two", "limit" => 100}
            }),
            FakeCodex.response_for(7, "experimentalFeature/list", %{
              "data" => [feature("shared-feature")],
              "nextCursor" => nil
            }),
            FakeCodex.exit(0)
          ]
      )

    assert {:error,
            %CapabilityError{
              kind: :duplicate_capability,
              method: "experimentalFeature/list"
            }} = probe(fixture, context)

    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "rejects a model catalog that exceeds the total item bound", context do
    pages =
      Enum.flat_map(0..4, fn page ->
        request_id = 4 + page
        cursor = if page == 0, do: nil, else: "page-#{page}"
        next_cursor = if page == 4, do: nil, else: "page-#{page + 1}"

        params =
          %{"includeHidden" => true, "limit" => 100}
          |> then(fn params -> if cursor, do: Map.put(params, "cursor", cursor), else: params end)

        models =
          Enum.map(1..250, fn item ->
            model("catalog-#{page}-#{item}", ["high"])
          end)

        [
          FakeCodex.expect(%{"id" => request_id, "method" => "model/list", "params" => params}),
          FakeCodex.response_for(request_id, "model/list", %{
            "data" => models,
            "nextCursor" => next_cursor
          })
        ]
      end)

    fixture =
      FakeCodex.create!(context.root, required_prelude() ++ pages ++ [FakeCodex.exit(0)])

    assert {:error,
            %CapabilityError{
              kind: :pagination_limit_exceeded,
              method: "model/list"
            }} = probe(fixture, context)

    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "accepts exactly sixteen small model pages and performs final account revalidation", context do
    pages = model_page_steps(16)
    next_request_id = 20

    fixture =
      FakeCodex.create!(
        context.root,
        required_prelude() ++
          pages ++ optional_unsupported_tail(next_request_id) ++ [FakeCodex.exit(0)]
      )

    assert {:ok, result} = probe(fixture, context)
    assert length(result.models) == 16
    assert result.account.auth_mode == :api_key
    assert result.account.identity.status == :unconfirmed
    assert result.optional.usage == %{status: :unsupported}
    assert result.optional.experimental_features == %{status: :unsupported}
    assert result.optional.collaboration_modes == %{status: :unsupported}
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "rejects a seventeenth model page independently of the item bound", context do
    fixture =
      FakeCodex.create!(
        context.root,
        required_prelude() ++
          model_page_steps(16, final_cursor: "model-page-17") ++ [FakeCodex.exit(0)]
      )

    assert {:error,
            %CapabilityError{
              kind: :pagination_limit_exceeded,
              method: "model/list"
            }} = probe(fixture, context)

    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  defp probe(fixture, context, opts \\ []) do
    base = [
      command_argv: fixture.argv,
      cwd: context.cwd,
      identity_key_path: context.identity_key_path
    ]

    CapabilityDiscovery.probe(Keyword.merge(base, opts))
  end

  defp required_prelude(quota_reply \\ FakeCodex.response_for(3, "account/rateLimits/read", %{"rateLimits" => %{}})) do
    [
      expect_initialize(),
      FakeCodex.response(1, FakeCodex.initialize_response()),
      FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
      FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
      FakeCodex.response_for(2, "account/read", api_key_account()),
      FakeCodex.expect(
        %{"id" => 3, "method" => "account/rateLimits/read"},
        absent: [["params"]]
      ),
      quota_reply
    ]
  end

  defp expect_initialize do
    FakeCodex.expect(%{"id" => 1, "method" => "initialize"}, match: :subset)
  end

  defp chatgpt_account do
    %{
      "account" => %{
        "email" => "operator@example.com",
        "planType" => "pro",
        "type" => "chatgpt"
      },
      "requiresOpenaiAuth" => true
    }
  end

  defp api_key_account do
    %{
      "account" => %{"type" => "apiKey"},
      "requiresOpenaiAuth" => false
    }
  end

  defp quota_response do
    %{
      "rateLimits" => %{},
      "rateLimitsByLimitId" => %{
        "opaque-limit" => %{
          "credits" => %{
            "balance" => "1234.56",
            "hasCredits" => true,
            "unlimited" => false
          },
          "limitId" => "opaque-limit",
          "primary" => %{"usedPercent" => 42}
        }
      }
    }
  end

  defp model(slug, efforts) do
    %{
      "defaultReasoningEffort" => hd(efforts),
      "description" => "Fixture model",
      "displayName" => slug,
      "hidden" => false,
      "id" => slug,
      "isDefault" => slug == "gpt-5.6-sol",
      "model" => slug,
      "supportedReasoningEfforts" => Enum.map(efforts, &%{"description" => "Fixture effort", "reasoningEffort" => &1})
    }
  end

  defp model_with_identity(id, slug) do
    slug
    |> model(["high"])
    |> Map.put("id", id)
  end

  defp model_page_steps(count, opts \\ []) do
    final_cursor = Keyword.get(opts, :final_cursor)

    Enum.flat_map(1..count, fn page ->
      request_id = page + 3
      cursor = if page == 1, do: nil, else: "model-page-#{page}"
      next_cursor = if page == count, do: final_cursor, else: "model-page-#{page + 1}"

      params = model_page_params(cursor)

      [
        FakeCodex.expect(%{"id" => request_id, "method" => "model/list", "params" => params}),
        FakeCodex.response_for(request_id, "model/list", %{
          "data" => [model("page-bound-model-#{page}", ["high"])],
          "nextCursor" => next_cursor
        })
      ]
    end)
  end

  defp model_page_params(nil), do: %{"includeHidden" => true, "limit" => 100}

  defp model_page_params(cursor),
    do: %{"cursor" => cursor, "includeHidden" => true, "limit" => 100}

  defp optional_unsupported_tail(request_id) do
    [
      FakeCodex.expect(%{"id" => request_id, "method" => "account/usage/read"},
        absent: [["params"]]
      ),
      FakeCodex.response_error(request_id, -32_601, "unsupported"),
      FakeCodex.expect(%{
        "id" => request_id + 1,
        "method" => "experimentalFeature/list",
        "params" => %{"limit" => 100}
      }),
      FakeCodex.response_error(request_id + 1, -32_601, "unsupported"),
      FakeCodex.expect(%{
        "id" => request_id + 2,
        "method" => "collaborationMode/list",
        "params" => %{}
      }),
      FakeCodex.response_error(request_id + 2, -32_601, "unsupported"),
      FakeCodex.expect(%{"id" => request_id + 3, "method" => "account/read", "params" => %{}}),
      FakeCodex.response_for(request_id + 3, "account/read", api_key_account())
    ]
  end

  defp feature(name) do
    %{
      "defaultEnabled" => false,
      "enabled" => false,
      "name" => name,
      "stage" => "stable"
    }
  end
end
