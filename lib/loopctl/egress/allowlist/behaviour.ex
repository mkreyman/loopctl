defmodule Loopctl.Egress.Allowlist.Behaviour do
  @moduledoc """
  Source of the OPERATOR deployment allowlist (US-41.4).

  Extracted purely so an `async: true` test can exercise an operator carve-out
  WITHOUT `Application.put_env` (forbidden by the project's test conventions and
  a global race under async). There is deliberately no write callback: the
  allowlist is read-only at every role, including `:user`.
  """

  @callback raw_entries() :: [String.t()]
end
