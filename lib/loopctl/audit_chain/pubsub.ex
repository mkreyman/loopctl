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
  append activity instead of only the per-minute cron. The firehose carries the
  SAME `{:audit_chain_entry, entry}` message shape as the per-tenant topic; the
  per-tenant topic and its subscribers are UNCHANGED.
  """

  @topic_prefix "audit_chain:"

  # US-35.2: single fixed cross-tenant firehose topic. Fixed (not per-tenant) so
  # a single supervised subscriber can watch every tenant's appends. The message
  # itself carries `entry.tenant_id`, so the subscriber stays fully tenant-scoped
  # without any per-tenant subscription.
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
  Broadcasts a new audit chain entry to the fixed cross-tenant firehose topic
  (US-35.2). Additive: callers still broadcast to the per-tenant topic via
  `broadcast_entry/2`. Fire-and-forget — the append path never depends on it.
  """
  @spec broadcast_entry_firehose(map()) :: :ok
  def broadcast_entry_firehose(entry) do
    Phoenix.PubSub.broadcast(
      Loopctl.PubSub,
      @firehose_topic,
      {:audit_chain_entry, entry}
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
