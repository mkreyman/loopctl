defmodule Loopctl.AuditChain.PubSub do
  @moduledoc """
  US-26.5.1 — PubSub broadcast for audit chain events.

  Broadcasts new audit chain entries and STH computations to per-tenant
  topics so agents can maintain an STH cache for witness verification.

  ## Firehose topic (US-35.2)

  In addition to the per-tenant `"audit_chain:<tenant_id>"` topics, every
  audit-chain append is ALSO broadcast to a single fixed firehose topic
  (`"audit_chain:events"`). This lets one supervised, node-local subscriber
  (`Loopctl.AuditChain.SthEnqueuer`) observe appends across ALL tenants without
  subscribing to N per-tenant topics, so STH computation can be driven by real
  append activity instead of only the per-minute cron.

  The firehose keeps the SAME `{:audit_chain_entry, _}` tuple TAG as the
  per-tenant topic, but its payload is MINIMIZED to `%{tenant_id: entry.tenant_id}`
  — the only field the sole subscriber reads. The full `%Entry{}` (with its
  arbitrary `:payload` map and `:actor_lineage`) is therefore never placed on
  this fixed, non-tenant-scoped topic, so no tenant's entry contents fan out
  across nodes on it or become visible to any future firehose subscriber. The
  per-tenant topic still carries the full entry and its subscribers are
  UNCHANGED.
  """

  @topic_prefix "audit_chain:"

  # US-35.2: single fixed cross-tenant firehose topic. Fixed (not per-tenant) so
  # a single supervised subscriber can watch every tenant's appends. The message
  # carries ONLY `tenant_id` (the subscriber's sole tenant-scoping input), so this
  # shared topic never transports per-tenant entry payloads across nodes.
  @firehose_topic "#{@topic_prefix}events"

  @doc "Broadcasts a new audit chain entry to the tenant's topic."
  @spec broadcast_entry(Ecto.UUID.t(), map()) :: :ok
  def broadcast_entry(tenant_id, entry) do
    Phoenix.PubSub.broadcast(
      Loopctl.PubSub,
      topic(tenant_id),
      {:audit_chain_entry, entry}
    )
  end

  @doc """
  Broadcasts a MINIMAL tenant-scoped notification to the fixed cross-tenant
  firehose topic (US-35.2). Additive: callers still broadcast the full entry to
  the per-tenant topic via `broadcast_entry/2`. Fire-and-forget — the append
  path never depends on it.

  Only `entry.tenant_id` is placed on the wire (as `%{tenant_id: tenant_id}`,
  keeping the `{:audit_chain_entry, _}` tuple tag) because that is the single
  field the sole subscriber (`SthEnqueuer`) reads. This keeps the shared,
  non-tenant-scoped topic from ever carrying an entry's `:payload`/`:actor_lineage`
  and halves the per-append cross-node bytes the firehose fans out.
  """
  @spec broadcast_entry_firehose(map()) :: :ok
  def broadcast_entry_firehose(%{tenant_id: tenant_id}) do
    Phoenix.PubSub.broadcast(
      Loopctl.PubSub,
      @firehose_topic,
      {:audit_chain_entry, %{tenant_id: tenant_id}}
    )
  end

  @doc "Broadcasts a new STH to the tenant's topic."
  @spec broadcast_sth(Ecto.UUID.t(), map()) :: :ok
  def broadcast_sth(tenant_id, sth) do
    Phoenix.PubSub.broadcast(
      Loopctl.PubSub,
      topic(tenant_id),
      {:sth_updated, sth}
    )
  end

  @doc "Subscribes to a tenant's audit chain events."
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(tenant_id) do
    Phoenix.PubSub.subscribe(Loopctl.PubSub, topic(tenant_id))
  end

  @doc "Subscribes to the fixed cross-tenant audit-chain firehose topic (US-35.2)."
  @spec subscribe_firehose() :: :ok | {:error, term()}
  def subscribe_firehose do
    Phoenix.PubSub.subscribe(Loopctl.PubSub, @firehose_topic)
  end

  @doc "Returns the PubSub topic for a tenant."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(tenant_id), do: "#{@topic_prefix}#{tenant_id}"

  @doc "Returns the fixed cross-tenant audit-chain firehose topic (US-35.2)."
  @spec firehose_topic() :: String.t()
  def firehose_topic, do: @firehose_topic
end
