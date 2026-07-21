# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CapabilityReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.{CapabilityError, CapabilityReport}

  test "builds a deterministic public report with only the safe identity binding" do
    assert {:ok, report} = CapabilityReport.public(discovery_result())

    assert report["reportVersion"] == 1
    assert report["noModelWork"]
    assert report["account"]["authMode"] == "chatgpt"
    assert report["account"]["identity"]["status"] == "confirmed"
    assert report["account"]["identity"]["bindingId"] == "codex-binding-v1-private"
    assert report["referenceProfile"]["identityBinding"]
    assert report["initialize"]["versionAdvertised"]
    assert report["initialize"]["userAgentSha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert report["models"] |> Enum.map(& &1["model"]) == ~w(gpt-5.6-sol gpt-5.6-terra)
    assert report["models"] |> hd() |> Map.fetch!("serviceTierIds") == ["fast-opaque", "priority-opaque"]
    assert report["models"] |> hd() |> Map.fetch!("fastServiceTierId") == "fast-opaque"
    assert report["quotaShape"]["fields"] == ["credits", "primary"]

    encoded = Jason.encode!(report)
    refute encoded =~ "operator@example.com"
    assert encoded =~ "codex-binding-v1-private"
    refute encoded =~ ~s("planType":"pro")
    refute encoded =~ "/private/codex/home"
    refute encoded =~ "1234.56"
    assert encoded =~ "lifetimeTokens"
    refute encoded =~ "Fast private provider description"
    refute encoded =~ "codex-app-server/0.144.3-private-agent"

    assert {:ok, ^report} = CapabilityReport.public(discovery_result())
  end

  test "fails closed on malformed or incomplete discovery state" do
    assert {:error, %CapabilityError{kind: :public_report_failed}} =
             CapabilityReport.public(%{})

    malformed = put_in(discovery_result(), [:account, :identity, :generation], 0)

    assert {:error, %CapabilityError{kind: :public_report_failed}} =
             CapabilityReport.public(malformed)

    assert {:error, %CapabilityError{kind: :public_report_failed}} =
             CapabilityReport.public(:invalid)
  end

  test "publishes compatibility telemetry absence without provider error content" do
    compatibility =
      discovery_result()
      |> put_in([:account, :auth_mode], :api_key)
      |> put_in([:account, :identity], %{
        binding_id: nil,
        evidence: :unavailable,
        generation: 1,
        provider_identifier_available: false,
        status: :unconfirmed
      })
      |> put_in([:quota], %{status: :auth_restricted})
      |> put_in([:optional, :usage], %{status: :unavailable})
      |> put_in([:optional, :experimental_features], %{status: :unavailable})
      |> put_in([:reference_profile, :chatgpt_authentication], false)
      |> put_in([:reference_profile, :identity_binding], false)
      |> put_in([:reference_profile, :status], :fail)

    assert {:ok, report} = CapabilityReport.public(compatibility)
    assert report["quotaShape"] == %{"status" => "auth_restricted"}
    assert report["optional"]["usage"] == %{"status" => "unavailable"}
    assert report["optional"]["experimentalFeatures"] == %{"status" => "unavailable"}
    assert report["account"]["identity"]["bindingId"] == nil
  end

  test "does not select an ambiguous human-facing Fast tier" do
    tiers = [
      %{id: "fast-one", name: "Fast"},
      %{id: "fast-two", name: " fast "}
    ]

    for candidate_tiers <- [tiers, Enum.reverse(tiers)] do
      candidate =
        put_in(
          discovery_result(),
          [:models, Access.at(1), :service_tiers],
          candidate_tiers
        )

      assert {:ok, report} = CapabilityReport.public(candidate)
      assert report["models"] |> hd() |> Map.fetch!("fastServiceTierId") == nil

      assert report["models"] |> hd() |> Map.fetch!("serviceTierIds") ==
               ["fast-one", "fast-two"]
    end
  end

  test "requires an exact advertised version token" do
    for user_agent <- [
          "codex-app-server/0.144.30",
          "codex-app-server/0.144.3.1",
          "codex-app-server/10.144.3",
          "codex-app-server/x0.144.3y"
        ] do
      candidate = put_in(discovery_result(), [:initialize, :user_agent], user_agent)
      assert {:ok, report} = CapabilityReport.public(candidate)
      refute report["initialize"]["versionAdvertised"]
    end

    candidate =
      put_in(
        discovery_result(),
        [:initialize, :user_agent],
        "codex-app-server/0.144.3 (linux)"
      )

    assert {:ok, report} = CapabilityReport.public(candidate)
    assert report["initialize"]["versionAdvertised"]
  end

  test "normalizes atom-valued optional metadata and unsupported item surfaces" do
    candidate =
      discovery_result()
      |> put_in([:optional, :collaboration_modes, :result], [
        %{mode: :default, model: :sol, name: "default", reasoning_effort: :ultra}
      ])
      |> put_in([:optional, :experimental_features], %{status: :unsupported})

    assert {:ok, report} = CapabilityReport.public(candidate)

    assert report["optional"]["collaborationModes"]["result"] == [
             %{
               "mode" => "default",
               "model" => "sol",
               "name" => "default",
               "reasoningEffort" => "ultra"
             }
           ]

    assert report["optional"]["experimentalFeatures"] == %{"status" => "unsupported"}
  end

  test "converts thrown enumerable failures into a content-free report error" do
    throwing_models = Stream.map([:private_payload], fn _value -> throw(:private_payload) end)
    candidate = Map.put(discovery_result(), :models, throwing_models)

    assert {:error, %CapabilityError{kind: :public_report_failed}} =
             CapabilityReport.public(candidate)
  end

  defp discovery_result do
    %{
      account: %{
        auth_mode: :chatgpt,
        authenticated: true,
        identity: %{
          binding_id: "codex-binding-v1-private",
          evidence: :keyed_account_metadata,
          generation: 1,
          provider_identifier_available: false,
          status: :confirmed
        },
        plan_type: "pro",
        requires_openai_auth: true
      },
      initialize: %{
        codex_home_absolute: true,
        platform_family: "unix",
        platform_os: "linux",
        user_agent: "codex-app-server/0.144.3-private-agent"
      },
      models: [
        %{
          default_reasoning_effort: "high",
          default_service_tier: nil,
          hidden: false,
          id: "terra-id",
          is_default: false,
          model: "gpt-5.6-terra",
          reasoning_efforts: ~w(high medium),
          service_tiers: []
        },
        %{
          default_reasoning_effort: "ultra",
          default_service_tier: "priority-opaque",
          hidden: false,
          id: "sol-id",
          is_default: true,
          model: "gpt-5.6-sol",
          reasoning_efforts: ~w(ultra high),
          service_tiers: [
            %{
              id: "fast-opaque",
              name: "Fast"
            },
            %{
              id: "priority-opaque",
              name: "Fast private provider description"
            }
          ]
        }
      ],
      no_model_work: true,
      optional: %{
        collaboration_modes: %{
          result: [
            %{mode: "default", model: "gpt-5.6-sol", name: "default", reasoning_effort: "ultra"}
          ],
          status: :available
        },
        experimental_features: %{
          items: [
            %{default_enabled: false, enabled: true, name: "multi_agent_v2", stage: "underDevelopment"}
          ],
          status: :available
        },
        usage: %{
          result: %{daily_bucket_count: 2, populated_summary_fields: ["lifetimeTokens"]},
          status: :available
        }
      },
      quota: %{
        bucket_count: 1,
        bucket_source: :multi,
        fields: [:primary, :credits],
        out_of_range_values: false,
        reset_credits: %{details: :unavailable, summary: :absent},
        window_slot_count: 1
      },
      reference_profile: %{
        chatgpt_authentication: true,
        identity_binding: true,
        sol_available: true,
        sol_review_effort: true,
        sol_ultra: true,
        status: :pass,
        terra_available: true,
        terra_high: true,
        terra_medium: true
      },
      schema_version: "0.144.3"
    }
  end
end
