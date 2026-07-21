# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CapabilityDecoderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.{CapabilityDecoder, CapabilityError, SchemaBundle}

  test "decodes initialize metadata without returning the Codex home" do
    response =
      schema_valid!(
        %{
          "codexHome" => "/home/private/.codex",
          "platformFamily" => "unix",
          "platformOs" => "linux",
          "userAgent" => "codex_app_server/0.144.3"
        },
        "json/v1/InitializeResponse.json"
      )

    assert {:ok,
            %{
              codex_home_absolute: true,
              platform_family: "unix",
              platform_os: "linux",
              user_agent: "codex_app_server/0.144.3"
            } = decoded} = CapabilityDecoder.initialize(response)

    refute inspect(decoded) =~ "/home/private"

    assert {:error,
            %CapabilityError{
              kind: :invalid_response_shape,
              method: "initialize",
              reason: :invalid_absolute_path
            }} = CapabilityDecoder.initialize(%{response | "codexHome" => "relative"})
  end

  test "canonicalizes account modes and never returns raw ChatGPT identity metadata" do
    key = :crypto.strong_rand_bytes(32)
    parent = self()

    chatgpt =
      schema_valid!(
        %{
          "account" => %{
            "type" => "chatgpt",
            "email" => "Operator@Example.COM",
            "planType" => "pro"
          },
          "requiresOpenaiAuth" => true
        },
        "json/v2/GetAccountResponse.json"
      )

    assert {:ok, decoded} =
             CapabilityDecoder.account(
               chatgpt,
               fn ->
                 send(parent, :identity_key_requested)
                 {:ok, key}
               end,
               4
             )

    assert_received :identity_key_requested
    assert decoded.auth_mode == :chatgpt
    assert decoded.authenticated
    assert decoded.plan_type == "pro"
    assert decoded.requires_openai_auth
    assert decoded.identity.status == :confirmed
    assert decoded.identity.generation == 4
    refute Jason.encode!(decoded) =~ "Operator@Example.COM"
    refute Map.has_key?(decoded, :email)

    api_key =
      schema_valid!(
        %{"account" => %{"type" => "apiKey"}, "requiresOpenaiAuth" => false},
        "json/v2/GetAccountResponse.json"
      )

    assert {:ok, %{auth_mode: :api_key, identity: %{status: :unconfirmed}}} =
             CapabilityDecoder.account(api_key, fn -> flunk("key provider must remain lazy") end)

    assert {:ok, %{auth_mode: :unavailable, authenticated: false}} =
             CapabilityDecoder.account(
               %{"account" => nil, "requiresOpenaiAuth" => true},
               fn -> flunk("key provider must remain lazy") end
             )

    assert {:ok, %{auth_mode: :unsupported, authenticated: true}} =
             CapabilityDecoder.account(
               %{
                 "account" => %{
                   "type" => "amazonBedrock",
                   "credentialSource" => "awsManaged"
                 },
                 "requiresOpenaiAuth" => false
               },
               fn -> flunk("key provider must remain lazy") end
             )

    assert {:error, %CapabilityError{reason: :missing_required_field}} =
             CapabilityDecoder.account(
               %{
                 "account" => %{"type" => "chatgpt", "planType" => "pro"},
                 "requiresOpenaiAuth" => true
               },
               fn -> flunk("key provider must not run for malformed account") end
             )
  end

  test "fails closed when account identity key creation is unavailable" do
    response = %{
      "account" => %{"type" => "chatgpt", "email" => "operator@example.com", "planType" => "plus"},
      "requiresOpenaiAuth" => true
    }

    assert {:error,
            %CapabilityError{
              kind: :invalid_response_shape,
              method: "account/read",
              reason: :identity_key_unavailable
            }} = CapabilityDecoder.account(response, fn -> {:error, :raw_private_failure} end)

    refute inspect(CapabilityDecoder.account(response, fn -> {:error, :raw_private_failure} end)) =~
             "operator@example.com"
  end

  test "normalizes account updates and requires identity revalidation without exposing metadata" do
    for {auth_mode, expected} <- [
          {"apikey", :api_key},
          {"chatgpt", :chatgpt},
          {"personalAccessToken", :unsupported}
        ] do
      response =
        schema_valid!(
          %{"authMode" => auth_mode, "planType" => if(auth_mode == "chatgpt", do: "pro", else: nil)},
          "json/v2/AccountUpdatedNotification.json"
        )

      assert {:ok,
              %{
                auth_mode: ^expected,
                authenticated: true,
                identity_binding_action: :revalidate
              }} = CapabilityDecoder.account_updated(response)
    end

    assert {:ok,
            %{
              auth_mode: :unavailable,
              authenticated: false,
              identity_binding_action: :invalidate,
              plan_type: nil
            }} =
             CapabilityDecoder.account_updated(%{"authMode" => nil, "planType" => nil})

    assert {:error, %CapabilityError{reason: :missing_required_field}} =
             CapabilityDecoder.account_updated(%{"authMode" => "apikey"})

    assert {:error, %CapabilityError{reason: :invalid_enum}} =
             CapabilityDecoder.account_updated(%{"authMode" => "unknown", "planType" => nil})
  end

  test "decodes opaque model efforts and service tiers and evaluates the reference profile" do
    response =
      schema_valid!(
        %{
          "data" => [
            model("gpt-5.6-sol", ~w(high ultra), [
              %{"id" => "tier-provider-7", "name" => "Rapid", "description" => "Provider tier"}
            ]),
            model("gpt-5.6-terra", ~w(medium high), [])
          ],
          "nextCursor" => "opaque-page-2"
        },
        "json/v2/ModelListResponse.json"
      )

    assert {:ok, %{items: models, next_cursor: "opaque-page-2"}} =
             CapabilityDecoder.model_page(response)

    assert [sol, terra] = models
    assert sol.model == "gpt-5.6-sol"
    assert sol.reasoning_efforts == ~w(high ultra)
    assert sol.service_tiers == [%{id: "tier-provider-7", name: "Rapid"}]
    assert terra.model == "gpt-5.6-terra"

    account = %{
      auth_mode: :chatgpt,
      authenticated: true,
      identity: %{status: :confirmed}
    }

    assert %{
             chatgpt_authentication: true,
             identity_binding: true,
             sol_available: true,
             sol_review_effort: true,
             sol_ultra: true,
             status: :pass,
             terra_available: true,
             terra_high: true,
             terra_medium: true
           } = CapabilityDecoder.reference_profile(models, account)

    assert %{status: :fail, chatgpt_authentication: false} =
             CapabilityDecoder.reference_profile(models, %{
               auth_mode: :api_key,
               authenticated: true,
               identity: %{status: :unconfirmed}
             })

    assert %{status: :fail, chatgpt_authentication: true, identity_binding: false} =
             CapabilityDecoder.reference_profile(models, %{
               auth_mode: :chatgpt,
               authenticated: true,
               identity: %{status: :unconfirmed}
             })

    hidden_models = Enum.map(models, &Map.put(&1, :hidden, true))

    assert %{
             status: :fail,
             sol_available: false,
             terra_available: false,
             terra_high: false,
             terra_medium: false
           } = CapabilityDecoder.reference_profile(hidden_models, account)
  end

  test "rejects malformed, duplicate, and oversized model pages with content-free errors" do
    duplicate = %{"data" => [model("same", ["high"], []), model("same", ["ultra"], [])]}

    assert {:error,
            %CapabilityError{
              method: "model/list",
              reason: :duplicate_identifier
            }} = CapabilityDecoder.model_page(duplicate)

    oversized = %{"data" => List.duplicate(model("bounded", ["high"], []), 257)}

    assert {:error,
            %CapabilityError{
              method: "model/list",
              reason: :response_limit_exceeded
            } = error} = CapabilityDecoder.model_page(oversized)

    refute inspect(error) =~ "bounded"

    assert {:error, %CapabilityError{reason: :invalid_field_type}} =
             CapabilityDecoder.model_page(%{"data" => "not-a-list"})

    assert {:error, %CapabilityError{reason: :invalid_cursor}} =
             CapabilityDecoder.model_page(%{"data" => [], "nextCursor" => ""})

    assert {:error, %CapabilityError{reason: :missing_required_field}} =
             CapabilityDecoder.model_page(%{
               "data" => [Map.delete(model("missing-description", ["high"], []), "description")]
             })

    assert {:error, %CapabilityError{reason: :inconsistent_default_effort}} =
             CapabilityDecoder.model_page(%{
               "data" => [
                 model("inconsistent-effort", ["high"], [])
                 |> Map.put("defaultReasoningEffort", "ultra")
               ]
             })

    assert {:error, %CapabilityError{reason: :inconsistent_default_tier}} =
             CapabilityDecoder.model_page(%{
               "data" => [
                 model("inconsistent-tier", ["high"], [])
                 |> Map.put("defaultServiceTier", "missing-tier")
               ]
             })
  end

  test "decodes bounded feature, collaboration, and token-usage shapes without usage values" do
    feature_response =
      schema_valid!(
        %{
          "data" => [
            %{
              "defaultEnabled" => true,
              "enabled" => false,
              "name" => "multi_agent_v2",
              "stage" => "underDevelopment"
            }
          ],
          "nextCursor" => nil
        },
        "json/v2/ExperimentalFeatureListResponse.json"
      )

    assert {:ok,
            %{
              items: [
                %{
                  default_enabled: true,
                  enabled: false,
                  name: "multi_agent_v2",
                  stage: "underDevelopment"
                }
              ],
              next_cursor: nil
            }} = CapabilityDecoder.feature_page(feature_response)

    collaboration_response =
      schema_valid!(
        %{
          "data" => [
            %{
              "name" => "default",
              "mode" => "default",
              "model" => "gpt-5.6-sol",
              "reasoning_effort" => "ultra"
            }
          ]
        },
        "experimental/json/v2/CollaborationModeListResponse.json"
      )

    assert {:ok,
            [
              %{
                mode: "default",
                model: "gpt-5.6-sol",
                name: "default",
                reasoning_effort: "ultra"
              }
            ]} = CapabilityDecoder.collaboration_modes(collaboration_response)

    usage_response =
      schema_valid!(
        %{
          "summary" => %{"lifetimeTokens" => 9_999_999, "peakDailyTokens" => nil},
          "dailyUsageBuckets" => [
            %{"startDate" => "2026-07-17", "tokens" => 123_456}
          ]
        },
        "json/v2/GetAccountTokenUsageResponse.json"
      )

    assert {:ok,
            %{
              daily_bucket_count: 1,
              populated_summary_fields: ["lifetimeTokens"]
            } = usage_shape} = CapabilityDecoder.usage_shape(usage_response)

    refute Jason.encode!(usage_shape) =~ "9999999"
    refute Jason.encode!(usage_shape) =~ "123456"

    assert {:ok, %{daily_bucket_count: 0, populated_summary_fields: []}} =
             CapabilityDecoder.usage_shape(%{
               "summary" => %{},
               "dailyUsageBuckets" => nil
             })
  end

  test "rejects invalid decoder options and account variants without invoking model work" do
    provider = fn -> flunk("identity key provider must remain lazy") end

    assert_shape_error(CapabilityDecoder.initialize(:not_an_object), "initialize", :expected_object)

    assert_shape_error(
      CapabilityDecoder.account(%{}, :not_a_provider, 1),
      "account/read",
      :invalid_decoder_options
    )

    assert_shape_error(
      CapabilityDecoder.account(
        %{"account" => %{"type" => "unknown"}, "requiresOpenaiAuth" => true},
        provider
      ),
      "account/read",
      :invalid_account
    )

    assert {:ok, %{identity: %{status: :unconfirmed}}} =
             CapabilityDecoder.account(
               %{
                 "account" => %{"type" => "chatgpt", "email" => nil, "planType" => "pro"},
                 "requiresOpenaiAuth" => true
               },
               provider
             )

    assert_shape_error(
      CapabilityDecoder.account(
        %{
          "account" => %{
            "type" => "chatgpt",
            "email" => String.duplicate("e", 321),
            "planType" => "pro"
          },
          "requiresOpenaiAuth" => true
        },
        provider
      ),
      "account/read",
      :response_limit_exceeded
    )

    assert_shape_error(
      CapabilityDecoder.account(
        %{
          "account" => %{"type" => "chatgpt", "email" => 7, "planType" => "pro"},
          "requiresOpenaiAuth" => true
        },
        provider
      ),
      "account/read",
      :invalid_field_type
    )

    assert_shape_error(
      CapabilityDecoder.account(
        %{
          "account" => %{"type" => "amazonBedrock", "credentialSource" => "invalid"},
          "requiresOpenaiAuth" => false
        },
        provider
      ),
      "account/read",
      :invalid_account
    )
  end

  test "rejects every malformed primitive used by initialization and paginated lists" do
    assert_shape_error(
      CapabilityDecoder.initialize(%{
        "codexHome" => String.duplicate("/", 1_025),
        "platformFamily" => "unix",
        "platformOs" => "linux",
        "userAgent" => "codex"
      }),
      "initialize",
      :response_limit_exceeded
    )

    assert_shape_error(
      CapabilityDecoder.initialize(%{
        "codexHome" => 7,
        "platformFamily" => "unix",
        "platformOs" => "linux",
        "userAgent" => "codex"
      }),
      "initialize",
      :invalid_field_type
    )

    assert_shape_error(
      CapabilityDecoder.account(%{"account" => nil}, fn -> {:ok, <<0::256>>} end),
      "account/read",
      :missing_required_field
    )

    assert_shape_error(
      CapabilityDecoder.account(
        %{"account" => nil, "requiresOpenaiAuth" => "yes"},
        fn -> {:ok, <<0::256>>} end
      ),
      "account/read",
      :invalid_field_type
    )

    assert_shape_error(CapabilityDecoder.model_page(%{}), "model/list", :missing_required_field)

    assert_shape_error(
      CapabilityDecoder.model_page(%{
        "data" => [],
        "nextCursor" => String.duplicate("c", 1_025)
      }),
      "model/list",
      :response_limit_exceeded
    )
  end

  test "rejects malformed optional capability fields and bounded collections" do
    assert_shape_error(
      CapabilityDecoder.usage_shape(%{"summary" => []}),
      "account/usage/read",
      :invalid_field_type
    )

    assert_shape_error(
      CapabilityDecoder.usage_shape(%{}),
      "account/usage/read",
      :missing_required_field
    )

    assert_shape_error(
      CapabilityDecoder.usage_shape(%{"summary" => %{"lifetimeTokens" => "private"}}),
      "account/usage/read",
      :invalid_usage_summary
    )

    assert_shape_error(
      CapabilityDecoder.usage_shape(%{
        "summary" => %{},
        "dailyUsageBuckets" => [%{"startDate" => "2026-07-17"}]
      }),
      "account/usage/read",
      :missing_required_field
    )

    assert_shape_error(
      CapabilityDecoder.usage_shape(%{
        "summary" => %{},
        "dailyUsageBuckets" => [%{"startDate" => "2026-07-17", "tokens" => "private"}]
      }),
      "account/usage/read",
      :invalid_field_type
    )

    assert_shape_error(
      CapabilityDecoder.usage_shape(%{
        "summary" => %{},
        "dailyUsageBuckets" => List.duplicate(%{}, 401)
      }),
      "account/usage/read",
      :response_limit_exceeded
    )

    assert_shape_error(
      CapabilityDecoder.usage_shape(%{"summary" => %{}, "dailyUsageBuckets" => %{}}),
      "account/usage/read",
      :invalid_field_type
    )

    collaboration = %{
      "data" => [
        %{
          "name" => "default",
          "mode" => nil,
          "model" => nil,
          "reasoning_effort" => nil
        }
      ]
    }

    assert {:ok, [%{mode: nil, model: nil, reasoning_effort: nil}]} =
             CapabilityDecoder.collaboration_modes(collaboration)

    assert_shape_error(
      CapabilityDecoder.collaboration_modes(put_in(collaboration, ["data", Access.at(0), "model"], String.duplicate("m", 257))),
      "collaborationMode/list",
      :response_limit_exceeded
    )

    assert_shape_error(
      CapabilityDecoder.collaboration_modes(put_in(collaboration, ["data", Access.at(0), "model"], 7)),
      "collaborationMode/list",
      :invalid_field_type
    )

    assert_shape_error(
      CapabilityDecoder.collaboration_modes(put_in(collaboration, ["data", Access.at(0), "mode"], 7)),
      "collaborationMode/list",
      :invalid_enum
    )

    assert_shape_error(
      CapabilityDecoder.model_page(%{
        "data" => [model("too-many-tiers", ["high"], List.duplicate(service_tier(), 33))]
      }),
      "model/list",
      :response_limit_exceeded
    )

    assert_shape_error(
      CapabilityDecoder.model_page(%{
        "data" => [model("invalid-tiers", ["high"], []) |> Map.put("serviceTiers", %{})]
      }),
      "model/list",
      :invalid_field_type
    )
  end

  test "rejects missing and non-enum capability values" do
    feature = %{
      "defaultEnabled" => false,
      "enabled" => true,
      "name" => "multi_agent_v2",
      "stage" => "underDevelopment"
    }

    assert_shape_error(
      CapabilityDecoder.feature_page(%{"data" => [Map.delete(feature, "stage")]}),
      "experimentalFeature/list",
      :missing_required_field
    )

    assert_shape_error(
      CapabilityDecoder.feature_page(%{"data" => [%{feature | "stage" => 7}]}),
      "experimentalFeature/list",
      :invalid_enum
    )

    assert_shape_error(
      CapabilityDecoder.account_updated(%{"authMode" => 7, "planType" => nil}),
      "account/updated",
      :invalid_enum
    )
  end

  defp model(slug, efforts, tiers) do
    %{
      "defaultReasoningEffort" => hd(efforts),
      "defaultServiceTier" => if(tiers == [], do: nil, else: hd(tiers)["id"]),
      "description" => "Fixture model description",
      "displayName" => slug,
      "hidden" => false,
      "id" => slug,
      "isDefault" => slug == "gpt-5.6-sol",
      "model" => slug,
      "serviceTiers" => tiers,
      "supportedReasoningEfforts" => Enum.map(efforts, &%{"description" => "Fixture effort", "reasoningEffort" => &1})
    }
  end

  defp service_tier do
    %{"id" => "tier", "name" => "Tier", "description" => "Fixture tier"}
  end

  defp assert_shape_error(result, method, reason) do
    assert {:error,
            %CapabilityError{
              kind: :invalid_response_shape,
              method: ^method,
              reason: ^reason
            }} = result
  end

  defp schema_valid!(value, relative_path) do
    assert {:ok, schema} = SchemaBundle.schema(relative_path)
    assert :ok = schema |> Xema.from_json_schema() |> Xema.validate(value)
    value
  end
end
