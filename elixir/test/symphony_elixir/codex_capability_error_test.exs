# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CapabilityErrorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.CapabilityError

  test "formats content-free messages with and without a protocol method" do
    scoped = CapabilityError.new(:invalid_response_shape, "model/list", :invalid_field_type)
    unscoped = CapabilityError.new(:identity_key_unavailable)

    assert Exception.message(scoped) ==
             "Codex capability discovery failed for model/list: invalid_response_shape"

    assert Exception.message(unscoped) ==
             "Codex capability discovery failed: identity_key_unavailable"

    assert %CapabilityError{kind: :probe_failed} = CapabilityError.exception(kind: :probe_failed)
  end
end
