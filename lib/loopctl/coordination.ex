defmodule Loopctl.Coordination do
  @moduledoc """
  Context for the coordination bus — a project-scoped, append-only, short-lived
  channel that lets agent sessions on the same repo (across machines) see each
  other's working-state.

  A **channel is a `project_id`**. A post is one attributed message with a
  uniform 30-day TTL; there is no message-type taxonomy. Durable keepers
  graduate to Knowledge — the rest expires.

  ## Isolation

  Like Knowledge and Projects, every query runs via `AdminRepo` (BYPASSRLS) with
  an **explicit `tenant_id` filter** — RLS on `channel_posts` is defense-in-depth,
  not the primary boundary. A query that omits the tenant filter is a bug.

  This module (US-39.1) provides the schema-level primitives — programmatic
  insert and a minimal tenant/project-scoped read. The write endpoint's ownership
  check, audit, per-session upsert, and rate limiting (US-39.2) and the full
  `channel_recent` read endpoint (US-39.3) build on these.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost

  # Uniform retention for every post — one authoritative constant in code, not a
  # DB default (owner decision; the fleet audit showed the category taxonomy and
  # per-type retentions were unused).
  @retention_days 30

  @default_recent_limit 50
  @max_recent_limit 200

  @doc "The uniform retention window, in days, applied to every post."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  Creates a channel post.

  `tenant_id`, `project_id`, `agent_id`, and `expires_at` are set programmatically
  on the struct (never from caller input); only `body` and the optional
  `session_id`/`host`/`key`/`refs` are cast from `attrs`. `expires_at` is fixed at
  `now + #{@retention_days} days`.

  Returns `{:ok, %ChannelPost{}}` or `{:error, %Ecto.Changeset{}}` (size/shape
  bound violation or a secret-denylist hit — the caller learns the content did
  not land).
  """
  @spec create_post(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, ChannelPost.t()} | {:error, Ecto.Changeset.t()}
  def create_post(tenant_id, project_id, agent_id, attrs) do
    %ChannelPost{
      tenant_id: tenant_id,
      project_id: project_id,
      agent_id: agent_id,
      expires_at: default_expires_at()
    }
    |> ChannelPost.create_changeset(attrs)
    |> AdminRepo.insert()
  end

  @doc """
  Returns recent, non-expired posts for a tenant's project channel, newest first.

  Isolation is the explicit `tenant_id` filter (AdminRepo path); expired posts
  are filtered defensively even before the TTL sweep runs. `opts`:

    * `:limit` — max rows (default #{@default_recent_limit}, capped at #{@max_recent_limit})
  """
  @spec recent(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: [ChannelPost.t()]
  def recent(tenant_id, project_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_recent_limit) |> clamp_limit()
    now = DateTime.utc_now()

    ChannelPost
    |> where([p], p.tenant_id == ^tenant_id and p.project_id == ^project_id)
    |> where([p], p.expires_at > ^now)
    |> order_by([p], desc: p.inserted_at)
    |> limit(^limit)
    |> AdminRepo.all()
  end

  defp default_expires_at do
    DateTime.add(DateTime.utc_now(), @retention_days * 24 * 60 * 60, :second)
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_recent_limit)

  defp clamp_limit(_), do: @default_recent_limit
end
