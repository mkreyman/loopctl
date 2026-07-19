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
  alias Loopctl.Auth.Role
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Projects

  # Uniform retention for every post — one authoritative constant in code, not a
  # DB default (owner decision; the fleet audit showed the category taxonomy and
  # per-type retentions were unused).
  @retention_days 30

  # Read-bound convention (US-39.3): the `channel_recent` endpoint defaults to 25
  # rows and CLAMPS a larger `?limit=` to 100 (not a 400) — see AC-39.3.3. These
  # are the single source of truth for both the context primitive and the HTTP
  # endpoint's `meta.limit`.
  @default_recent_limit 25
  @max_recent_limit 100

  # Read-model preview bound (US-40.D1), in BYTES. The LIST read never returns a
  # full post body: it projects a SMALL bounded prefix via a DB `substring` so the
  # TOASTed `body` column is never detoasted, and — since these previews are
  # injected into every peer agent session on the repo via the SessionStart hook —
  # so the prompt-injection blast radius of any single post stays small. A full
  # body is an explicit, separate fetch (`get_post/2` → GET /channel/posts/:id).
  # This is the SINGLE read-model primitive: US-40.C2's cursor/delta read CONSUMES
  # the same `select_preview/1` + `finalize_preview/1` helpers rather than
  # re-deriving them.
  #
  # This @preview_bytes bound is BYTE-semantic and is enforced authoritatively in
  # ELIXIR (`bounded_preview/1` + `utf8_prefix/2`), NOT by the DB. See
  # `@preview_probe_chars` for why the DB `substring` (which counts CHARACTERS)
  # cannot and does not enforce it.
  @preview_bytes 512

  # The DB projection probe width, in CHARACTERS. Postgres `substring(text FOR n)`
  # counts CHARACTERS, never bytes — so the DB slice does NOT (and cannot) enforce
  # the @preview_bytes BYTE bound. We ask the DB for `@preview_bytes + 1`
  # *characters* purely as a cheap detoast guard + truncation probe: because every
  # UTF-8 character is >= 1 byte, `@preview_bytes + 1` characters is ALWAYS
  # >= `@preview_bytes + 1` bytes, so the returned slice always carries enough
  # bytes to (a) detect that the full body exceeded the @preview_bytes-BYTE bound
  # and (b) have @preview_bytes bytes available to trim back to. The authoritative
  # BYTE bound is then applied in Elixir by `finalize_preview/1`. A maintainer must
  # NEVER trust this DB slice to be byte-bounded — it is character-bounded and
  # deliberately over-fetches.
  @preview_probe_chars @preview_bytes + 1

  @doc "The uniform retention window, in days, applied to every post."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  The bounded preview size, in bytes, the LIST read projects for each post body.
  Exposed so consumers (US-40.C2, tests) share one source of truth.
  """
  @spec preview_bytes() :: pos_integer()
  def preview_bytes, do: @preview_bytes

  @doc """
  Creates a channel post.

  `tenant_id`, `project_id`, `agent_id`, and `expires_at` are set programmatically
  on the struct (never from caller input); only `body` and the optional
  `session_id`/`host`/`key`/`refs`/`to_host`/`to_capability` are cast from `attrs`
  (`to_host`/`to_capability` are the advisory, spoofable, surfacing-only addressing
  fields — see the `ChannelPost` moduledoc trust boundary). `expires_at` is fixed
  at `now + #{@retention_days} days`.

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
  slot's caller-variable payload — `body`, `refs`, `updated_at`, and `expires_at`
  are fully replaced, while the advisory addressing (`to_host`/`to_capability`,
  US-40.A5) is PRESERVE-ON-OMIT: a supplied value re-addresses a handoff slot or
  promotes a broadcast slot to directed, but an OMITTED value keeps the
  previously-set target (COALESCE) rather than NULL-wiping it — so a body-only or
  TTL-only refresh never silently demotes a directed slot out of 40.C1 discovery
  (clearing addressing by omission is intentionally unsupported; delete + re-post
  to demote). `inserted_at`, `host`, and `session_id` are set-once (kept from the
  original insert). A different session's same key is a distinct row. Without a
  `key` every post is a new append-only row.

  ## Returns

    * `{:ok, %ChannelPost{}, :created}` — a new row was inserted (HTTP 201)
    * `{:ok, %ChannelPost{}, :updated}` — an existing session slot was upserted
      in place (HTTP 200)
    * `{:error, :not_found}` — the project is missing or belongs to another
      tenant (endpoint → shared 422)
    * `{:error, :agent_not_found}` — the server-stamped `agent_id` does not belong
      to `tenant_id` (a misconfigured key; endpoint → 403, attributed as an
      identity fault, NOT a cross-tenant project probe)
    * `{:error, %Ecto.Changeset{}}` — a size/shape bound, denylist hit, or NUL
      byte was rejected; nothing was persisted (endpoint → 422)
  """
  @spec post(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, ChannelPost.t(), :created | :updated}
          | {:error, :not_found}
          | {:error, :agent_not_found}
          | {:error, Ecto.Changeset.t()}
  def post(tenant_id, agent_id, attrs) do
    project_id = Map.get(attrs, :project_id)
    audit = Map.get(attrs, :audit, [])

    # Ownership is enforced for BOTH the project and the agent, each mapped to a
    # DISTINCT error so the endpoint attributes the failure correctly — a missing/
    # cross-tenant project is `:not_found` (→ 422 `:ownership_rejected`), a
    # foreign-tenant agent is `:agent_not_found` (→ 403 `:agent_identity_required`).
    # Folding both into one `{:error, :not_found}` would blame `project_id` (and
    # misfire the project security signal) for an identity fault. `agent_id` is
    # server-stamped from the ALREADY-verified key identity and tenant-paired at key
    # creation, so the agent check is defense-in-depth — BUT that pairing is not
    # enforced by any DB constraint (the `agents`/`api_keys`/`channel_posts` agent
    # FKs are all non-composite on `id` alone), so a misconfigured key carrying a
    # foreign-tenant `agent_id` would otherwise persist a post mis-attributed to
    # that foreign agent. Restoring the guard (mirroring sibling `create_post/4`)
    # closes that regression; the NOT NULL FK to `agents` remains the backstop for
    # the "agent row deleted while its api_key persists" race.
    with {:ok, _project} <- Projects.get_project(tenant_id, project_id),
         {:ok, _agent} <- agent_owned(tenant_id, agent_id) do
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

  @doc """
  HARD-deletes a channel post — the redact path (US-39.7).

  The backstop for a leaked/regretted post: whoever NOTICES a leaked secret (the
  denylist is best-effort, US-39.1) can remove the row immediately, before its
  30-day TTL (US-39.5) would sweep it. A hard delete is consistent with the
  transient model — there is nothing to soft-retain in a channel that expires
  wholesale.

  Author-only (or elevated role) — the redact path is for self-leak-pullback,
  NOT fleet-wide cleanup (US-40.D2). `agent_id` is the DELETING agent (the audit
  actor) AND the authorization principal: the delete is permitted ONLY when the
  caller's server-stamped `agent_id` equals the post's AUTHOR `agent_id`, OR the
  caller holds an elevated role (`>= :user`, `role`). This kills the
  censor-and-replace vector: a non-author agent could otherwise hard-delete any
  peer's post on the shared bus. A non-author agent (role `:agent`) attempting to
  delete another agent's post gets `{:error, :not_found}` — BYTE-IDENTICAL to a
  missing post, so there is no existence oracle revealing the post exists but is
  not yours.

  The elevated-role bypass (`>= :user`) is the operator escape hatch: cleaning up
  a leak the author cannot (the author's session is gone). It is gated on the
  VERIFIED key's role — never on spoofable `host`/`session_id`.

  It may NEVER delete a post in another tenant: the fetch filters on BOTH `id`
  and `tenant_id` (the explicit tenant boundary on the AdminRepo path), so a
  foreign (or nonexistent) `post_id` returns `{:error, :not_found}` —
  byte-identical outcomes, no cross-tenant existence oracle (KB "IDOR Prevention
  in Multi-Tenant Delete Operations"). The non-author and foreign-tenant and
  nonexistent cases ALL collapse to the same `{:error, :not_found}`.

  A malformed `post_id` (a non-UUID path segment) is guarded first and returns
  `{:error, :not_found}` too, so a bad id is a clean 404 — never an
  `Ecto.Query.CastError`/500 (mirrors the `valid_uuid?` guard in `recent_page/3`).

  The delete and its audit entry (`entity_type "channel_post"`, action
  `"deleted"`, actor = the deleting agent's key context, capturing the deleted
  post's `id` as `entity_id` and the original author `agent_id` in metadata) run
  in ONE `Ecto.Multi` transaction, so the removal stays accountable even though
  the row is gone.

  `audit` is the actor-context keyword list from
  `LoopctlWeb.AuditContext.from_conn/1`, threaded from the controller.

  Returns `{:ok, %ChannelPost{}}` (the deleted row) or `{:error, :not_found}`.
  """
  @spec delete_post(Ecto.UUID.t(), Ecto.UUID.t(), atom(), term(), keyword()) ::
          {:ok, ChannelPost.t()} | {:error, :not_found | :audit_write_failed}
  def delete_post(tenant_id, agent_id, role, post_id, audit \\ []) do
    # A malformed id (false), a nonexistent/foreign-tenant post (nil), AND a post
    # the caller may NOT delete (present but not theirs and not elevated, false)
    # ALL fall through the `else` to the SAME `{:error, :not_found}` — no oracle
    # revealing the post exists but is not yours (US-40.D2). Only an authorized
    # delete reaches `run_delete/4` (whose `{:ok, _}` / `:audit_write_failed`
    # results are the `with` body's terminal value, never re-mapped by `else`).
    with true <- valid_uuid?(post_id),
         %ChannelPost{} = post <- fetch_owned_post(tenant_id, post_id),
         true <- authorized_to_delete?(post, agent_id, role) do
      run_delete(tenant_id, agent_id, post, audit)
    else
      _ -> {:error, :not_found}
    end
  end

  # US-40.D2 authorization gate: the caller is the post's OWN author (server-
  # stamped `agent_id` equals the post's author `agent_id`) OR holds an elevated
  # role (`>= :user`, the operator escape hatch). Compares the AUTHENTICATED,
  # server-stamped identity only — never spoofable `host`/`session_id`.
  defp authorized_to_delete?(%ChannelPost{agent_id: author_id}, caller_agent_id, caller_role) do
    author_id == caller_agent_id or Role.role_at_least?(caller_role, :user)
  end

  @doc """
  Fetches ONE post by id, tenant-scoped, returning its FULL body — the public,
  shared by-id read (US-40.D1). This is the SINGLE shared by-id path: the
  oracle-safe `GET /channel/posts/:id` endpoint uses it here, and graduate
  (US-40.E1) reuses it rather than duplicating the query. It wraps the same
  private `fetch_owned_post/2` the redact path (`delete_post/4`) uses.

  ORACLE-SAFE, mirroring `delete_post/4`: the fetch filters on BOTH `id` and
  `tenant_id` on `AdminRepo` (BYPASSRLS), so a foreign-tenant OR nonexistent id
  both return `{:error, :not_found}` — byte-identical, no cross-tenant existence
  oracle (KB "IDOR Prevention in Multi-Tenant Delete Operations"). A malformed
  (non-UUID) `post_id` (or `tenant_id`) is guarded first and returns
  `{:error, :not_found}` too — a clean 404, never an `Ecto.Query.CastError`/500.

  Returns `{:ok, %ChannelPost{}}` (the full struct, including the un-truncated
  `body`) or `{:error, :not_found}`.
  """
  @spec get_post(term(), term()) :: {:ok, ChannelPost.t()} | {:error, :not_found}
  def get_post(tenant_id, post_id) do
    if valid_uuid?(tenant_id) and valid_uuid?(post_id) do
      case fetch_owned_post(tenant_id, post_id) do
        nil -> {:error, :not_found}
        post -> {:ok, post}
      end
    else
      {:error, :not_found}
    end
  end

  # Fetch a post by id CONSTRAINED to the caller's tenant — the isolation
  # boundary on the AdminRepo (BYPASSRLS) path. A foreign-tenant or nonexistent
  # id returns nil, so both collapse to the same 404 (no existence oracle). Shared
  # by the redact path (`delete_post/4`) and the public by-id read (`get_post/2`).
  defp fetch_owned_post(tenant_id, post_id) do
    ChannelPost
    |> where([p], p.id == ^post_id and p.tenant_id == ^tenant_id)
    |> AdminRepo.one()
  end

  # Delete + audit in ONE transaction so the removal survives in the trail even
  # though the row is hard-deleted (AC-39.7.3). The DELETING agent is the audit
  # actor (from `audit`); the post's original author is captured in metadata.
  defp run_delete(tenant_id, agent_id, post, audit) do
    multi =
      Multi.new()
      |> Multi.delete(:post, post)
      |> Audit.log_in_multi(:audit, fn %{post: deleted} ->
        delete_audit_attrs(tenant_id, agent_id, deleted, audit)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{post: post}} ->
        {:ok, post}

      # The `:audit` step failed with an invalid changeset. `Multi.delete` never
      # yields such a tuple (a missing row RAISES `Ecto.StaleEntryError`, rescued
      # below), so a convertible Multi error here is ALWAYS the audit insert. Because
      # the delete and the audit share ONE transaction, a failed audit rolls the
      # DELETE back too: the post SURVIVES. This is the redact path (a leaked
      # secret), so folding it into the contract's `:not_found` would be
      # fail-UNSAFE — the caller would read the resulting 404 as "already
      # gone/handled" and believe the secret (and its 30-day-TTL SessionStart
      # injection) is removed when it is NOT. Instead surface a DISTINCT error the
      # controller maps to a 5xx, so the agent RETRIES the redaction rather than
      # trusting a false 404. Matching `:audit` explicitly (not `_step`) preserves
      # the compile-gate `run_delete/4` had: if `Audit.log_in_multi/3` is ever
      # changed to fail with a non-changeset value, this clause stops covering it
      # and dialyzer fails the build here rather than silently mis-mapping it.
      {:error, :audit, %Ecto.Changeset{}, _changes} ->
        {:error, :audit_write_failed}
    end
  rescue
    # Concurrent double-delete. `fetch_owned_post/2` is an UNLOCKED read, so between
    # it and `Multi.delete` another deleter — or the US-39.5 TTL sweep — can remove
    # the row. The feature explicitly enables "whoever NOTICES a leaked secret,
    # fleet-wide" to delete, making two agents deleting the same post a first-class
    # case. The losing DELETE matches 0 rows and Ecto raises `Ecto.StaleEntryError`
    # (Multi does NOT convert a stale delete to an `{:error, ...}` tuple; it
    # propagates out of the transaction). A just-deleted post is now nonexistent,
    # and the AC maps nonexistent → 404, so collapse the race to the SAME idempotent
    # `{:error, :not_found}` a nonexistent id returns — never a 500.
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  defp delete_audit_attrs(tenant_id, agent_id, post, audit) do
    %{
      tenant_id: tenant_id,
      project_id: post.project_id,
      entity_type: "channel_post",
      entity_id: post.id,
      action: "deleted",
      actor_type: Keyword.get(audit, :actor_type, "api_key"),
      actor_id: Keyword.get(audit, :actor_id),
      actor_label: Keyword.get(audit, :actor_label),
      metadata:
        audit
        |> Keyword.get(:metadata, %{})
        |> Map.merge(%{
          "deleted_post_agent_id" => post.agent_id,
          "deleted_by_agent_id" => agent_id
        })
    }
  end

  # Assert the server-stamped agent belongs to the tenant, mapped to a DISTINCT
  # error from the project guard so the endpoint separates an identity fault (403)
  # from a cross-tenant project probe (422).
  defp agent_owned(tenant_id, agent_id) do
    case Agents.get_agent(tenant_id, agent_id) do
      {:ok, agent} -> {:ok, agent}
      {:error, :not_found} -> {:error, :agent_not_found}
    end
  end

  # Insert (or keyed upsert) + audit in one transaction. The created-vs-updated
  # outcome is derived from the PERSISTED row returned by the write itself — never
  # from a pre-transaction existence probe. A pre-read was a TOCTOU race: two
  # concurrent same-session writes could both read `exists? == false` and both
  # report 201 (even though the partial unique index turns one into a DO UPDATE),
  # and a US-39.5 TTL sweep deleting the slot between the read and the insert
  # produced the inverse mislabel — mis-stamping both the 201/200 status and the
  # audit action. Instead: on a fresh INSERT Ecto stamps `inserted_at` and
  # `updated_at` to the SAME instant; the ON CONFLICT DO UPDATE refreshes
  # `updated_at` (a new now) but never `inserted_at` (kept from the original
  # insert). So on the keyed path (`returning: true` reads the real persisted row)
  # equal timestamps ⇒ created and divergent ⇒ in-place update. This reflects the
  # actual write outcome atomically, so the label is correct even under a concurrent
  # same-session race or a sweep deleting the slot mid-flight.
  defp run_post(tenant_id, changeset, audit) do
    key = Ecto.Changeset.get_field(changeset, :key)
    insert_opts = insert_opts(key)

    multi =
      Multi.new()
      |> Multi.insert(:post, changeset, insert_opts)
      |> Audit.log_in_multi(:audit, fn %{post: post} ->
        audit_attrs(tenant_id, post, post_outcome(post), audit)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{post: post}} ->
        {:ok, post, post_outcome(post)}

      {:error, :post, %Ecto.Changeset{} = changeset, _changes} ->
        tap_secret_blocked({:error, changeset})

      # Any OTHER failed step (today only `:audit`, whose only failure mode is a
      # changeset) is normalised to the SAME documented `{:error, %Ecto.Changeset{}}`
      # shape — `run_post/3` never leaks an off-spec `{:error, reason}` to the
      # controller, so no controller catch-all (which dialyzer would reject as dead
      # code) is needed. If `Audit.log_in_multi/3` is ever changed to fail with a
      # non-changeset error, this clause stops covering it and dialyzer fails the
      # build here (a compile-gate guard, stronger than a runtime 500 fallback).
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Keyless posts are always a new append-only row. A keyed post UPSERTS on the
  # LIVE PARTIAL unique index (`... WHERE key IS NOT NULL`, index
  # `channel_posts_session_key_uidx`). Postgres cannot INFER a partial index from a
  # bare column list — the ON CONFLICT must carry the matching predicate — so the
  # conflict_target is an unsafe_fragment mirroring the index columns AND its WHERE
  # clause (same pattern as memory.ex:2510). `agent_id` participates so a spoofed
  # session_id can never overwrite another agent's slot. `returning: true` is
  # REQUIRED on the upsert path: on a DO UPDATE Ecto otherwise leaves the returned
  # struct's autogenerated `id` and timestamps at the phantom values it generated
  # for the INSERT ATTEMPT (the existing row kept its own). Reading the row back
  # makes the returned struct — the response JSON, the audit entity_id, AND the
  # `post_outcome/1` timestamp comparison — reflect the real persisted row.
  #
  # The DO UPDATE refreshes the CALLER-VARIABLE payload — the fields a re-post of
  # the SAME working-state slot may legitimately change — but with TWO distinct
  # merge rules, because the fields differ in how a caller signals intent:
  #
  #   * FULL REPLACE (`body`/`refs`/`updated_at`/`expires_at`) — overwritten with
  #     the incoming values every time. `body` is `validate_required`, so it can
  #     never be accidentally omitted; `refs` is content the caller re-curates with
  #     each post; the two timestamps are the refresh instant and the TTL extension.
  #
  #   * PRESERVE-ON-OMIT (`to_host`/`to_capability`, US-40.A5) — advisory addressing,
  #     merged with `COALESCE(EXCLUDED.<field>, existing.<field>)`: a non-nil
  #     incoming value re-addresses (or promotes a broadcast slot to directed), but
  #     an OMITTED value (nil) KEEPS the previously-set target rather than wiping it.
  #     This is deliberate and asymmetric to `body`: addressing is OPTIONAL and is
  #     the field a refresh most commonly omits — the controller sends
  #     `to_host: params["to_host"]` (nil when the JSON omits it) and the MCP proxy
  #     only adds the keys when present (`if (to_host) payload.to_host = to_host`),
  #     so a keyed re-post that touches only `body` or extends TTL through the normal
  #     agent path carries NO addressing. Under a plain replace that would silently
  #     NULL-wipe the routing and demote a directed handoff slot to broadcast,
  #     dropping it out of 40.C1 directed discovery (`to_host=$me OR to_capability
  #     IN $caps`) with no error surfaced — breaking the exact directed-handoff use
  #     case this story exists to enable. COALESCE makes an accidental omission a
  #     no-op instead of a silent routing loss. Re-addressing still works (a non-nil
  #     value wins); the only thing you CANNOT do by omission is CLEAR addressing
  #     (demote a directed slot back to broadcast) — a deliberately unsupported,
  #     never-designed-for path. To demote, delete the slot (US-39.7) and re-post
  #     without addressing.
  #
  # Deliberately UNTOUCHED (set-once at first insert): `inserted_at` (so
  # `post_outcome/1` can tell created from updated), and `host`/`session_id`, which
  # are slot-identity/attribution metadata the story mandates mirroring from the
  # original insert, not refreshable payload.
  defp insert_opts(nil), do: []

  defp insert_opts(_key) do
    [
      on_conflict: keyed_slot_on_conflict(),
      conflict_target:
        {:unsafe_fragment,
         "(tenant_id, project_id, agent_id, session_id, key) WHERE key IS NOT NULL"},
      returning: true
    ]
  end

  # DO UPDATE for a keyed working-state slot. `body`/`refs`/`updated_at`/`expires_at`
  # are replaced with the incoming values (`EXCLUDED.*` is the row we tried to
  # insert); `to_host`/`to_capability` COALESCE the incoming value over the stored
  # one so an OMITTED (nil) advisory target preserves the previously-set routing
  # instead of NULL-wiping it (see the insert_opts/1 comment for why addressing is
  # preserve-on-omit while body is full-replace). Mirrors the `EXCLUDED`-driven
  # on_conflict query in `Loopctl.AuditChain`.
  defp keyed_slot_on_conflict do
    from(p in ChannelPost,
      update: [
        set: [
          body: fragment("EXCLUDED.body"),
          refs: fragment("EXCLUDED.refs"),
          to_host: fragment("COALESCE(EXCLUDED.to_host, ?)", p.to_host),
          to_capability: fragment("COALESCE(EXCLUDED.to_capability, ?)", p.to_capability),
          updated_at: fragment("EXCLUDED.updated_at"),
          expires_at: fragment("EXCLUDED.expires_at")
        ]
      ]
    )
  end

  # Created vs in-place update, read from the PERSISTED row (see run_post/3). A
  # fresh insert stamps both timestamps to the same instant; a keyed upsert's DO
  # UPDATE refreshes `updated_at` while preserving the original `inserted_at`, so
  # equal ⇒ created, divergent ⇒ updated.
  defp post_outcome(%ChannelPost{inserted_at: ts, updated_at: ts}), do: :created
  defp post_outcome(%ChannelPost{}), do: :updated

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
  `tenant_id`/`project_id` (e.g. a malformed path segment from the
  `channel_recent` endpoint) yields `[]` rather than an `Ecto.Query.CastError` —
  mirroring the `valid_uuid?` guard in `Projects.get_project`. This is also the
  oracle-safe path: a cross-tenant or nonexistent (but well-formed) `project_id`
  is simply excluded by the explicit `tenant_id`/`project_id` filter and yields
  `[]` — identical to an owned-but-empty channel, revealing nothing about whether
  the project exists in another tenant. `opts`:

    * `:limit` — max rows (default #{@default_recent_limit}, capped at
      #{@max_recent_limit}); `limit: 0` (or negative) returns `[]`. Accepts an
      integer or an integer STRING (e.g. `"0"`/`"1000"` from the `?limit=` query
      param) so the documented contract holds for the real endpoint input; any
      other value falls back to the default.
    * `:since` — when present, returns only posts touched AFTER this instant,
      filtering `GREATEST(inserted_at, updated_at) > since` so a keyed slot
      upserted after `since` (its `updated_at` advanced) still surfaces as a
      delta. In this delta mode the ORDER BY is also `GREATEST(inserted_at,
      updated_at) DESC` (not plain `inserted_at DESC`) so a re-touched slot ranks
      by its most-recent touch and is not the first row dropped by `:limit`.
      Accepts a `DateTime` or a full ISO8601 INSTANT string (as a `?since=` query
      param arrives) — an OFFSET-LESS but valid instant (e.g.
      `"2026-07-18T00:00:00"`) is interpreted as UTC. A malformed, absent, or
      wrong-granularity value (e.g. a date-only `"2026-07-18"`) is a NO-OP filter
      that returns the whole live channel — never a 400; supply a full instant to
      get a delta.
  """
  @spec recent(term(), term(), keyword()) :: [preview()]
  def recent(tenant_id, project_id, opts \\ []) do
    {posts, _has_more} = recent_page(tenant_id, project_id, opts)
    posts
  end

  @doc """
  Like `recent/3` but also reports whether the `:limit` TRUNCATED the result.

  Returns `{posts, has_more}` where `has_more` is `true` iff at least one more
  live, matching post exists beyond the applied `:limit`. Detected by fetching
  `limit + 1` rows and checking for the overflow row (no extra COUNT query), so
  the endpoint can surface an HONEST truncation signal in its `meta` envelope
  rather than leaving consumers to infer it from `count == limit`. A full cursor
  (paging past the truncation) is out of scope — US-39.6 owns dedup/paging; this
  is only the cheap "there is more" flag.
  """
  @spec recent_page(term(), term(), keyword()) :: {[preview()], boolean()}
  def recent_page(tenant_id, project_id, opts \\ []) do
    if valid_uuid?(tenant_id) and valid_uuid?(project_id) do
      limit = opts |> Keyword.get(:limit, @default_recent_limit) |> clamp_limit()
      since = opts |> Keyword.get(:since) |> normalize_since()
      now = DateTime.utc_now()

      rows =
        ChannelPost
        |> where([p], p.tenant_id == ^tenant_id and p.project_id == ^project_id)
        |> where([p], p.expires_at > ^now)
        |> apply_since(since)
        |> order_recent(since)
        |> select_preview()
        |> limit(^(limit + 1))
        |> AdminRepo.all()

      page = rows |> Enum.take(limit) |> Enum.map(&finalize_preview/1)
      {page, length(rows) > limit}
    else
      {[], false}
    end
  end

  @typedoc """
  A single LIST-read row: a bounded read-model projection (NOT a `%ChannelPost{}`).
  Carries `body_preview` (a prefix of at most `#{@preview_bytes}` bytes) + `truncated`
  instead of the full `body`, plus the attribution/addressing/timestamp fields.
  """
  @type preview :: %{
          id: Ecto.UUID.t(),
          agent_id: Ecto.UUID.t(),
          session_id: String.t() | nil,
          host: String.t() | nil,
          to_host: String.t() | nil,
          to_capability: String.t() | nil,
          key: String.t() | nil,
          refs: term(),
          body_preview: String.t() | nil,
          truncated: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  The shared read-model preview projection (US-40.D1) — the SINGLE read primitive
  the LIST read here and US-40.C2's cursor/delta read both use.

  Projects a bounded `body_preview` via `substring(body for #{@preview_probe_chars})`
  so Postgres NEVER detoasts the full (up to 16KB, TOASTed) `body` column — it reads
  at most `#{@preview_probe_chars}` CHARACTERS. Note `substring(text FOR n)` counts
  CHARACTERS, not bytes, so this DB slice is CHARACTER-bounded, not byte-bounded: it
  is a cheap detoast guard + truncation probe, NOT the byte-bound enforcement. The
  extra `+1` character (`@preview_probe_chars` = `@preview_bytes + 1`) is the
  truncation probe; because every UTF-8 character is >= 1 byte, the slice always
  carries enough bytes for `finalize_preview/1` to (a) derive `truncated` and
  (b) trim the returned preview back to at most `#{@preview_bytes}` BYTES — the
  authoritative byte bound, applied in Elixir, never by the DB. Every other read
  field is projected directly; `body` itself is deliberately absent (fetch it
  explicitly via `get_post/2`).
  """
  @spec select_preview(Ecto.Query.t()) :: Ecto.Query.t()
  def select_preview(query) do
    select(query, [p], %{
      id: p.id,
      agent_id: p.agent_id,
      session_id: p.session_id,
      host: p.host,
      to_host: p.to_host,
      to_capability: p.to_capability,
      key: p.key,
      refs: p.refs,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at,
      # CHARACTER-bounded over-fetch (see @preview_probe_chars) — NOT byte-bounded.
      body_preview: fragment("substring(? for ?)", p.body, ^@preview_probe_chars)
    })
  end

  @doc """
  Finalizes one `select_preview/1` projection row. This is where the authoritative
  `#{@preview_bytes}`-BYTE bound is enforced (the DB slice is only CHARACTER-bounded
  — see `select_preview/1`): derives `truncated` from the `#{@preview_probe_chars}`-
  character probe slice and bounds `body_preview` to at most `#{@preview_bytes}`
  BYTES (on a UTF-8 codepoint boundary, so the returned JSON is always valid).
  Shared with US-40.C2 so both reads shape rows identically.
  """
  @spec finalize_preview(map()) :: preview()
  def finalize_preview(%{body_preview: raw} = row) do
    {preview, truncated} = bounded_preview(raw)

    row
    |> Map.put(:body_preview, preview)
    |> Map.put(:truncated, truncated)
  end

  # `body` is `validate_required`, so the projected slice is a binary in practice;
  # the nil clause is defensive. This is the authoritative BYTE-bound enforcement
  # (the DB slice is only character-bounded): `truncated` is true iff the slice is
  # MORE than @preview_bytes BYTES (i.e. the full body exceeded the byte bound —
  # sound because the character-bounded DB over-fetch always carries enough bytes
  # to observe this); in that case trim the returned preview back to @preview_bytes
  # bytes on a valid UTF-8 boundary.
  defp bounded_preview(raw) when is_binary(raw) do
    if byte_size(raw) > @preview_bytes do
      {utf8_prefix(raw, @preview_bytes), true}
    else
      {raw, false}
    end
  end

  defp bounded_preview(_), do: {nil, false}

  # Largest valid-UTF-8 prefix of `str` no longer than `max` bytes. The DB
  # substring returns whole codepoints, so a byte-cut can split at most a 1–3 byte
  # trailing codepoint; drop trailing bytes until the prefix is valid UTF-8 (so
  # Jason never chokes on a half codepoint). At most 3 iterations.
  defp utf8_prefix(str, max) when byte_size(str) <= max, do: str

  defp utf8_prefix(str, max) do
    candidate = binary_part(str, 0, max)
    if String.valid?(candidate), do: candidate, else: utf8_prefix(str, max - 1)
  end

  @doc """
  Clamps a `:limit` value to the `channel_recent` read-bound contract (default
  #{@default_recent_limit}, cap #{@max_recent_limit}), accepting an integer or an
  integer string. Exposed so the HTTP endpoint can report the ACTUALLY-applied
  limit in its `meta` envelope from the SAME source of truth `recent/3` uses,
  never a divergent second copy.
  """
  @spec clamp_recent_limit(term()) :: non_neg_integer()
  def clamp_recent_limit(limit), do: clamp_limit(limit)

  # Resolve the caller's `:since` (a `DateTime`, an ISO8601 string, or
  # nil/garbage) to a single `%DateTime{}` or `nil`, ONCE, so the delta FILTER
  # (`apply_since/2`) and the delta ORDERING (`order_recent/2`) agree on the same
  # value. A malformed, absent, or wrong-granularity (date-only) value resolves to
  # `nil` — a no-op filter with the default ordering, never a 400.
  defp normalize_since(%DateTime{} = since), do: since

  defp normalize_since(since) when is_binary(since) do
    case parse_since(since) do
      {:ok, dt} -> dt
      :error -> nil
    end
  end

  defp normalize_since(_since), do: nil

  # `:since` delta filter. Filters to posts whose most-recent touch —
  # GREATEST(inserted_at, updated_at) — is strictly after `since`, so a session
  # slot upserted after `since` still surfaces even though its `inserted_at`
  # predates it. `nil` (absent/malformed/date-only) is a no-op so a bad `?since=`
  # degrades to "no filter", never a 400.
  defp apply_since(query, %DateTime{} = since) do
    where(query, [p], fragment("GREATEST(?, ?)", p.inserted_at, p.updated_at) > ^since)
  end

  defp apply_since(query, nil), do: query

  # AC-39.3.1 orders the plain read `inserted_at DESC`. But a DELTA read (`since`
  # present) filters on GREATEST(inserted_at, updated_at) — so a keyed slot whose
  # `updated_at` (not `inserted_at`) advanced past `since` MATCHES the filter yet,
  # ordered by its stale `inserted_at`, would rank last among matched rows and be
  # the FIRST dropped by LIMIT — the exact SessionStart working-state slot the bus
  # exists to surface (US-39.6 dedup). In delta mode we therefore order by the SAME
  # GREATEST(inserted_at, updated_at) the filter uses, so a re-touched slot ranks
  # by its most-recent touch and is not silently truncated. The non-delta read
  # keeps the AC-mandated `inserted_at DESC`. `seq` (bigserial) DESC tie-breaks.
  defp order_recent(query, %DateTime{}) do
    order_by(query, [p],
      desc: fragment("GREATEST(?, ?)", p.inserted_at, p.updated_at),
      desc: p.seq
    )
  end

  defp order_recent(query, nil) do
    order_by(query, [p], desc: p.inserted_at, desc: p.seq)
  end

  # Parse an ISO8601 `since` into a UTC DateTime. `DateTime.from_iso8601/1` only
  # accepts an offset-bearing instant (the `...Z`/`+HH:MM` form that
  # `DateTime.to_iso8601/1` emits on the programmatic path). A hand-crafted or
  # tool-supplied but otherwise-valid OFFSET-LESS instant (e.g.
  # "2026-07-18T00:00:00") returns `{:error, :missing_offset}` there — so without
  # this fallback it would fall through to the no-op clause and SILENTLY disable
  # the delta filter, returning the whole channel and defeating the "read only
  # what's new" contract. Interpret an offset-less-but-valid ISO8601 instant as
  # UTC (loopctl stores every timestamp in UTC) rather than dropping the filter.
  defp parse_since(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, :missing_offset} ->
        case NaiveDateTime.from_iso8601(since) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          _ -> :error
        end

      _ ->
        :error
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

  # The `channel_recent` endpoint (US-39.3) passes `?limit=` through as a string.
  # Parse an integer string and re-clamp so the documented contract (`"0"` -> [],
  # `"1000"` capped at #{@max_recent_limit}) holds; a non-integer / trailing-garbage
  # value falls back to the default rather than silently returning the default for
  # a well-formed `"0"`.
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
