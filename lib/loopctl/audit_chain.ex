defmodule Loopctl.AuditChain do
  @moduledoc """
  US-26.1.1 — Context module for the hash-chained, append-only audit log.

  Every custody-critical event is recorded as a chain entry with a SHA-256
  hash linking it to the previous entry. DB triggers enforce immutability
  (no updates, no deletes) and chain integrity (sequential positions,
  correct prev_entry_hash).

  ## Usage

      Loopctl.AuditChain.append(tenant_id, %{
        action: "story_claimed",
        actor_lineage: ["dispatch-id-1"],
        entity_type: "story",
        entity_id: story_id,
        payload: %{"title" => "..."}
      })
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.AuditChain.SignedTreeHead
  alias Loopctl.TenantKeys

  @zero_hash :binary.copy(<<0>>, 32)

  @doc """
  Appends a new entry to a tenant's audit chain.

  Computes chain_position, prev_entry_hash, and entry_hash. Uses
  SELECT...FOR UPDATE to serialize concurrent appends within the
  same tenant.

  ## Parameters

  - `tenant_id` — the tenant UUID
  - `attrs` — map with:
    - `:action` (required) — event type string
    - `:actor_lineage` (required) — list of dispatch/key IDs
    - `:entity_type` (required) — entity type string
    - `:entity_id` (optional) — entity UUID
    - `:payload` (required) — event details as a map

  ## Returns

  - `{:ok, %Entry{}}` on success
  - `{:error, reason}` on failure
  """
  @spec append(Ecto.UUID.t(), map()) :: {:ok, Entry.t()} | {:error, term()}
  def append(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.run(:lock_and_read, fn _repo, _changes ->
        lock_and_read_previous(tenant_id)
      end)
      |> Multi.run(:insert_entry, fn _repo, %{lock_and_read: {position, prev_hash}} ->
        entry_attrs = build_entry_attrs(tenant_id, position, prev_hash, attrs, now)

        %Entry{tenant_id: tenant_id}
        |> Entry.changeset(entry_attrs)
        |> AdminRepo.insert()
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{insert_entry: entry}} -> {:ok, entry}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Lists audit chain entries for a tenant with pagination.

  ## Options

  - `:limit` — max entries (default 50, max 100)
  - `:offset` — skip N entries (default 0)
  - `:action` — filter by action type

  ## Returns

  `%{data: [Entry.t()], meta: %{total_count, limit, offset}}`
  """
  @spec list_entries(Ecto.UUID.t(), keyword()) :: %{
          data: [Entry.t()],
          meta: %{total_count: non_neg_integer(), limit: pos_integer(), offset: non_neg_integer()}
        }
  def list_entries(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(e in Entry,
        where: e.tenant_id == ^tenant_id,
        order_by: [asc: e.chain_position]
      )

    base =
      case Keyword.get(opts, :action) do
        nil -> base
        action -> from(e in base, where: e.action == ^action)
      end

    total_count = AdminRepo.aggregate(base, :count, :id)

    entries =
      base
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{data: entries, meta: %{total_count: total_count, limit: limit, offset: offset}}
  end

  @doc """
  Returns the latest entry for a tenant (the chain head).
  """
  @spec latest_entry(Ecto.UUID.t()) :: Entry.t() | nil
  def latest_entry(tenant_id) do
    from(e in Entry,
      where: e.tenant_id == ^tenant_id,
      order_by: [desc: e.chain_position],
      limit: 1
    )
    |> AdminRepo.one()
  end

  # --- STH functions ---

  @doc """
  Computes the SHA-256 merkle root of all entry_hashes for a tenant's chain.
  Returns `{:ok, merkle_root_bytes}` or `{:ok, nil}` if the chain is empty.
  """
  @spec compute_merkle_root(Ecto.UUID.t()) :: {:ok, binary() | nil}
  def compute_merkle_root(tenant_id) do
    hashes =
      from(e in Entry,
        where: e.tenant_id == ^tenant_id,
        order_by: [asc: e.chain_position],
        select: e.entry_hash
      )
      |> AdminRepo.all()

    case hashes do
      [] -> {:ok, nil}
      _ -> {:ok, merkle_tree(hashes)}
    end
  end

  @doc """
  Signs a tree head for a tenant using the tenant's audit-signing key.
  Stores the result in `audit_signed_tree_heads`.

  Returns `{:ok, %SignedTreeHead{}}` or `{:error, reason}`.
  """
  @spec sign_and_store_tree_head(Ecto.UUID.t()) :: {:ok, SignedTreeHead.t()} | {:error, term()}
  def sign_and_store_tree_head(tenant_id) do
    with {:ok, merkle_root} when not is_nil(merkle_root) <- compute_merkle_root(tenant_id),
         %Entry{chain_position: position} <- latest_entry(tenant_id),
         {:ok, private_key} <- TenantKeys.get_private_key(tenant_id) do
      now = DateTime.utc_now()

      message = build_sth_message(tenant_id, position, merkle_root, now)
      signature = :crypto.sign(:eddsa, :sha512, message, [private_key, :ed25519])

      sth =
        %SignedTreeHead{tenant_id: tenant_id}
        |> SignedTreeHead.changeset(%{
          chain_position: position,
          merkle_root: merkle_root,
          signed_at: now,
          signature: signature
        })
        |> AdminRepo.insert(
          on_conflict: {:replace, [:merkle_root, :signed_at, :signature]},
          conflict_target: [:tenant_id, :chain_position]
        )

      sth
    else
      {:ok, nil} -> {:error, :empty_chain}
      nil -> {:error, :empty_chain}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the latest STH for a tenant.
  """
  @spec get_latest_sth(Ecto.UUID.t()) :: SignedTreeHead.t() | nil
  def get_latest_sth(tenant_id) do
    from(s in SignedTreeHead,
      where: s.tenant_id == ^tenant_id,
      order_by: [desc: s.chain_position],
      limit: 1
    )
    |> AdminRepo.one()
  end

  @doc """
  Returns the smallest STH with chain_position >= the given position.
  """
  @spec get_sth_at_position(Ecto.UUID.t(), non_neg_integer()) :: SignedTreeHead.t() | nil
  def get_sth_at_position(tenant_id, position) do
    from(s in SignedTreeHead,
      where: s.tenant_id == ^tenant_id and s.chain_position >= ^position,
      order_by: [asc: s.chain_position],
      limit: 1
    )
    |> AdminRepo.one()
  end

  @doc """
  Checks if a new STH is needed (chain has grown since last STH).
  """
  @spec sth_needed?(Ecto.UUID.t()) :: boolean()
  def sth_needed?(tenant_id) do
    latest = latest_entry(tenant_id)
    latest_sth = get_latest_sth(tenant_id)

    case {latest, latest_sth} do
      {nil, _} -> false
      {_, nil} -> true
      {entry, sth} -> entry.chain_position > sth.chain_position
    end
  end

  # --- STH helpers ---

  defp build_sth_message(tenant_id, position, merkle_root, signed_at) do
    unix_ts = DateTime.to_unix(signed_at)
    tenant_id <> Integer.to_string(position) <> merkle_root <> Integer.to_string(unix_ts)
  end

  defp merkle_tree([single]), do: single

  defp merkle_tree(hashes) do
    # Pad to even length by duplicating the last element
    padded = if rem(length(hashes), 2) == 1, do: hashes ++ [List.last(hashes)], else: hashes

    next_level =
      padded
      |> Enum.chunk_every(2)
      |> Enum.map(fn [a, b] -> :crypto.hash(:sha256, a <> b) end)

    merkle_tree(next_level)
  end

  # --- Private ---

  defp lock_and_read_previous(tenant_id) do
    # Lock the latest entry to serialize concurrent appends
    case from(e in Entry,
           where: e.tenant_id == ^tenant_id,
           order_by: [desc: e.chain_position],
           limit: 1,
           lock: "FOR UPDATE"
         )
         |> AdminRepo.one() do
      nil ->
        # Genesis entry
        {:ok, {0, @zero_hash}}

      prev ->
        {:ok, {prev.chain_position + 1, prev.entry_hash}}
    end
  end

  defp build_entry_attrs(tenant_id, position, prev_hash, attrs, now) do
    action = Map.fetch!(attrs, :action)
    actor_lineage = Map.get(attrs, :actor_lineage, [])
    entity_type = Map.fetch!(attrs, :entity_type)
    entity_id = Map.get(attrs, :entity_id)
    payload = Map.get(attrs, :payload, %{})

    entry_hash =
      compute_hash(%{
        tenant_id: tenant_id,
        position: position,
        prev_hash: prev_hash,
        action: action,
        actor_lineage: actor_lineage,
        entity_type: entity_type,
        entity_id: entity_id,
        payload: payload,
        inserted_at: now
      })

    %{
      chain_position: position,
      prev_entry_hash: prev_hash,
      action: action,
      actor_lineage: actor_lineage,
      entity_type: entity_type,
      entity_id: entity_id,
      payload: payload,
      entry_hash: entry_hash,
      inserted_at: now
    }
  end

  defp compute_hash(%{
         tenant_id: tenant_id,
         position: position,
         prev_hash: prev_hash,
         action: action,
         actor_lineage: actor_lineage,
         entity_type: entity_type,
         entity_id: entity_id,
         payload: payload,
         inserted_at: inserted_at
       }) do
    canonical =
      Jason.encode!(%{
        action: action,
        actor_lineage: actor_lineage,
        entity_id: entity_id,
        entity_type: entity_type,
        payload: payload
      })

    data =
      tenant_id <>
        Integer.to_string(position) <>
        prev_hash <>
        canonical <>
        DateTime.to_iso8601(inserted_at)

    :crypto.hash(:sha256, data)
  end
end
