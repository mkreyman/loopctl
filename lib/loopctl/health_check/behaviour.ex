defmodule Loopctl.HealthCheck.Behaviour do
  @moduledoc """
  Behaviour for health check implementations.

  Defines the contract for checking application health.
  The default implementation checks database connectivity and Oban status.
  Tests use a mock via Mox.
  """

  @callback check() :: {:ok, map()} | {:error, term()}
end
