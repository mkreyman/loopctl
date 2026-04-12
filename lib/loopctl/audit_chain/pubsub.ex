defmodule Loopctl.AuditChain.PubSub do
  @moduledoc """
  US-26.5.1 — PubSub broadcast for audit chain events.

  Broadcasts new audit chain entries and STH computations to per-tenant
  topics so agents can maintain an STH cache for witness verification.
  """

  @topic_prefix "audit_chain:"

  @doc "Broadcasts a new audit chain entry to the tenant's topic."
  @spec broadcast_entry(Ecto.UUID.t(), map()) :: :ok
  def broadcast_entry(tenant_id, entry) do
    Phoenix.PubSub.broadcast(
      Loopctl.PubSub,
      topic(tenant_id),
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

  @doc "Returns the PubSub topic for a tenant."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(tenant_id), do: "#{@topic_prefix}#{tenant_id}"
end
