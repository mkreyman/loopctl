defmodule Loopctl.GitSha do
  @moduledoc """
  The ONE rule for a git object id loopctl accepts: lowercase hex, 40 characters (SHA-1) or 64
  (SHA-256). Every module that validates a commit, tree or merge SHA calls `valid?/1`, so the
  rule cannot drift between the thread ledger, the stage machine and the forge clients.

  The OpenAPI schemas state the same rule as a JSON-schema `pattern` string (`pattern/0`).
  """

  @doc "Whether `value` is a git object id: 40 or 64 lowercase hex characters."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, value)

  def valid?(_value), do: false
end
