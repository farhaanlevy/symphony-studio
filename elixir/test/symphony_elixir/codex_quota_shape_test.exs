# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.QuotaShapeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.{CapabilityError, QuotaShape, SchemaBundle}

  test "prefers the multi-bucket view and returns only shape metadata" do
    response =
      schema_valid!(
        %{
          "rateLimits" => %{
            "limitId" => "legacy-sensitive-id",
            "primary" => %{"usedPercent" => 99}
          },
          "rateLimitsByLimitId" => %{
            "opaque-a" => %{
              "limitId" => "opaque-a",
              "limitName" => "Primary Codex",
              "primary" => %{
                "usedPercent" => 42,
                "windowDurationMins" => 300,
                "resetsAt" => 1_900_000_000
              },
              "credits" => %{
                "hasCredits" => true,
                "unlimited" => false,
                "balance" => "1234.56"
              }
            },
            "opaque-b" => %{
              "limitId" => "opaque-b",
              "secondary" => %{"usedPercent" => 101},
              "individualLimit" => %{
                "limit" => "200.00",
                "used" => "50.00",
                "remainingPercent" => 75,
                "resetsAt" => 1_900_000_100
              }
            }
          },
          "rateLimitResetCredits" => %{
            "availableCount" => 5,
            "credits" => [
              %{
                "id" => "private-reset-credit-id",
                "status" => "available",
                "resetType" => "codexRateLimits",
                "grantedAt" => 1_800_000_000,
                "expiresAt" => nil,
                "title" => "Reset",
                "description" => nil
              }
            ]
          }
        },
        "json/v2/GetAccountRateLimitsResponse.json"
      )

    assert {:ok,
            %{
              bucket_count: 2,
              bucket_source: :multi,
              fields: [
                :credits,
                :limit_id,
                :limit_name,
                :primary,
                :secondary,
                :spend_control
              ],
              out_of_range_values: true,
              reset_credits: %{details: :present, summary: :present},
              window_slot_count: 2
            } = shape} = QuotaShape.full(response)

    rendered = Jason.encode!(shape)
    refute rendered =~ "legacy-sensitive-id"
    refute rendered =~ "opaque-a"
    refute rendered =~ "1234.56"
    refute rendered =~ "private-reset-credit-id"
  end

  test "accepts a successful fallback snapshot with no windows without calling it unlimited" do
    response =
      schema_valid!(
        %{
          "rateLimits" => %{
            "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
          },
          "rateLimitsByLimitId" => nil,
          "rateLimitResetCredits" => nil
        },
        "json/v2/GetAccountRateLimitsResponse.json"
      )

    assert {:ok,
            %{
              bucket_count: 1,
              bucket_source: :fallback,
              fields: [:credits],
              out_of_range_values: false,
              reset_credits: %{details: :unavailable, summary: :absent},
              window_slot_count: 0
            } = shape} = QuotaShape.full(response)

    refute Map.has_key?(shape, :unlimited)
  end

  test "a present empty multi-bucket view overrides a populated fallback" do
    response =
      schema_valid!(
        %{
          "rateLimits" => %{
            "limitId" => "fallback-only",
            "primary" => %{"usedPercent" => 90}
          },
          "rateLimitsByLimitId" => %{}
        },
        "json/v2/GetAccountRateLimitsResponse.json"
      )

    assert {:ok,
            %{
              bucket_count: 0,
              bucket_source: :multi,
              fields: [],
              out_of_range_values: false,
              window_slot_count: 0
            } = shape} = QuotaShape.full(response)

    refute Jason.encode!(shape) =~ "fallback-only"
  end

  test "counts zero, one, and many windows as opaque source slots" do
    responses = [
      {%{"rateLimits" => %{}}, 0},
      {%{"rateLimits" => %{"primary" => %{"usedPercent" => 0}}}, 1},
      {
        %{
          "rateLimits" => %{},
          "rateLimitsByLimitId" => %{
            "opaque-a" => %{
              "limitId" => "opaque-a",
              "primary" => %{"usedPercent" => 1},
              "secondary" => %{"usedPercent" => 2}
            },
            "opaque-b" => %{
              "limitId" => "opaque-b",
              "primary" => %{"usedPercent" => 3},
              "secondary" => %{"usedPercent" => 4}
            }
          }
        },
        4
      }
    ]

    Enum.each(responses, fn {response, expected_count} ->
      response = schema_valid!(response, "json/v2/GetAccountRateLimitsResponse.json")

      assert {:ok, %{window_slot_count: ^expected_count}} = QuotaShape.full(response)
    end)
  end

  test "sparse summaries persist omitted, explicit-null, and populated fields separately" do
    omitted =
      schema_valid!(
        %{"rateLimits" => %{}},
        "json/v2/AccountRateLimitsUpdatedNotification.json"
      )

    assert {:ok,
            %{
              fields: [],
              null_fields: [],
              out_of_range_values: false,
              patch_semantics: :sparse,
              window_slot_count: 0
            }} = QuotaShape.sparse_update(omitted)

    explicit_null =
      schema_valid!(
        %{
          "rateLimits" => %{
            "credits" => nil,
            "individualLimit" => nil,
            "limitId" => nil,
            "limitName" => nil,
            "planType" => nil,
            "primary" => nil,
            "rateLimitReachedType" => nil,
            "secondary" => nil
          }
        },
        "json/v2/AccountRateLimitsUpdatedNotification.json"
      )

    assert {:ok,
            %{
              fields: [],
              null_fields: [
                :credits,
                :limit_id,
                :limit_name,
                :plan_type,
                :primary,
                :reached_type,
                :secondary,
                :spend_control
              ],
              window_slot_count: 0
            }} = QuotaShape.sparse_update(explicit_null)

    populated =
      schema_valid!(
        %{
          "rateLimits" => %{
            "credits" => %{
              "hasCredits" => true,
              "unlimited" => false,
              "balance" => "private-balance"
            },
            "individualLimit" => %{
              "limit" => "private-limit",
              "used" => "private-used",
              "remainingPercent" => 100,
              "resetsAt" => 1_900_000_000
            },
            "limitId" => "private-limit-id",
            "limitName" => "Private limit name",
            "planType" => "enterprise",
            "primary" => %{"usedPercent" => 0},
            "rateLimitReachedType" => "workspace_member_usage_limit_reached",
            "secondary" => %{"usedPercent" => 100}
          }
        },
        "json/v2/AccountRateLimitsUpdatedNotification.json"
      )

    assert {:ok,
            %{
              fields: [
                :credits,
                :limit_id,
                :limit_name,
                :plan_type,
                :primary,
                :reached_type,
                :secondary,
                :spend_control
              ],
              null_fields: [],
              out_of_range_values: false,
              patch_semantics: :sparse,
              window_slot_count: 2
            } = summary} = QuotaShape.sparse_update(populated)

    persisted = summary |> Jason.encode!() |> Jason.decode!()

    assert persisted["fields"] ==
             ~w(credits limit_id limit_name plan_type primary reached_type secondary spend_control)

    assert persisted["null_fields"] == []
    refute Jason.encode!(summary) =~ "private-"
  end

  test "classifies reset-credit detail availability without trusting detail-row count" do
    reset_credit = reset_credit("private-reset-id")

    cases = [
      {%{"availableCount" => 2}, :unavailable},
      {%{"availableCount" => 2, "credits" => nil}, :unavailable},
      {%{"availableCount" => 0, "credits" => []}, :empty},
      {%{"availableCount" => 65, "credits" => [reset_credit]}, :present}
    ]

    Enum.each(cases, fn {reset_credits, expected_details} ->
      response =
        schema_valid!(
          %{"rateLimits" => %{}, "rateLimitResetCredits" => reset_credits},
          "json/v2/GetAccountRateLimitsResponse.json"
        )

      assert {:ok,
              %{
                out_of_range_values: false,
                reset_credits: %{details: ^expected_details, summary: :present}
              }} = QuotaShape.full(response)
    end)

    response_without_summary =
      schema_valid!(
        %{"rateLimits" => %{}},
        "json/v2/GetAccountRateLimitsResponse.json"
      )

    assert {:ok, %{reset_credits: %{details: :unavailable, summary: :absent}}} =
             QuotaShape.full(response_without_summary)

    negative_count =
      schema_valid!(
        %{
          "rateLimits" => %{},
          "rateLimitResetCredits" => %{"availableCount" => -1, "credits" => []}
        },
        "json/v2/GetAccountRateLimitsResponse.json"
      )

    assert {:ok, %{out_of_range_values: true}} = QuotaShape.full(negative_count)

    over_bound_details =
      schema_valid!(
        %{
          "rateLimits" => %{},
          "rateLimitResetCredits" => %{
            "availableCount" => 65,
            "credits" => Enum.map(1..65, &reset_credit("private-reset-id-#{&1}"))
          }
        },
        "json/v2/GetAccountRateLimitsResponse.json"
      )

    assert {:error, %CapabilityError{reason: :response_limit_exceeded}} =
             QuotaShape.full(over_bound_details)
  end

  test "rejects malformed and unbounded quota shapes with content-free errors" do
    assert {:error,
            %CapabilityError{
              method: "account/rateLimits/read",
              reason: :missing_required_field
            }} = QuotaShape.full(%{})

    too_many =
      for index <- 1..129, into: %{} do
        {"limit-#{index}", %{}}
      end

    assert {:error,
            %CapabilityError{
              method: "account/rateLimits/read",
              reason: :response_limit_exceeded
            } = error} =
             QuotaShape.full(%{"rateLimits" => %{}, "rateLimitsByLimitId" => too_many})

    refute inspect(error) =~ "limit-129"

    assert {:error, %CapabilityError{reason: :invalid_field_type}} =
             QuotaShape.sparse_update(%{"rateLimits" => %{"primary" => %{"usedPercent" => "42"}}})

    assert {:error, %CapabilityError{reason: :bucket_identifier_mismatch}} =
             QuotaShape.full(%{
               "rateLimits" => %{},
               "rateLimitsByLimitId" => %{"opaque-a" => %{"limitId" => "opaque-b"}}
             })
  end

  test "rejects malformed bucket containers, identifiers, and snapshot objects" do
    assert_quota_error(QuotaShape.full(:not_an_object), :expected_object)

    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => []}),
      :invalid_field_type
    )

    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{}, "rateLimitsByLimitId" => []}),
      :invalid_field_type
    )

    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{}, "rateLimitsByLimitId" => %{"" => %{}}}),
      :invalid_bucket_identifier
    )

    assert_quota_error(
      QuotaShape.full(%{
        "rateLimits" => %{},
        "rateLimitsByLimitId" => %{"valid-id" => :not_a_snapshot}
      }),
      :expected_object
    )

    assert_quota_error(
      QuotaShape.full(%{
        "rateLimits" => %{},
        "rateLimitsByLimitId" => %{"" => :not_a_snapshot}
      }),
      :invalid_bucket_identifier
    )
  end

  test "rejects malformed window, credit, spend, and enum primitives" do
    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{"primary" => %{"usedPercent" => 1, "resetsAt" => "later"}}}),
      :invalid_field_type
    )

    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{"limitName" => String.duplicate("n", 1_025)}}),
      :response_limit_exceeded
    )

    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{"limitName" => 7}}),
      :invalid_field_type
    )

    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{"planType" => 7}}),
      :invalid_enum
    )

    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{"credits" => %{"unlimited" => false}}}),
      :missing_required_field
    )

    assert_quota_error(
      QuotaShape.full(%{
        "rateLimits" => %{"credits" => %{"hasCredits" => "yes", "unlimited" => false}}
      }),
      :invalid_field_type
    )
  end

  test "rejects malformed reset-credit summaries and detail rows" do
    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{}, "rateLimitResetCredits" => []}),
      :invalid_field_type
    )

    assert_quota_error(
      QuotaShape.full(%{
        "rateLimits" => %{},
        "rateLimitResetCredits" => %{"availableCount" => 1, "credits" => %{}}
      }),
      :invalid_field_type
    )

    assert_quota_error(
      QuotaShape.full(%{
        "rateLimits" => %{},
        "rateLimitResetCredits" => %{"availableCount" => 1, "credits" => [:not_a_row]}
      }),
      :expected_object
    )

    assert_quota_error(
      QuotaShape.full(%{"rateLimits" => %{}, "rateLimitResetCredits" => %{}}),
      :missing_required_field
    )

    assert_quota_error(
      QuotaShape.full(%{
        "rateLimits" => %{},
        "rateLimitResetCredits" => %{"availableCount" => "one"}
      }),
      :invalid_field_type
    )

    for {row, reason} <- [
          {Map.delete(reset_credit("private"), "id"), :missing_required_field},
          {%{reset_credit("private") | "id" => String.duplicate("i", 257)}, :response_limit_exceeded},
          {%{reset_credit("private") | "id" => 7}, :invalid_field_type},
          {Map.delete(reset_credit("private"), "status"), :missing_required_field},
          {%{reset_credit("private") | "status" => 7}, :invalid_enum}
        ] do
      assert_quota_error(
        QuotaShape.full(%{
          "rateLimits" => %{},
          "rateLimitResetCredits" => %{"availableCount" => 1, "credits" => [row]}
        }),
        reason
      )
    end
  end

  defp schema_valid!(value, relative_path) do
    assert {:ok, schema} = SchemaBundle.schema(relative_path)
    assert :ok = schema |> Xema.from_json_schema() |> Xema.validate(value)
    value
  end

  defp reset_credit(id) do
    %{
      "id" => id,
      "status" => "available",
      "resetType" => "codexRateLimits",
      "grantedAt" => 1_800_000_000,
      "expiresAt" => nil,
      "title" => nil,
      "description" => nil
    }
  end

  defp assert_quota_error(result, reason) do
    assert {:error,
            %CapabilityError{
              kind: :invalid_response_shape,
              method: "account/rateLimits/read",
              reason: ^reason
            }} = result
  end
end
