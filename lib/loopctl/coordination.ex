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
  alias Loopctl.Coordination.ChannelCursor
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.KeysetSeek
  alias Loopctl.Projects
  alias Loopctl.WorkBreakdown.Story

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

  # Commit-lag look-back window, in SECONDS (US-40.C2, AC-40.C2.2). `inserted_at`
  # and `seq` are assigned PRE-COMMIT, so a row with an EARLIER inserted_at / LOWER
  # seq can COMMIT after a later row. A naive delta read at `since = last_seen`
  # would then skip such a late-committing earlier row PERMANENTLY (it sorts before
  # the watermark yet became visible only after the reader passed it). We subtract
  # this bounded epsilon from `since` (`effective_since = since - epsilon`) so rows
  # WITHIN epsilon of the watermark are RE-SCANNED rather than lost.
  #
  # DELIVERY CONTRACT: the SERVER guarantees AT-LEAST-ONCE with a bounded, deliberate
  # OVERLAP — the epsilon look-back re-delivers rows near the watermark, never
  # dropping one. Direction is safe: over-deliver, never lose. EXACTLY-once is the
  # CONSUMER's job (the claude-config turn-boundary hook keeps a per-session
  # high-watermark and dedups the small overlap by id/seq); the server does NOT
  # itself dedup — consumer dedup lives in the companion, out of scope here. Five
  # seconds comfortably covers plausible transaction commit lag on this path while
  # keeping the re-delivered overlap tiny.
  #
  # TRUNCATION-DRAIN RULE (the ONLY caveat to "advance the watermark"): a delta read
  # is bounded by `:limit` (default #{@default_recent_limit}, cap #{@max_recent_limit})
  # and returns `has_more == true` when MORE matching rows exist in the (since, now]
  # window than the limit. Because delta mode orders by GREATEST(inserted_at,
  # updated_at) DESC, truncation drops the OLDEST-touched matching rows, not the
  # newest. A consumer that blindly advances `since` to the newest GREATEST it saw
  # would step PAST those dropped older rows and never see them again (a lost-write
  # gap). The rule that closes the gap: WHILE `has_more` is true, do NOT advance the
  # watermark past the truncation — DRAIN the backlog first via the keyset/history
  # read (`recent_page/3` with `:cursor`, walked to exhaustion; see AC-40.C2.4),
  # which returns EVERY live row (including the truncated older ones) newest→oldest,
  # then advance `since` only once a delta read comes back `has_more == false`. In
  # practice a turn-boundary burst is far under the limit so `has_more` is false and
  # the watermark advances directly; the drain path is the reliability backstop that
  # makes "a long session sees every new post without a lost-write gap" hold even
  # under a burst larger than the cap. (No keyset cursor is emitted in delta mode by
  # design — AC-40.C2.4 — so the drain is the history read, not a delta continuation.)
  @commit_lag_epsilon_seconds 5

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
  key identity — never the request body); `role` is the caller's VERIFIED key
  role (used only for the elevated-role membership bypass, below — never a
  spoofable body field). `attrs` carries the caller-supplied fields plus two
  context keys the changeset never casts:

    * `:project_id` — the channel; ownership is checked via
      `Projects.get_project/2`. A missing OR cross-tenant project returns the
      SAME `{:error, :not_found}` (no existence oracle — the endpoint maps both
      to one byte-identical 422).
    * `:audit` — the actor context keyword list (from
      `LoopctlWeb.AuditContext.from_conn/1`) written into the audit entry.

  `expires_at` is fixed server-side at `now + #{@retention_days} days`.

  ## Project-scoped write authorization (US-40.D3) — default-DENY cross-project

  Owning the target project's TENANT is NOT sufficient to write to its channel:
  the caller must ALSO be a WRITABLE MEMBER of the specific project (see
  `project_writable_by_agent/4`). Absent membership the write is rejected with the
  SAME `{:error, :not_found}` a missing/cross-tenant project returns — so a
  cross-PROJECT attempt (an `:agent` posting to a sibling project in its own
  tenant it is not assigned to) collapses to the byte-identical 422 the
  cross-tenant case yields, no oracle distinguishing "not a member" from "not your
  tenant" from "does not exist". This closes the tenant-wide prompt-injection hole:
  before US-40.D3 any tenant agent key could post into any project channel, and
  that body auto-injects into every peer session on the repo via SessionStart.

  Membership is derived from an AUTHENTICATED server-side source — a story
  assignment (`stories.assigned_agent_id`) — never a client field; an `:agent`
  with no assigned story in the project is denied (default-deny). Elevated roles
  (`>= :user`) bypass the membership gate, mirroring the redact-path escape hatch
  (`authorized_to_delete?/3`): the threat model is specifically the `:agent` role
  ("one compromised agent key"), and an operator legitimately curates across
  projects. The check runs AFTER `Projects.get_project/2` and `agent_owned/2`, so
  a missing project or foreign-tenant agent still surface their own distinct
  errors first.

  ## Accepted risk — signed-off residual (AC-40.D3.4)

  AC-40.D3.4 requires that any residual hole left by choosing the story-assignment
  membership model (rather than a full, non-self-grantable membership relation) be
  a DELIBERATE, documented sign-off — never a silent no-op. Two residuals are
  accepted here, both consciously, both observable:

    1. **Membership is SELF-GRANTABLE via the claim path.** `assigned_agent_id` is
       set by `Progress.claim_story/3`, and claiming is self-service for the
       `:agent` role (`POST /stories/:id/contract` then `/claim`). So a compromised
       `:agent` key CAN, within its own tenant, contract + claim a pending story in
       a sibling project P2 to make itself a member of P2, then post into P2's
       channel — narrowing but not fully closing the tenant-wide injection vector
       this story targets. This is accepted because: (a) the claim is a
       state-mutating, AUDITED event (`Audit.log_in_multi`) that HIJACKS real work
       (a claimable/dependency-satisfied story must exist in P2), so the bootstrap
       is observable and disruptive, not silent; (b) the injection blast radius per
       post is already bounded by the 512-byte SessionStart preview (`@preview_bytes`);
       and (c) the FULL closure — binding a claim to a dispatch lineage so an agent
       may only claim work DISPATCHED to it — is Chain of Custody v2 (Epic 26,
       `docs/chain-of-custody-v2.md` L4; `dispatches.lineage_path`). That is out of
       scope for US-40.D3 and cannot be relied on yet: legacy env-var agent keys
       (with no dispatch) remain valid through the Epic 26 deprecation window, so a
       dispatch-only membership source would deny the still-supported legacy path.
       The compensating control named by decision 2 is per-project-scoped agent
       keys; dispatch-lineage-bound claiming is the durable fix. The "ACCEPTED RISK
       (AC-40.D3.4)" test in `coordination_test.exs` runs the real self-service
       contract + claim flow to keep this accepted behavior VISIBLE — it will break,
       DELIBERATELY, when Epic 26 binds the claim path to a dispatch lineage, forcing
       a conscious revisit rather than a silent regression.

    2. **Membership tracks the CURRENT assignment only**, so the surface is narrower
       than the pre-US-40.D3 tenant-wide bus: an agent posting BEFORE it claims a
       story, a distinct REVIEWER/verifier agent (`reviewer_agent_id` differs from
       `assigned_agent_id`), and an `:orchestrator`-role key carrying an agent
       identity (level 2, below the `:user` bypass) are all default-denied without a
       current assignment; and releasing the only story in a project
       (`unclaim_story`/`force_unclaim_story` null `assigned_agent_id`) revokes write
       access, so a "released, blocked on X" follow-up cannot be posted. (`report_story`
       does NOT null the assignment, so the normal reported_done/verify flow keeps
       write access.) These denials all collapse to the same oracle-safe 422, so they
       are unobservable to the caller — accepted under the default-deny decision-2
       model and flagged here as a heads-up for the US-40.B1 claim/release coupling.

  ## Coupling (US-40.B1 / US-40.E1)

  This predicate is SHARED: the claim writes (US-40.B1 claim/release/done) and the
  graduate write (US-40.E1) MUST gate through `project_writable_by_agent/4`. Note
  the deliberate non-circularity for the CLAIM gate: claiming a story is HOW an
  agent obtains assignment-membership, so gating the coordination-CLAIM write on
  membership does not gate the story-`claim_story` transition itself — 40.B1 must
  ensure it does not create a bootstrap where you need membership to claim the very
  work that would grant it.

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
  @spec post(Ecto.UUID.t(), Ecto.UUID.t(), atom(), map()) ::
          {:ok, ChannelPost.t(), :created | :updated}
          | {:error, :not_found}
          | {:error, :agent_not_found}
          | {:error, Ecto.Changeset.t()}
  def post(tenant_id, agent_id, role, attrs) do
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
    # US-40.D3: after the project and agent ownership guards, enforce project-
    # scoped WRITE membership. A non-member `:agent` (even in its own tenant) is
    # rejected with the SAME `{:error, :not_found}` the missing/cross-tenant
    # project returns, so the endpoint maps it to the byte-identical 422 with no
    # "not a member" vs "not your tenant" oracle. This runs LAST so a missing
    # project (:not_found) and a foreign-tenant agent (:agent_not_found) keep
    # their distinct, correctly-attributed errors.
    #
    # DELIBERATELY outside the `run_post/3` insert transaction — like the sibling
    # `Projects.get_project/2` and `agent_owned/2` guards above it. This is a
    # benign, accepted TOCTOU: a concurrent story unclaim/reassign between this
    # read and the insert can let a post commit on just-stale membership (or deny a
    # just-assigned agent). It is NOT a correctness or security defect — membership
    # WAS true at check time, so which side of the microsecond boundary the commit
    # lands on is semantically irrelevant (the same post one tick earlier is
    # unarguably authorized), and the worst case is a single stale-authorized or
    # stale-denied post, never a cross-tenant/cross-project escalation (the tenant
    # and project predicates are re-evaluated by the insert's own FKs/columns).
    # Folding the check into the transaction would not close the window (READ
    # COMMITTED still lets a concurrent unclaim commit between the two statements)
    # and would only add coupling — so it stays a pre-flight guard.
    with {:ok, _project} <- Projects.get_project(tenant_id, project_id),
         {:ok, _agent} <- agent_owned(tenant_id, agent_id),
         :ok <- project_writable_by_agent(tenant_id, agent_id, project_id, role) do
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
  Authorizes a project-scoped WRITE by an agent — the SHARED default-deny
  membership gate (US-40.D3).

  Returns `:ok` when the caller may write to the project's coordination surface,
  `{:error, :not_found}` otherwise. The `:not_found` shape is deliberate: callers
  fold it into the SAME byte-identical 422 a missing/cross-tenant project returns,
  so a cross-project write attempt reveals no "not a member" vs "not your tenant"
  vs "does not exist" oracle.

  Two ways to be authorized:

    1. **Membership** — the agent is assigned to at least one story in the project
       (`stories.assigned_agent_id`, scoped by an EXPLICIT `tenant_id` filter on
       the `AdminRepo`/BYPASSRLS path — the module's isolation convention). This is
       the AUTHENTICATED, server-side source: `agent_id` and `tenant_id` are both
       key-derived, never client-supplied. In the loopctl flow an implementer that
       claims/starts a story gets `assigned_agent_id` set, so a working agent IS a
       member of the project it works on. Default-DENY: no assignment ⇒ no write.

    2. **Elevated role** — a caller with `role >= :user` bypasses the membership
       check, mirroring the redact-path operator escape hatch
       (`authorized_to_delete?/3`). The threat model is the `:agent` role (one
       compromised agent key posting into every project channel); operators
       legitimately curate across projects. NOTE the deliberate choice: an
       `:orchestrator` (level 2, below `:user`) does NOT bypass and must be a
       member via story assignment — the gate is enforced for every role below
       `:user`.

  ## Coupling (keep SHARED)

  This is the single project-scoped-write predicate for the coordination surface.
  The CLAIM writes (US-40.B1 claim/release/done) and the graduate write
  (US-40.E1) MUST gate through this same function — a claim/graduate on a project
  the caller cannot post to is denied identically — rather than re-deriving
  membership. Do not inline a second copy.
  """
  @spec project_writable_by_agent(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          :ok | {:error, :not_found}
  def project_writable_by_agent(tenant_id, agent_id, project_id, role) do
    if Role.role_at_least?(role, :user) or
         agent_member_of_project?(tenant_id, agent_id, project_id) do
      :ok
    else
      {:error, :not_found}
    end
  end

  # Membership derivation (US-40.D3): the agent is assigned to at least one story
  # in the project. Runs on `AdminRepo` (BYPASSRLS) with an EXPLICIT `tenant_id`
  # filter — the module's isolation convention; omitting it would be a cross-tenant
  # bug. `exists?` compiles to `SELECT 1 ... LIMIT 1`, so it never materializes rows.
  # Source table: `stories` (`Loopctl.WorkBreakdown.Story`). The 3-predicate probe
  # is backed by the composite `stories_assigned_agent_project_idx` on
  # `(assigned_agent_id, project_id)` (migration 20260719120000) so it seeks
  # straight to the pair and stays flat even for an agent with many assignments,
  # rather than seeking on `assigned_agent_id` alone and heap-rechecking project.
  defp agent_member_of_project?(tenant_id, agent_id, project_id) do
    Story
    |> where(
      [s],
      s.tenant_id == ^tenant_id and s.project_id == ^project_id and
        s.assigned_agent_id == ^agent_id
    )
    |> AdminRepo.exists?()
  end

  @doc """
  HARD-deletes a channel post — the redact path (US-39.7).

  The backstop for a leaked/regretted post: the AUTHOR who notices their own
  leaked secret (the denylist is best-effort, US-39.1) can pull the row back
  immediately, before its 30-day TTL (US-39.5) would sweep it (an elevated
  operator can do so on the author's behalf — see below). A hard delete is
  consistent with the transient model — there is nothing to soft-retain in a
  channel that expires wholesale.

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
  private `fetch_owned_post/2` the redact path (`delete_post/5`) uses.

  ORACLE-SAFE, mirroring `delete_post/5`: the fetch filters on BOTH `id` and
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
  # by the redact path (`delete_post/5`) and the public by-id read (`get_post/2`).
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
    # it and `Multi.delete` the row can vanish. Under the author-only gate
    # (`authorized_to_delete?/3`, US-40.D2) two DIFFERENT agents can no longer both
    # delete the same post, so the legitimate races are: the author double-deleting
    # (two concurrent redact calls from the same session), the US-39.5 TTL sweep
    # reaping the row, or an elevated operator (`>= :user`) racing the author's own
    # pullback. Any of these makes a concurrent delete of the same post a first-class
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

      Delta reads are bounded by `:limit`. When the (since, now] window holds more
      matching rows than the limit, the OLDEST-touched matching rows are truncated
      (delta orders GREATEST(inserted_at, updated_at) DESC). `recent/3` discards the
      truncation signal — use `recent_page/3` (which returns `has_more`) plus the
      TRUNCATION-DRAIN RULE (see `@commit_lag_epsilon_seconds` and `recent_page/3`)
      to guarantee a burst larger than the cap is drained without a lost-write gap.
  """
  @spec recent(term(), term(), keyword()) :: [preview()]
  def recent(tenant_id, project_id, opts \\ []) do
    {posts, _has_more, _next_cursor} = recent_page(tenant_id, project_id, opts)
    posts
  end

  @doc """
  Like `recent/3` but also reports truncation and the keyset paging cursor
  (US-40.C2).

  Returns `{posts, has_more, next_cursor}`:

    * `has_more` — `true` iff at least one more live, matching post exists beyond
      the applied `:limit`. Detected by fetching `limit + 1` rows and checking for
      the overflow row (no extra COUNT query), so the endpoint surfaces an HONEST
      truncation signal rather than leaving consumers to infer it from
      `count == limit`. TRUNCATION-DRAIN RULE (delta mode): because delta orders
      GREATEST(inserted_at, updated_at) DESC, an overflowing window truncates the
      OLDEST-touched matching rows. A consumer MUST NOT advance its `since` watermark
      while `has_more` is true — the newest-first truncation means advancing steps
      PAST the dropped older rows permanently (a lost-write gap). Instead, drain the
      backlog via the HISTORY read (`cursor:` walked to exhaustion), which returns
      every live row including the truncated ones, then advance `since` only once a
      delta read returns `has_more == false`. (Delta mode emits no `next_cursor`, so
      the drain is the keyset/history read — not a delta continuation. See
      `@commit_lag_epsilon_seconds`.)
    * `next_cursor` — the `(inserted_at, seq)` keyset position of the LAST returned
      row when more history remains, else `nil`. This is a HISTORY-paging construct:
      it is returned only for the HISTORY read (no `:since` delta window). The
      caller re-issues `recent_page/3` with `cursor: next_cursor` to walk the next
      older page, until `next_cursor` is `nil` (exhausted). See AC-40.C2.4 for why a
      keyset cursor is NOT emitted in delta mode.

  ## Two distinct reads (AC-40.C2.4 — do NOT unify)

    * `:cursor` present → HISTORY read. Seeks `(inserted_at, seq) < cursor` and
      orders `inserted_at DESC, seq DESC` — a deterministic walk keyed on the
      monotonic `seq` bigserial (NEVER the random `id`; this is why US-40.C2
      supersedes US-40.5). Pages the full set of ALREADY-COMMITTED live rows without
      gaps or dups: for any row visible when a page is read, the strict `< cursor`
      seek reaches it on exactly one page. It does NOT (and by design need not)
      guarantee that a row which COMMITS mid-walk with `(inserted_at, seq)` ABOVE an
      already-emitted cursor is later returned by the backward walk — that row sits
      above the walk's descending frontier, so a subsequent older page never revisits
      it. This is the standard keyset property (a backward walk sees a consistent
      snapshot from its start point, not rows that appear newer-than-frontier after
      the fact), and it is deliberate here: NEW-row completeness near `now` is owned
      by the epsilon-protected DELTA read (`:since`), which look-back re-scans exactly
      that pre-commit-lag class of row. The two reads split the completeness
      contract — history walks committed history downward, delta catches new/late
      commits at the head. A cursor takes PRECEDENCE over `:since` (the two reads are
      never combined).
    * `:since` present (no cursor) → DELTA read. Applies a bounded commit-lag
      look-back (`effective_since = since - #{@commit_lag_epsilon_seconds}s`, see
      `@commit_lag_epsilon_seconds`) so a late-committing earlier row is re-scanned
      rather than lost (AT-LEAST-ONCE with a small deliberate overlap the CONSUMER
      dedups). Filters + orders on `GREATEST(inserted_at, updated_at)` so a
      re-touched slot ranks by its most-recent touch. Delta paging is the consumer
      advancing its `since` watermark, so `next_cursor` is `nil` here — with ONE
      completeness caveat when the window overflows `:limit`: see the TRUNCATION-DRAIN
      RULE below and on `has_more`.
    * neither → NEWEST page (exactly US-39.3), `inserted_at DESC, seq DESC`, plus a
      `next_cursor` when the page truncated (opt-in keyset paging over live history).

  `opts`:

    * `:cursor` — a `{inserted_at, seq}` keyset position (already decoded/verified
      by the caller, e.g. `ChannelCursor.decode/2`). A non-tuple / wrong-shape value
      is treated as absent.
    * `:limit`, `:since` — as `recent/3`.
  """
  @spec recent_page(term(), term(), keyword()) ::
          {[preview()], boolean(), ChannelCursor.position() | nil}
  def recent_page(tenant_id, project_id, opts \\ []) do
    if valid_uuid?(tenant_id) and valid_uuid?(project_id) do
      limit = opts |> Keyword.get(:limit, @default_recent_limit) |> clamp_limit()
      cursor = opts |> Keyword.get(:cursor) |> normalize_cursor()

      # A cursor (history paging) takes precedence over `since` (delta window): the
      # two reads are distinct (AC-40.C2.4) and never unified. When a cursor is
      # present, ignore `since`.
      since = if cursor, do: nil, else: opts |> Keyword.get(:since) |> normalize_since()
      now = DateTime.utc_now()

      rows =
        ChannelPost
        |> where([p], p.tenant_id == ^tenant_id and p.project_id == ^project_id)
        |> where([p], p.expires_at > ^now)
        |> apply_since(commit_lag_since(since))
        |> apply_cursor(cursor)
        |> order_recent(since)
        |> select_preview()
        |> limit(^(limit + 1))
        |> AdminRepo.all()

      has_more = length(rows) > limit
      kept = Enum.take(rows, limit)
      page = Enum.map(kept, &finalize_preview/1)
      {page, has_more, next_cursor(kept, has_more, since)}
    else
      {[], false, nil}
    end
  end

  @typedoc """
  A single LIST-read row: a bounded read-model projection (NOT a `%ChannelPost{}`).
  Carries `body_preview` (a prefix of at most `#{@preview_bytes}` bytes) + `truncated`
  instead of the full `body`, plus the attribution/addressing/timestamp fields.
  """
  @type preview :: %{
          id: Ecto.UUID.t(),
          seq: integer(),
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
      # `seq` (bigserial) is projected so the LIST read's keyset next_cursor
      # (US-40.C2) is the last row's `(inserted_at, seq)` without a second fetch.
      # It is never exposed to clients: the controller's `channel_post_json/1` picks
      # explicit fields and does NOT put `seq` in the JSON body, AND — because `seq`
      # is a GLOBAL cross-tenant counter — it rides inside the cursor only in
      # AES-256-GCM ENCRYPTED form (see `Loopctl.KeysetCursor`). The HMAC alone would
      # keep the cursor unforgeable but NOT unreadable, so signing is not enough to
      # keep a global counter server-side; the payload encryption is what does.
      seq: p.seq,
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

  # Commit-lag look-back (AC-40.C2.2): widen the delta window backwards by the
  # bounded epsilon so a row whose earlier `inserted_at`/lower `seq` COMMITTED after
  # the reader's watermark is RE-SCANNED, not silently skipped. At-least-once with a
  # small deliberate overlap; the consumer dedups (see `@commit_lag_epsilon_seconds`).
  # `nil` (history/newest read, no delta) is unchanged.
  defp commit_lag_since(nil), do: nil

  defp commit_lag_since(%DateTime{} = since),
    do: DateTime.add(since, -@commit_lag_epsilon_seconds, :second)

  # History keyset seek (AC-40.C2.1): step to rows strictly OLDER than the cursor by
  # `(inserted_at, seq)`, tie-broken on the monotonic `seq` bigserial. Delegates to
  # the shared `KeysetSeek.before_position/2` (the load-bearing `type/2` annotations
  # live there). `nil` (no cursor) is the newest page.
  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {%DateTime{}, seq} = cursor) when is_integer(seq),
    do: KeysetSeek.before_position(query, cursor)

  # Validate the caller-supplied `:cursor` opt to the `{DateTime, integer_seq}`
  # keyset shape; anything else (nil, a bare timestamp, a UUID tuple, garbage) is
  # treated as absent — a bad cursor degrades to the newest page, never a crash.
  defp normalize_cursor({%DateTime{}, seq} = cursor) when is_integer(seq), do: cursor
  defp normalize_cursor(_), do: nil

  # The keyset `next_cursor` is a HISTORY-paging construct (AC-40.C2.4): the
  # `(inserted_at, seq)` of the last returned row, emitted ONLY for the history read
  # (no `:since` delta window) when more rows remain. In DELTA mode the read is a
  # watermark window ordered by GREATEST(inserted_at, updated_at) — a re-touched slot
  # ranks by its `updated_at` while the keyset walks `inserted_at`, so a keyset
  # cursor there would be incoherent; delta paging is the consumer advancing `since`,
  # so we return `nil`. Also `nil` when history is exhausted (`has_more == false`).
  defp next_cursor(_kept, false, _since), do: nil
  defp next_cursor(_kept, true, %DateTime{}), do: nil
  # `limit: 0` (or negative) returns no rows even though more exist — there is no
  # last row to anchor a cursor on, so there is nothing to page from.
  defp next_cursor([], true, nil), do: nil

  defp next_cursor(kept, true, nil) do
    last = List.last(kept)
    {last.inserted_at, last.seq}
  end

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
