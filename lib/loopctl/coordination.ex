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

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Agents
  alias Loopctl.Audit
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Projects

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

  Both `project_id` and `agent_id` must belong to `tenant_id`; a mispaired call
  returns `{:error, :not_found}` rather than inserting a cross-tenant-shaped row
  (the primitive asserts its own ownership invariant for BOTH ids — the write
  endpoint's fuller ownership/audit path is US-39.2). In the real flow `agent_id`
  is server-stamped from the verified key identity so it always matches; the
  explicit check is defense-in-depth mirroring the `project_id` guard, so the
  ownership invariant is not silently one-sided.

  Returns `{:ok, %ChannelPost{}}`, `{:error, %Ecto.Changeset{}}` (size/shape
  bound violation, a secret-denylist hit, or a session-key slot collision — the
  caller learns the content did not land), or `{:error, :not_found}` when the
  project or agent does not belong to the tenant.
  """
  @spec create_post(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, ChannelPost.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_post(tenant_id, project_id, agent_id, attrs) do
    with {:ok, _project} <- Projects.get_project(tenant_id, project_id),
         {:ok, _agent} <- Agents.get_agent(tenant_id, agent_id) do
      %ChannelPost{
        tenant_id: tenant_id,
        project_id: project_id,
        agent_id: agent_id,
        expires_at: default_expires_at()
      }
      |> ChannelPost.create_changeset(attrs)
      |> AdminRepo.insert()
      |> tap_secret_blocked()
    end
  end

  @doc """
  Writes a coordination post on behalf of a **verified agent identity**, with
  ownership enforcement, audit, and per-session upsert — the HTTP write path
  (US-39.2). This is the richer sibling of `create_post/4`: it runs the insert
  (or keyed upsert) and the audit-log write in a single `AdminRepo.transaction`
  so authorship is tamper-evident, and it distinguishes a freshly-created post
  from an in-place slot update so the endpoint can answer 201 vs 200.

  `tenant_id` and `agent_id` are server-stamped by the caller (from the verified
  key identity — never the request body). `attrs` carries the caller-supplied
  fields plus two context keys the changeset never casts:

    * `:project_id` — the channel; ownership is checked via
      `Projects.get_project/2`. A missing OR cross-tenant project returns the
      SAME `{:error, :not_found}` (no existence oracle — the endpoint maps both
      to one byte-identical 422).
    * `:audit` — the actor context keyword list (from
      `LoopctlWeb.AuditContext.from_conn/1`) written into the audit entry.

  `expires_at` is fixed server-side at `now + #{@retention_days} days`.

  ## Upsert semantics

  With a `key` present the write UPSERTS on the LIVE partial unique index
  `(tenant_id, project_id, agent_id, session_id, key) WHERE key IS NOT NULL` —
  `agent_id` participates (it is server-stamped and constant per session, so
  this changes nothing observable versus the doc's stale
  `(tenant, project, session, key)` target, but it MUST match the live index or
  the insert raises). A repeat write from the SAME session refreshes its own
  slot (`body`/`refs`/`updated_at`/`expires_at`); a different session's same key
  is a distinct row. Without a `key` every post is a new append-only row.

  ## Returns

    * `{:ok, %ChannelPost{}, :created}` — a new row was inserted (HTTP 201)
    * `{:ok, %ChannelPost{}, :updated}` — an existing session slot was upserted
      in place (HTTP 200)
    * `{:error, :not_found}` — the project is missing or belongs to another
      tenant (endpoint → shared 422)
    * `{:error, %Ecto.Changeset{}}` — a size/shape bound, denylist hit, or NUL
      byte was rejected; nothing was persisted (endpoint → 422)
  """
  @spec post(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, ChannelPost.t(), :created | :updated}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
  def post(tenant_id, agent_id, attrs) do
    project_id = Map.get(attrs, :project_id)
    audit = Map.get(attrs, :audit, [])

    with {:ok, _project} <- Projects.get_project(tenant_id, project_id),
         {:ok, _agent} <- Agents.get_agent(tenant_id, agent_id) do
      changeset =
        %ChannelPost{
          tenant_id: tenant_id,
          project_id: project_id,
          agent_id: agent_id,
          expires_at: default_expires_at()
        }
        |> ChannelPost.create_changeset(attrs)

      run_post(tenant_id, changeset, audit)
    end
  end

  # Insert (or keyed upsert) + audit in one transaction. The created/updated
  # outcome is resolved from a pre-existence check on the slot rather than the
  # returned row's timestamps: with `on_conflict: {:replace, ...}` Ecto does NOT
  # read `inserted_at` back, so `inserted_at == updated_at` cannot distinguish an
  # insert from an update. The slot is keyed on `agent_id + session_id`, and a
  # single session is single-threaded, so the check is race-free in practice
  # (a different session targets a different slot).
  defp run_post(tenant_id, changeset, audit) do
    key = Ecto.Changeset.get_field(changeset, :key)

    {insert_opts, outcome} =
      if is_nil(key) do
        {[], :created}
      else
        # The LIVE arbiter is a PARTIAL unique index
        # (`... WHERE key IS NOT NULL`, index `channel_posts_session_key_uidx`).
        # Postgres cannot INFER a partial index from a bare column list — the
        # ON CONFLICT must carry the matching predicate — so the conflict_target
        # is an unsafe_fragment mirroring the index columns AND its WHERE clause
        # (same pattern as memory.ex:2510). agent_id participates so a spoofed
        # session_id can never overwrite another agent's slot.
        {[
           on_conflict: {:replace, [:body, :refs, :updated_at, :expires_at]},
           conflict_target:
             {:unsafe_fragment,
              "(tenant_id, project_id, agent_id, session_id, key) WHERE key IS NOT NULL"},
           # `returning: true` is REQUIRED on the upsert path: on a DO UPDATE,
           # Ecto otherwise leaves the returned struct's autogenerated `id` (and
           # timestamps) at the values it generated for the INSERT ATTEMPT — a
           # phantom id that was never persisted (the existing row kept its own).
           # Reading the row back makes the returned struct (and the response
           # JSON / audit entity_id) reflect the real persisted row.
           returning: true
         ], slot_outcome(changeset)}
      end

    multi =
      Multi.new()
      |> Multi.insert(:post, changeset, insert_opts)
      |> Audit.log_in_multi(:audit, fn %{post: post} ->
        audit_attrs(tenant_id, post, outcome, audit)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{post: post}} ->
        {:ok, post, outcome}

      {:error, :post, %Ecto.Changeset{} = changeset, _changes} ->
        tap_secret_blocked({:error, changeset})

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Does the keyed working-state slot already exist? Determines 201 (created) vs
  # 200 (upsert-updated). Matches the LIVE partial unique index columns exactly.
  defp slot_outcome(changeset) do
    tenant_id = Ecto.Changeset.get_field(changeset, :tenant_id)
    project_id = Ecto.Changeset.get_field(changeset, :project_id)
    agent_id = Ecto.Changeset.get_field(changeset, :agent_id)
    session_id = Ecto.Changeset.get_field(changeset, :session_id)
    key = Ecto.Changeset.get_field(changeset, :key)

    exists? =
      ChannelPost
      |> where([p], p.tenant_id == ^tenant_id and p.project_id == ^project_id)
      |> where([p], p.agent_id == ^agent_id and p.session_id == ^session_id and p.key == ^key)
      |> AdminRepo.exists?()

    if exists?, do: :updated, else: :created
  end

  defp audit_attrs(tenant_id, post, outcome, audit) do
    %{
      tenant_id: tenant_id,
      project_id: post.project_id,
      entity_type: "channel_post",
      entity_id: post.id,
      action: if(outcome == :created, do: "posted", else: "upserted"),
      actor_type: Keyword.get(audit, :actor_type, "api_key"),
      actor_id: Keyword.get(audit, :actor_id),
      actor_label: Keyword.get(audit, :actor_label),
      metadata: Keyword.get(audit, :metadata, %{})
    }
  end

  # Fire the "credential blocked" security signal once, at the point a write is
  # actually rejected — NOT inside the (pure) changeset builder, which would
  # re-emit on every rebuild/preview and double-count the signal. A no-op unless
  # the rejection carries a secret-denylist error.
  defp tap_secret_blocked({:error, %Ecto.Changeset{} = changeset} = result) do
    ChannelPost.emit_secret_blocked_events(changeset)
    result
  end

  defp tap_secret_blocked(result), do: result

  @doc """
  Returns recent, non-expired posts for a tenant's project channel, newest first.

  Ordering is `inserted_at DESC`, tie-broken by the monotonic `seq` (bigserial)
  DESC — so two posts sharing the same microsecond `inserted_at` sort by true
  insertion order, not by their random v4 `id`. Newest-first is therefore
  insert-order-correct, not merely stable.

  Isolation is the explicit `tenant_id` filter (AdminRepo path); expired posts
  are filtered defensively even before the TTL sweep runs. A non-UUID
  `tenant_id`/`project_id` (e.g. a malformed path segment once US-39.3 wires an
  endpoint) yields `[]` rather than an `Ecto.Query.CastError` — mirroring the
  `valid_uuid?` guard in `Projects.get_project`. `opts`:

    * `:limit` — max rows (default #{@default_recent_limit}, capped at
      #{@max_recent_limit}); `limit: 0` (or negative) returns `[]`. Accepts an
      integer or an integer STRING (e.g. `"0"`/`"1000"` from a `?limit=` query
      param once US-39.3 wires an endpoint) so the documented contract holds for
      the real endpoint input; any other value falls back to the default.
  """
  @spec recent(term(), term(), keyword()) :: [ChannelPost.t()]
  def recent(tenant_id, project_id, opts \\ []) do
    if valid_uuid?(tenant_id) and valid_uuid?(project_id) do
      limit = opts |> Keyword.get(:limit, @default_recent_limit) |> clamp_limit()
      now = DateTime.utc_now()

      ChannelPost
      |> where([p], p.tenant_id == ^tenant_id and p.project_id == ^project_id)
      |> where([p], p.expires_at > ^now)
      |> order_by([p], desc: p.inserted_at, desc: p.seq)
      |> limit(^limit)
      |> AdminRepo.all()
    else
      []
    end
  end

  defp default_expires_at do
    DateTime.add(DateTime.utc_now(), @retention_days * 24 * 60 * 60, :second)
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_recent_limit)

  # An explicit non-positive limit means "no rows" — honour it rather than
  # silently coercing to the default (LIMIT 0 returns []).
  defp clamp_limit(limit) when is_integer(limit) and limit <= 0, do: 0

  # US-39.3 will wire this to an HTTP endpoint where `?limit=` arrives as a string.
  # Parse an integer string and re-clamp so the documented contract (`"0"` -> [],
  # `"1000"` capped at #{@max_recent_limit}) holds; a non-integer / trailing-garbage
  # value falls back to the default rather than silently returning the default 50
  # for a well-formed `"0"`.
  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} -> clamp_limit(n)
      _ -> @default_recent_limit
    end
  end

  defp clamp_limit(_), do: @default_recent_limit

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false
end
