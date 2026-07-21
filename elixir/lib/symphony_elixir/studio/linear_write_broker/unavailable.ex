# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteBroker.Unavailable do
  @moduledoc false

  @behaviour SymphonyElixir.Studio.LinearWriteBroker

  @impl true
  def reconcile(_server, _command), do: {:error, :least_privilege_write_broker_unavailable}

  @impl true
  def execute(_server, _command), do: {:error, :least_privilege_write_broker_unavailable}
end
