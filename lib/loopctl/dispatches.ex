defmodule Loopctl.Dispatches do
  @moduledoc """
  US-26.2.1 — Context module for dispatch lineage management.

  Each dispatch represents a scoped task assignment with an ephemeral API
  key. Dispatches form a tree via `parent_dispatch_id`, and every dispatch
  carries its full `lineage_path` (root → self) for efficient prefix
  comparison queries.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Auth
  alias Loopctl.Dispatches.Dispatch

  @max_expires_seconds 14_400
  @default_expires_seconds 3_600

  @doc """
  Creates a new dispatch with an ephemeral API key.

  The lineage_path is computed as: parent.lineage_path ++ [new_dispatch_id].
  For root dispatches (no parent), lineage_path = [self_id].

  ## Parameters

  - `tenant_id` — the tenant UUID
  - `attrs` — map with:
    - `:parent_dispatch_id` (optional, nil for root)
    - `:role` (required)
    - `:agent_id` (required for non-user roles)
    - `:story_id` (optional)
    - `:expires_in_seconds` (optional, default 3600, max 14400)
  - `opts` — keyword list with `:actor_lineage` for audit logging

  ## Returns

  `{:ok, %{dispatch: Dispatch.t(), raw_key: String.t()}}` or `{:error, reason}`
  """
  @spec create_dispatch(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{dispatch: Dispatch.t(), raw_key: String.t()}} | {:error, term()}
  def create_dispatch(tenant_id, attrs, opts \\ []) do
    parsed = parse_dispatch_attrs(attrs)
    do_create_dispatch(tenant_id, parsed, opts)
  end

  defp parse_dispatch_attrs(attrs) do
    expires_in =
      (Map.get(attrs, :expires_in_seconds) || Map.get(attrs, "expires_in_seconds") ||
         @default_expires_seconds)
      |> min(@max_expires_seconds)
      |> max(60)

    now = DateTime.utc_now()

    %{
      parent_id: Map.get(attrs, :parent_dispatch_id) || Map.get(attrs, "parent_dispatch_id"),
      role: Map.get(attrs, :role) || Map.get(attrs, "role"),
      agent_id: Map.get(attrs, :agent_id) || Map.get(attrs, "agent_id"),
      story_id: Map.get(attrs, :story_id) || Map.get(attrs, "story_id"),
      expires_at: DateTime.add(now, expires_in, :second),
      now: now
    }
  end

  defp do_create_dispatch(tenant_id, parsed, opts) do
    %{
      parent_id: parent_id,
      role: role,
      agent_id: agent_id,
      story_id: story_id,
      expires_at: expires_at,
      now: now
    } = parsed

    multi =
      Multi.new()
      |> Multi.run(:resolve_lineage, fn _repo, _changes ->
        resolve_lineage(tenant_id, parent_id)
      end)
      |> Multi.run(:create_dispatch, fn _repo, %{resolve_lineage: parent_lineage} ->
        dispatch_id = Ecto.UUID.generate()
        lineage_path = parent_lineage ++ [dispatch_id]

        %Dispatch{id: dispatch_id, tenant_id: tenant_id}
        |> Dispatch.changeset(%{
          parent_dispatch_id: parent_id,
          agent_id: agent_id,
          story_id: story_id,
          role: normalize_role(role),
          lineage_path: lineage_path,
          expires_at: expires_at,
          created_at: now
        })
        |> AdminRepo.insert()
      end)
      |> Multi.run(:mint_key, fn _repo, %{create_dispatch: dispatch} ->
        mint_and_link_key(tenant_id, dispatch, agent_id, expires_at)
      end)
      |> Multi.run(:audit, fn _repo, %{mint_key: %{dispatch: dispatch}} ->
        actor_lineage = Keyword.get(opts, :actor_lineage, [])

        AuditChain.append(tenant_id, %{
          action: "dispatch_created",
          actor_lineage: actor_lineage,
          entity_type: "dispatch",
          entity_id: dispatch.id,
          payload: %{
            "lineage_path" => dispatch.lineage_path,
            "role" => to_string(dispatch.role),
            "expires_at" => DateTime.to_iso8601(dispatch.expires_at)
          }
        })
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{mint_key: %{raw_key: raw_key, dispatch: dispatch}}} ->
        {:ok, %{dispatch: dispatch, raw_key: raw_key}}

      {:error, :resolve_lineage, reason, _} ->
        {:error, reason}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc "Gets a dispatch by ID, tenant-scoped."
  @spec get_dispatch(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Dispatch.t()} | {:error, :not_found}
  def get_dispatch(tenant_id, dispatch_id) do
    case AdminRepo.get_by(Dispatch, id: dispatch_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      dispatch -> {:ok, dispatch}
    end
  end

  @doc "Lists dispatches with optional filters."
  @spec list_dispatches(Ecto.UUID.t(), keyword()) :: %{data: [Dispatch.t()], meta: map()}
  def list_dispatches(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(d in Dispatch,
        where: d.tenant_id == ^tenant_id,
        order_by: [desc: d.created_at]
      )

    base =
      case Keyword.get(opts, :role) do
        nil -> base
        role -> from(d in base, where: d.role == ^role)
      end

    base =
      if Keyword.get(opts, :active_only, false) do
        now = DateTime.utc_now()

        from(d in base,
          where: is_nil(d.revoked_at) and d.expires_at > ^now
        )
      else
        base
      end

    total_count = AdminRepo.aggregate(base, :count, :id)
    data = base |> limit(^limit) |> offset(^offset) |> AdminRepo.all()

    %{data: data, meta: %{total_count: total_count, limit: limit, offset: offset}}
  end

  @doc """
  Revokes a dispatch and all its descendants.
  """
  @spec revoke(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke(tenant_id, dispatch_id) do
    alias Loopctl.Auth.ApiKey
    now = DateTime.utc_now()

    # Find all dispatches to revoke (target + descendants)
    dispatches_query =
      from(d in Dispatch,
        where:
          d.tenant_id == ^tenant_id and
            is_nil(d.revoked_at) and
            (d.id == ^dispatch_id or ^dispatch_id in d.lineage_path),
        select: %{id: d.id, api_key_id: d.api_key_id}
      )

    to_revoke = AdminRepo.all(dispatches_query)
    dispatch_ids = Enum.map(to_revoke, & &1.id)
    key_ids = to_revoke |> Enum.map(& &1.api_key_id) |> Enum.reject(&is_nil/1)

    # Revoke dispatches and their linked api_keys atomically
    multi =
      Multi.new()
      |> Multi.run(:revoke_dispatches, fn _repo, _ ->
        {count, _} =
          from(d in Dispatch, where: d.id in ^dispatch_ids)
          |> AdminRepo.update_all(set: [revoked_at: now])

        {:ok, count}
      end)
      |> Multi.run(:revoke_keys, fn _repo, _ ->
        if key_ids != [] do
          {count, _} =
            from(k in ApiKey, where: k.id in ^key_ids and is_nil(k.revoked_at))
            |> AdminRepo.update_all(set: [revoked_at: now])

          {:ok, count}
        else
          {:ok, 0}
        end
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{revoke_dispatches: count}} -> {:ok, count}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Checks if two lineage paths share a common prefix of length >= 1."
  @spec lineage_shares_prefix?(list(), list()) :: boolean()
  def lineage_shares_prefix?([], _), do: false
  def lineage_shares_prefix?(_, []), do: false

  def lineage_shares_prefix?([a | _], [b | _]) when a == b, do: true
  def lineage_shares_prefix?(_, _), do: false

  # --- Private ---

  defp mint_and_link_key(tenant_id, dispatch, agent_id, expires_at) do
    key_attrs = %{
      tenant_id: tenant_id,
      name: "dispatch-#{dispatch.id}",
      role: dispatch.role,
      agent_id: agent_id,
      expires_at: expires_at
    }

    with {:ok, {raw_key, api_key}} <- Auth.generate_api_key(key_attrs),
         {:ok, updated} <-
           dispatch
           |> Dispatch.changeset(%{api_key_id: api_key.id})
           |> AdminRepo.update() do
      {:ok, %{raw_key: raw_key, dispatch: updated}}
    end
  end

  defp resolve_lineage(_tenant_id, nil), do: {:ok, []}

  defp resolve_lineage(tenant_id, parent_id) do
    case AdminRepo.get_by(Dispatch, id: parent_id, tenant_id: tenant_id) do
      nil -> {:error, :parent_not_found}
      parent -> {:ok, parent.lineage_path}
    end
  end

  defp normalize_role(role) when role in [:agent, :orchestrator, :user], do: role
  defp normalize_role("agent"), do: :agent
  defp normalize_role("orchestrator"), do: :orchestrator
  defp normalize_role("user"), do: :user
  defp normalize_role(invalid), do: {:error, {:invalid_role, invalid}}
end
