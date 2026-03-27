defmodule Loopctl.Auth.Role do
  @moduledoc """
  Role hierarchy and authorization helpers.

  The role hierarchy is:

      superadmin (4) > user (3) > orchestrator (2) > agent (1)

  Higher levels can access endpoints requiring lower levels.
  """

  @role_levels %{
    superadmin: 4,
    user: 3,
    orchestrator: 2,
    agent: 1
  }

  @doc """
  Returns true if `actual_role` meets or exceeds the `required_role` level.

  ## Examples

      iex> role_at_least?(:superadmin, :user)
      true

      iex> role_at_least?(:agent, :orchestrator)
      false

      iex> role_at_least?(:orchestrator, :orchestrator)
      true
  """
  @spec role_at_least?(atom(), atom()) :: boolean()
  def role_at_least?(actual_role, required_role) do
    level(actual_role) >= level(required_role)
  end

  @doc """
  Returns the numeric level for a role.
  """
  @spec level(atom()) :: non_neg_integer()
  def level(role) when is_map_key(@role_levels, role) do
    Map.fetch!(@role_levels, role)
  end
end
