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

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Agents
  alias Loopctl.Audit
  alias Loopctl.Auth.Role
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Coordination.ChannelCursor
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.KeysetSeek
  alias Loopctl.Knowledge
  alias Loopctl.Projects
  alias Loopctl.Projects.Project
  alias Loopctl.Security.SecretDenylist
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story

  # Uniform retention for every post — one authoritative constant in code, not a
  # DB default (owner decision; the fleet audit showed the category taxonomy and
  # per-type retentions were unused).
  @retention_days 30

  # Issue #499: the 422 a KEYLESS idempotent re-write gets when the row holding its
  # token has been QUARANTINED. Names the remedy explicitly — the caller must not
  # believe a hidden post is live, and it cannot be silently released (its stored
  # content is what the denylist flagged).
  @quarantined_idempotency_message "a previous post with this idempotency_key was quarantined for carrying a credential shape and is no longer readable; remove the credential and retry with a NEW idempotency_key"

  # Issue #499: the 422 for the post-write invariant in `secret_guard_step/1` — the
  # write merged cleanly but the PERSISTED row still carries a credential in a field
  # the keyed upsert preserves (`host`, or an omitted `to_host`/`to_capability`).
  # The remedy names REDACTION only, deliberately: `release_post/5` clears the quarantine
  # bookkeeping but cannot change the dirty PRESERVED field, and `secret_guard_step/1` has
  # no notion of an exonerated row — so after a release this slot would 422 on every
  # subsequent write, permanently, while the genuinely dirty post is republished. The only
  # remedies that actually free the slot are `delete_post/5` and a new session_id.
  @persisted_secret_message "this keyed slot still carries a credential shape in a field a re-post cannot overwrite (host or advisory addressing); the write was rolled back — have an operator redact (delete) the post, or retry under a new session_id. Releasing the post does NOT free the slot: release cannot clear the offending field"

  # Issue #499: bound on one page of the operator quarantine review read.
  @quarantined_default_limit 25
  @quarantined_max_limit 100

  # US-40.B1 claim lifecycle windows.
  #   * @default_lease_seconds — a claim's default lease (how long the claimant may
  #     hold the ref before an abandoned-lease sweep may reopen it). Overridable per
  #     claim via the `:lease_seconds` opt, clamped to [1, @max_lease_seconds].
  #   * @claim_done_retention_days — how long a DONE claim is retained before the
  #     lifecycle-aware sweep reaps it (an audit/idempotency breadcrumb window). The
  #     sweeper (`Loopctl.Workers.ChannelClaimSweeper`) reads this as its single
  #     source of truth so the code and the sweep predicate never drift.
  @default_lease_seconds 3600
  @max_lease_seconds 86_400
  @claim_done_retention_days 7

  # US-40.4 ADVISORY FILE SOFT-LOCKS — deliberately NOT the exactly-once handoff
  # claim above. A soft-lock is a HINT ("I'm editing lib/foo.ex") surfaced on the
  # channel; it NEVER blocks anyone and TWO sessions may hold one on the same file
  # (AC-40.4.4). It is built entirely on `channel_posts` (no new table): a keyed
  # post under the `claim:<target>` key convention with a SHORT, caller-influenced,
  # SERVER-CLAMPED TTL.
  #
  # NAMING (load-bearing): `claim/5`, `release/5` and `done/5` are the exactly-once
  # HANDOFF claim (US-40.B1, `channel_claims`). The soft-lock is `lock_file/5` /
  # `unlock_file/5` / `active_locks/3` precisely so the two primitives can never be
  # conflated — the key PREFIX is the only thing they share, and only because the
  # story fixed that convention before the handoff claim existed as a table.
  @lock_key_prefix "claim:"

  # The SQL `LIKE` pattern for the lock namespace. It MUST stay a compile-time
  # LITERAL in every query (review #451): Postgres only matches a partial index when
  # it can PROVE the query predicate implies the index predicate, and that proof is
  # Const-based — it cannot reason about a bind parameter. Written as `^(prefix <>
  # "%")` the predicate renders `key LIKE $n` and
  # `channel_posts_soft_lock_idx` (predicate `key LIKE 'claim:%'`) is never chosen,
  # so the index ships dead and every lock read falls back to scan-and-filter. The
  # US-40.C1 handoff read gets this right with a literal; so must this one.
  @lock_key_like "claim:%"

  # Compile-time tie: the literal above can never drift from the prefix.
  if @lock_key_like != @lock_key_prefix <> "%" do
    raise "@lock_key_like must be @lock_key_prefix <> \"%\""
  end

  # The 422 a caller gets for posting into the RESERVED soft-lock key namespace via
  # the generic write path. Names the remedy explicitly: the lock endpoint owns the
  # prefix, and an ordinary keyed slot must pick a different name.
  @reserved_key_prefix_message "key prefix \"#{@lock_key_prefix}\" is reserved for advisory file soft-locks; use POST /api/v1/channel/locks (channel_lock) to take one, or choose a different key for an ordinary post"

  # The soft-lock TTL clamp (AC-40.4.1). This is the ONE place `expires_at` is
  # caller-influenced — every other post is fixed at `now + @retention_days` — so
  # the bounds are a STATED INVARIANT, not a soft default:
  #
  #   * floor 60s — below a minute the lock expires before a peer's next channel
  #     read and buys nothing;
  #   * ceiling 3600s (60 min) — a soft-lock must NEVER outlive the editing session
  #     that took it. A crashed/killed session's lock self-expires within the hour
  #     via `expires_at` (reads filter it out IMMEDIATELY; `ChannelPostSweeper`
  #     reaps the row), so no dead session can sit on a file indefinitely.
  #
  # The override applies ONLY on the INTERNAL soft-lock write path — `lock_file/5`
  # stamps a private marker (`@soft_lock_ttl_attr`) into the attrs map, and
  # `resolve_expires_at/1` routes on THAT, never on the caller-chosen `key`. A
  # request body therefore cannot reach the short TTL at all: an ordinary post can
  # neither shorten (evade the audit/read window) nor lengthen channel retention.
  # (Review #451: routing on the `claim:` key prefix silently cut ANY caller-keyed
  # post named `claim:...` from 30 days to 900s — the invariant above was false.)
  @min_lock_ttl_seconds 60
  @max_lock_ttl_seconds 3600
  @default_lock_ttl_seconds 900

  # The PRIVATE attrs marker that makes a write a soft-lock. Never cast, never
  # derived from a request body — `lock_file/5` is the only writer, and `post/4`
  # REJECTS a caller-supplied `claim:`-prefixed key that lacks it (the prefix is a
  # reserved namespace, so `key LIKE 'claim:%'` remains a sound lock predicate for
  # every read).
  @soft_lock_ttl_attr :__soft_lock_ttl_seconds__

  # The audit action a soft-lock RELEASE is recorded under (review #451). Deliberately
  # NOT the `deleted` action `delete_post/5` uses: that one is the US-39.7 secret
  # REDACTION path an operator watches (and whose audit failure deliberately rolls the
  # DELETE back so a leaked credential is never falsely reported gone). Routine lock
  # churn — roughly one release per file edit per session — must not land in the same
  # bucket and dilute that signal.
  @soft_lock_release_action "soft_lock_released"

  # Hard safety cap on ONE page of the pinned active-lock read. Locks are short-lived
  # (<= @max_lock_ttl_seconds) so the live set is small by construction; this bounds
  # the pathological case (a runaway locker) without truncating a normal repo's set.
  @default_active_locks_limit 100
  @max_active_locks_limit 200

  # Page bounds on the CLAIM read (#707). A claim is one row per outstanding unit of
  # work on a channel, so a healthy repo's live set is a handful; these bound the
  # pathological case without truncating any real one. Mirrors the lock bounds above
  # rather than inventing a second convention. Unlike locks, the fairness axis that
  # matters is NOT the holder (a fleet's sessions share one agent_id, so a per-agent
  # partition would never bind) but the LIFECYCLE: `claims_page/3` orders OPEN rows
  # ahead of terminal ones so retained DONE rows cannot evict a live claim.
  @default_claims_limit 100
  @max_claims_limit 200

  # FAIRNESS bound on the pinned active-lock read (review #451). The page cap above
  # truncates NEWEST-first, so without this one noisy holder — the lock write cap is
  # 120/min against a 900s TTL — could fill every slot and evict every peer's lock
  # from the very read that exists to surface peers. A single AGENT therefore
  # contributes at most this many rows to a page; the rest of the page stays
  # available to other agents. Well above any sane working set (an agent editing >20
  # files at once is not doing collision avoidance any more).
  #
  # The partition is `agent_id` ALONE — deliberately NOT `(agent_id, session_id)`.
  # `session_id` is CALLER-SUPPLIED (see the `unlock_file/5` trust note), so a caller
  # that sends a fresh session_id per write lands every row in its own partition of
  # size 1 and the bound never binds — the adversary this cap exists to stop would
  # bypass it by construction. `agent_id` is SERVER-STAMPED from the verified key, so
  # partitioning on it makes the published guarantee actually hold. Cost: an agent
  # legitimately running several concurrent sessions shares one budget — acceptable,
  # since the budget is per PAGE of an advisory hint read and the complete set is
  # reachable via a larger `:limit` and the `holders_truncated` signal.
  @max_locks_per_holder 20

  # Bounded SHARE of one `recent_page/3` page that advisory locks may occupy (review
  # #451). Locks ride the ordinary post path so AC-40.4.2's `channel_recent` surfacing
  # holds, but they are the highest-churn write on the bus (refreshed while editing,
  # and each refresh bumps `updated_at`, which RE-FLOATS them in the `since` delta
  # ordering). Without a cap a handful of refreshing sessions would crowd genuine
  # coordination posts and handoffs out of the 25-row window. Only the NEWEST few
  # locks are admitted to a page; the complete live set is the dedicated pinned read
  # (`active_locks_page/3` / `GET /api/v1/channel/locks`).
  @max_recent_locks 5

  # Read-bound convention (US-39.3): the `channel_recent` endpoint defaults to 25
  # rows and CLAMPS a larger `?limit=` to 100 (not a 400) — see AC-39.3.3. These
  # are the single source of truth for both the context primitive and the HTTP
  # endpoint's `meta.limit`.
  @default_recent_limit 25
  @max_recent_limit 100

  # Pinned directed-handoff safety cap (US-40.C1). `directed_handoffs/3` is a PINNED
  # set — it must NOT be truncated by the newest-N recency cutoff (AC-40.C1.2), so it
  # does not take a caller `limit`. But an unbounded read is still a liability: broadcast
  # handoffs are default-include for EVERY caller, posts live 30d, and each preview is
  # injected into peer agent sessions via the SessionStart hook — so on a busy channel
  # the row COUNT (not just each 512-byte body) could grow without bound. This is a
  # large HARD safety cap on worst-case response/memory size, NOT recency truncation:
  # the read is ordered OLDEST-first, so the cap retains the most at-risk aging handoffs
  # and only ever drops the newest overflow — the opposite of the forbidden newest-N cut.
  # Deliberately far above any sane directed-handoff backlog; hitting it signals a
  # pathological channel, not normal operation. When it IS hit the truncation is NOT
  # silent: `directed_handoffs_page/3` returns an `overflowed?` flag (surfaced as HTTP
  # `meta.overflow`) so the caller knows the oldest directed handoffs were dropped and
  # can read the channel directly instead of trusting a truncated pinned set.
  @max_directed_handoffs 500

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

  @typedoc """
  One tenant's retention RESIDUE: expired `channel_posts` rows the US-39.5 sweep has
  not removed. `overdue_count`/`oldest_expires_at` are computed over the BOUNDED scan
  (see `system_retention_stall_candidates/2`).
  """
  @type retention_residue :: %{
          tenant_id: binary(),
          overdue_count: non_neg_integer(),
          oldest_expires_at: DateTime.t() | NaiveDateTime.t()
        }

  @doc false
  # SYSTEM/maintenance read — NOT a tenant-scoped context function.
  #
  # Deliberately `@doc false` and `system_`-prefixed: unlike every other function in this
  # module it takes NO `tenant_id` and reads across ALL tenants on `AdminRepo`
  # (BYPASSRLS). It exists solely for the install-wide `:sweep_stalled` dead-man's-switch
  # (`Loopctl.Knowledge.IngestionHealth.detect_sweep_stalled/1`), which has no tenant to
  # scope to — the thing it watches (`ChannelPostSweeper`) is a single global worker.
  # NEVER call it from a controller or any tenant-facing path; a tenant-facing residue
  # read must be written as a normal `tenant_id`-first function on `Loopctl.Repo`.
  #
  # Cross-tenant retention RESIDUE for the US-39.5 channel-post sweep (#498): per ACTIVE
  # tenant, how many `channel_posts` rows are still present with `expires_at < cutoff`,
  # and how old the oldest of them is.
  #
  # This lives in `Loopctl.Coordination` — the context that OWNS `channel_posts` — rather
  # than in the detector that consumes it (`Loopctl.Knowledge.IngestionHealth`), so the
  # knowledge context never builds a query directly on a coordination schema. The
  # detector interprets these rows (grace window, drain-capacity, anomaly persistence);
  # this function only reports what is on the table.
  #
  # ## Bounded scan (AdminRepo pool safety)
  #
  # The residue set only EXISTS, and only GROWS, while the sweep is not keeping up — so an
  # unbounded `count(*)` over it would be cheap exactly when it does not matter and
  # unbounded exactly when it does, on the 3-connection `AdminRepo` pool shared with
  # custody/admin writes. The scan is therefore capped at `scan_limit` rows via a
  # LIMITed subquery, and the return value reports whether the cap was HIT
  # (`truncated?: true` ⇒ "at least `scan_limit` overdue rows exist"), so a caller can
  # reason about a saturated backlog without ever paying for a full count.
  #
  # The LIMIT is install-wide and oldest-first, so under truncation a tenant's
  # `overdue_count` is a LOWER BOUND on its residue and a tenant whose residue is newer
  # than the cutoff sample may be ABSENT from `rows` entirely. `truncated?` is returned
  # precisely so the consumer never reads absence-under-truncation as "this tenant has no
  # residue" (see `IngestionHealth.auto_resolve_recovered_sweep_stalled/1`).
  #
  # Returns `%{rows: [retention_residue()], scanned: n, truncated?: bool}`.
  @spec system_retention_stall_candidates(DateTime.t(), pos_integer()) :: %{
          rows: [retention_residue()],
          scanned: non_neg_integer(),
          truncated?: boolean()
        }
  def system_retention_stall_candidates(%DateTime{} = cutoff, scan_limit)
      when is_integer(scan_limit) and scan_limit > 0 do
    overdue =
      ChannelPost
      |> join(:inner, [p], t in Tenant, on: t.id == p.tenant_id and t.status == :active)
      |> where([p], p.expires_at < ^cutoff)
      # OLDEST FIRST is load-bearing, not cosmetic: under truncation the sample must
      # still contain the genuinely oldest rows, or `min(expires_at)` would UNDER-report
      # staleness and the consumer's hard-ceiling backstop could never fire on a big
      # backlog. The `(expires_at)` index the sweep itself uses makes this ordered read
      # index-driven rather than a sort.
      |> order_by([p], asc: p.expires_at)
      |> select([p], %{tenant_id: p.tenant_id, expires_at: p.expires_at})
      |> limit(^scan_limit)

    rows =
      from(o in subquery(overdue),
        group_by: o.tenant_id,
        select: %{
          tenant_id: o.tenant_id,
          overdue_count: count(o.tenant_id),
          oldest_expires_at: min(o.expires_at)
        }
      )
      |> AdminRepo.all()

    scanned = Enum.reduce(rows, 0, &(&1.overdue_count + &2))

    %{rows: rows, scanned: scanned, truncated?: scanned >= scan_limit}
  end

  @doc """
  The hard safety cap on the pinned `directed_handoffs/3` set (US-40.C1). NOT a
  recency truncation — the read is ordered oldest-first, so the cap only drops the
  newest overflow on a pathological channel. Exposed as a single source of truth
  for tests.
  """
  @spec max_directed_handoffs() :: pos_integer()
  def max_directed_handoffs, do: @max_directed_handoffs

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
  caller learns the content did not land), `{:error, :not_found}` when the
  project or agent does not belong to the tenant, or
  `{:error, :unprocessable_entity, message}` when `key` is in the RESERVED
  `#{@lock_key_prefix}` soft-lock namespace. That last check is the SAME
  `reserved_key_prefix_check/1` `post/4` runs (review #451): the namespace guarantee
  every lock read depends on must be enforced by every writer, not by one call site.
  """
  @spec create_post(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, ChannelPost.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found}
          | {:error, :unprocessable_entity, String.t()}
  def create_post(tenant_id, project_id, agent_id, attrs) do
    with :ok <- reserved_key_prefix_check(attrs),
         {:ok, _project} <- Projects.get_project(tenant_id, project_id),
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
  a DELIBERATE, documented sign-off — never a silent no-op. Three residuals are
  accepted here, all consciously:

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

    3. **A `:kb`-kind scope is tenant-wide-writable by ANY agent (issue #517).**
       `project_writable_by_agent/4` grants the write when the target is a
       `:kb`-kind project in the caller's own tenant, WITHOUT a per-project
       membership check (see path 3 in that function's moduledoc). So in a
       multi-agent tenant an `:agent` compromised on repo-C can post into a
       kb-scope channel that auto-injects (via the SessionStart preview) into a
       peer agent's session working that kb-scope — the intra-tenant, cross-scope
       injection surface US-40.D3's membership gate closes for WORK projects. This
       is a DELIBERATE accepted residual, not an oversight: (a) a kb-scope carries
       NO chain-of-custody surface (`RequireWorkProject` bars work attachment, so
       it can never hold a story), so nothing custody-critical is exposed; (b) the
       blast radius is bounded to a single tenant (the `tenant_id` predicate in
       `kb_scope?/2` blocks cross-tenant reach) and, per post, to the 512-byte
       SessionStart preview (`@preview_bytes`); and (c) it mirrors the #331/#505
       trust unit that already made `create_kb_scope` and all agent-role KB
       curation tenant-wide — a kb-scope is a shared, agent-native knowledge
       partition whose whole point is any-agent collaboration, so gating its
       channel by story membership (structurally unsatisfiable — see (a)) would
       leave an agent-rooted KB-tier tenant with NO writable coordination bus at
       all. The compensating control is the same as decision 1's: per-project /
       per-dispatch agent keys under Chain of Custody v2. Registered here so the
       tenant-wide kb-channel writability is a signed-off decision, not a silent
       reopening of the D3 injection vector for `:kb` scopes.

       Custody-safety is NOT injection-safety, so the injection dimension is called
       out explicitly (review): the 512-byte SessionStart preview is same-tenant,
       agent-controlled text auto-injected into a peer agent's context, i.e. a genuine
       intra-tenant prompt-injection surface (OWASP ASI06 memory-poisoning / ASI01
       goal-hijack) — a repo-C-compromised agent can attempt to steer a peer working
       the kb-scope. What keeps this an ACCEPTED residual rather than an active exploit
       is that the SessionStart preview CONSUMER treats channel content as untrusted
       DATA, never instructions: it renders the preview as inert framed text (no shell
       interpolation, control chars stripped) and does not execute or obey it. The
       accepted risk is therefore bounded to whatever a peer MODEL might be socially
       engineered into by 512 bytes of adversarial prose — the same intra-tenant risk
       any shared agent-native surface carries — mitigated by per-dispatch keys under
       Chain of Custody v2 and by the `:kb_scope_write` telemetry marker (see
       `emit_kb_scope_write/3`) that makes member-bypass writes independently alertable.
       Emitting the marker on this path is deliberate: it is the one path where
       membership is bypassed, so cross-scope kb writes must be observable separately
       from membership-backed writes.

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

  ## Keyless idempotency (US-40.B2)

  On the KEYLESS path (no `key`), an OPTIONAL client `idempotency_key` makes a
  retried/offline-reconciled append retry-safe: a repeat write with the same
  `(tenant_id, project_id, agent_id, idempotency_key)` returns the EXISTING post
  (`{:ok, post, :deduplicated}`, HTTP 200 `created: false`) rather than appending a
  duplicate — the same guarantee `knowledge_create` gives. It is enforced by the
  partial unique index `channel_posts_idempotency_uidx` (scoped
  `WHERE idempotency_key IS NOT NULL AND key IS NULL`, so a KEYED post never
  participates) and caught with insert-and-recover (no TOCTOU). The token is a
  SEPARATE dedup dimension from the keyed slot and is consulted ONLY on the keyless
  path; a request carrying BOTH a `key` and an `idempotency_key` is rejected (422)
  as nonsensical. Absent, the write is exactly today's append-only behavior. One
  agent's token never collides with another's (scoped per `(tenant, project,
  agent)`).

  ## Returns

    * `{:ok, %ChannelPost{}, :created}` — a new row was inserted (HTTP 201)
    * `{:ok, %ChannelPost{}, :updated}` — an existing session slot was upserted
      in place (HTTP 200)
    * `{:ok, %ChannelPost{}, :deduplicated}` — a KEYLESS write carried a client
      `idempotency_key` that already exists for this
      `(tenant, project, agent)`; the EXISTING post is returned and nothing new
      was appended (HTTP 200, `created: false`) — US-40.B2
    * `{:error, :not_found}` — the project is missing or belongs to another
      tenant (endpoint → shared 422)
    * `{:error, :agent_not_found}` — the server-stamped `agent_id` does not belong
      to `tenant_id` (a misconfigured key; endpoint → 403, attributed as an
      identity fault, NOT a cross-tenant project probe)
    * `{:error, %Ecto.Changeset{}}` — a size/shape bound, denylist hit, or NUL
      byte was rejected; nothing was persisted (endpoint → 422)
  """
  @spec post(Ecto.UUID.t(), Ecto.UUID.t(), atom(), map()) ::
          {:ok, ChannelPost.t(), :created | :updated | :deduplicated}
          | {:error, :not_found}
          | {:error, :supersede_target_not_found}
          | {:error, :agent_not_found}
          | {:error, :conflict}
          # Issue #499 quarantine outcomes (message-carrying 422s): the idempotency
          # token belongs to a QUARANTINED row, or the persisted row still carries a
          # credential in a field the keyed upsert cannot overwrite.
          | {:error, :unprocessable_entity, String.t()}
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
    with :ok <- reserved_key_prefix_check(attrs),
         {:ok, _project} <- Projects.get_project(tenant_id, project_id),
         {:ok, _agent} <- agent_owned(tenant_id, agent_id),
         :ok <- project_writable_by_agent(tenant_id, agent_id, project_id, role),
         {:ok, supersedes} <-
           fetch_supersede_target(
             tenant_id,
             project_id,
             Map.get(attrs, :supersedes),
             agent_id,
             role
           ) do
      # US-454 (defect 1): rescue handoffs that would otherwise land keyless and
      # silently undiscoverable, and keep the keyed path available when the MCP
      # proxy supplied no session_id (the 422 "session_id can't be blank" that
      # forced the degraded keyless fallback in the incident behind issue #454).
      attrs =
        attrs
        |> maybe_derive_handoff_key()
        |> maybe_surrogate_session()

      changeset =
        %ChannelPost{
          tenant_id: tenant_id,
          project_id: project_id,
          agent_id: agent_id,
          # US-40.4: fixed at `now + @retention_days` for EVERY post except an
          # advisory soft-lock — identified by the PRIVATE `@soft_lock_ttl_attr`
          # marker that only `lock_file/5` stamps, never by the caller-chosen key —
          # whose TTL is caller-influenced and server-clamped.
          # `expires_at` is set on the STRUCT and never cast from
          # attrs, so no request body can reach it directly; and because the keyed
          # upsert FULL-REPLACES `expires_at` with `EXCLUDED.expires_at`, a
          # re-lock from the same slot refreshes the short TTL automatically.
          expires_at: resolve_expires_at(attrs)
        }
        |> ChannelPost.create_changeset(attrs)
        |> put_provenance_changes(attrs)

      run_post(tenant_id, changeset, audit, supersedes)
    end
  end

  # US-454 (defect 1), issue fix 1: a KEYLESS post whose body ANNOUNCES a
  # `handoff:<anchor>` gets the anchor DERIVED as its key server-side, rather
  # than landing with key NULL — invisible to `directed_handoffs/3` (which
  # filters `key LIKE 'handoff:%'`) and unclaimable (claim ref == key). The
  # /handoff convention is client-side, but a client without a session (no
  # CLAUDE_SESSION_ID) could not use the keyed path at all before this fallback;
  # deriving makes the only post it COULD produce discoverable.
  #
  # Two announcement shapes are recognized — both from the incident behind
  # issue #454, whose fix text names them explicitly:
  #   * the anchor at the very start of the body (`handoff:repo#812 — …`), and
  #   * the canonical prose form `HANDOFF (handoff:<anchor>) …` (what a sender
  #     writes when it has no keyed path). The HANDOFF-prose prefix is bounded
  #     (<= 80 chars before the anchor) so a deliberate announcement matches
  #     while a passing mid-body mention ("discussing handoff:x") NEVER gets
  #     promoted to a keyed handoff (and can never upsert-clobber a real one
  #     from the same session).
  #
  # A HANDOFF-announcing body carrying a client idempotency token derives the
  # key ANYWAY and therefore 422s LOUDLY via the key/token exclusion (issue
  # fix 2: "a loud 422 beats a silent drop") — the client must pick: an
  # explicit key (keyed slot dedups the retry) or a token (keyless, and the
  # handoff stays undiscoverable BY ITS OWN CHOICE, told so by the error).
  # Capped so the derived key can never exceed the column bound:
  #   "handoff:" (8) + 1 required + {0,191} = at most 200 bytes.
  @handoff_anchor_regex ~r/\A\s*(?:HANDOFF\b[\s\S]{0,80}?)?(handoff:[A-Za-z0-9][A-Za-z0-9_.\-\/#:]{0,191})/

  defp maybe_derive_handoff_key(attrs) do
    key = Map.get(attrs, :key)
    body = Map.get(attrs, :body)

    if present_string?(key) or not is_binary(body) do
      attrs
    else
      case Regex.run(@handoff_anchor_regex, body) do
        [_full, anchor] ->
          attrs |> Map.put(:key, anchor) |> Map.put(:key_source, "derived_from_body")

        _no_anchor ->
          attrs
      end
    end
  end

  # US-454 (defect 1), issue fix 1: a keyed post with NO session_id (the MCP
  # proxy had no CLAUDE_SESSION_ID to auto-fill) no longer 422s — the server
  # mints a UNIQUE surrogate session id, so the slot insert succeeds and the
  # handoff is discoverable/claimable. The surrogate is unique per write, so
  # same-"session" retries do NOT upsert (there is no session identity to dedupe
  # against) — duplicate pointers are collapsed at read time by DISTINCT ON
  # (key), and the CLAIM remains the cross-session exactly-once backstop. The
  # `session_id_source` marker lets the endpoint tell the sender its post was
  # rescued (issue fix 3: surface the degraded state at post time).
  defp maybe_surrogate_session(attrs) do
    if present_string?(Map.get(attrs, :key)) and not present_string?(Map.get(attrs, :session_id)) do
      attrs
      |> Map.put(:session_id, "srvgen-" <> Ecto.UUID.generate())
      |> Map.put(:session_id_source, "server_surrogate")
    else
      attrs
    end
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  # Carry the write-path provenance markers onto the returned struct (virtual
  # fields — never persisted) so the endpoint can surface them in the response.
  defp put_provenance_changes(changeset, attrs) do
    changeset
    |> Ecto.Changeset.put_change(:key_source, Map.get(attrs, :key_source))
    |> Ecto.Changeset.put_change(:session_id_source, Map.get(attrs, :session_id_source))
  end

  # US-454 (defect 3): resolve the OPTIONAL `supersedes` target for a post. The
  # target must live in the SAME tenant+project channel, and the caller must be
  # its AUTHOR or hold role >= :user (mirrors `authorized_to_delete?/3` — the
  # same "who may retire a post" boundary). Any miss — nonexistent, cross-
  # project, not-yours, or malformed — collapses to `{:error,
  # :supersede_target_not_found}` so the endpoint maps it to a 422 WITHOUT
  # the :ownership_rejected security signal (preserving honest attribution).
  defp fetch_supersede_target(_tenant_id, _project_id, nil, _agent_id, _role), do: {:ok, nil}

  defp fetch_supersede_target(tenant_id, project_id, target_id, agent_id, role)
       when is_binary(target_id) do
    target =
      ChannelPost
      |> where(
        [p],
        p.tenant_id == ^tenant_id and p.project_id == ^project_id and p.id == ^target_id
      )
      |> AdminRepo.one()

    case target do
      %ChannelPost{} = post ->
        if post.agent_id == agent_id or Role.role_at_least?(role, :user) do
          {:ok, post}
        else
          {:error, :supersede_target_not_found}
        end

      nil ->
        {:error, :supersede_target_not_found}
    end
  rescue
    # A malformed (non-UUID) target id is the same "not found" — no shape oracle.
    Ecto.Query.CastError -> {:error, :supersede_target_not_found}
  end

  # Catch-all for non-binary supersedes values (integer, array, object) — prevents
  # a FunctionClauseError → 500 on malformed JSON input.
  defp fetch_supersede_target(_tenant_id, _project_id, _target_id, _agent_id, _role),
    do: {:error, :supersede_target_not_found}

  @doc """
  Authorizes a project-scoped WRITE by an agent — the SHARED default-deny
  membership gate (US-40.D3).

  Returns `:ok` when the caller may write to the project's coordination surface,
  `{:error, :not_found}` otherwise. The `:not_found` shape is deliberate: callers
  fold it into the SAME byte-identical 422 a missing/cross-tenant project returns,
  so a cross-project write attempt reveals no "not a member" vs "not your tenant"
  vs "does not exist" oracle.

  Three ways to be authorized:

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

    3. **`:kb`-kind scope in the caller's own tenant** (issue #517) — a KB scope
       carries NO chain-of-custody surface: `RequireWorkProject` bars work
       attachment, so a kb-scope can NEVER have a story, and membership-by-story
       (path 1) is therefore structurally unsatisfiable for it. Without this path an
       agent-rooted (KB-tier) tenant — which can create a kb-scope via
       `create_kb_scope` (#331/#505) but not a work project — had NO channel it
       could both create AND post to, making the coordination bus (its intended
       handoff home) unreachable for a new repo. The membership gate exists to
       isolate CUSTODY-sensitive work-project channels; a kb-scope is a shared,
       agent-native knowledge partition with no custody weight, so any agent in the
       OWNING tenant may write its channel. The authorization is TENANT-WIDE, not
       creator-scoped: there is no per-scope creator/ownership tracking, so an agent
       may write ANY `:kb`-kind scope in its own tenant, NOT merely one it created via
       `create_kb_scope`. This is the deliberate, signed-off breadth (the tests at
       coordination_test.exs cover a brand-new agent with NO story assignment writing
       a kb-scope it did not create) — a kb-scope's whole point is any-agent
       collaboration, and an agent can already `knowledge_create` tenant-wide directly,
       so this opens no boundary the tenant trust unit did not already grant. This is
       NOT a cross-tenant hole:
       `kb_scope?/2` re-applies the `tenant_id` predicate (as does the `post/4`
       `get_project/2` guard upstream), so a kb-scope in ANOTHER tenant never
       reaches here — it is already `:not_found`. Consistent with the #331/#505
       carve-out that made `create_kb_scope` itself agent-role.

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
    # Clause order is a hot-path optimization, NOT a semantic one: kb_scope? and
    # agent_member_of_project? are mutually exclusive (a kb-scope structurally has
    # no stories, so it can never satisfy membership), so either order yields the
    # same verdict. Membership is checked FIRST because the dominant write is an
    # agent acting on a WORK project it is a member of — that resolves in a single
    # query, and the always-false kb_scope? probe is only paid on the rare kb path.
    cond do
      Role.role_at_least?(role, :user) -> :ok
      agent_member_of_project?(tenant_id, agent_id, project_id) -> :ok
      kb_scope?(tenant_id, project_id) -> emit_kb_scope_write(tenant_id, agent_id, project_id)
      true -> {:error, :not_found}
    end
  end

  # Issue #517 observability (review): the kb-scope branch is the ONE authorization
  # path where the project-membership gate is INTENTIONALLY bypassed — any agent in
  # the owning tenant may write a `:kb`-kind channel, including an agent that owns no
  # story anywhere. A successful kb-scope write is otherwise audited exactly like an
  # ordinary post and carries NO distinguishing security signal, so a burst of
  # cross-scope injecting posts from a non-member agent (the residual-3 intra-tenant
  # injection surface) is reconstructable only after the fact from the audit log — not
  # independently observable/alertable. Emit a dedicated low-severity telemetry marker
  # + log line so member-bypass kb writes can be monitored / rate-anomaly-detected
  # separately from membership-backed writes, mirroring the denied-path signals
  # (`:ownership_rejected` / `:agent_identity_required`) the controllers already fire.
  # Runs at the SHARED predicate so it covers every caller (post / claim / graduate)
  # in one place. Returns `:ok` so the branch stays authorized.
  defp emit_kb_scope_write(tenant_id, agent_id, project_id) do
    :telemetry.execute(
      [:loopctl, :coordination, :kb_scope_write],
      %{count: 1},
      %{tenant_id: tenant_id, agent_id: agent_id, project_id: project_id}
    )

    Logger.info(
      "coordination kb-scope member-bypass write " <>
        "(tenant=#{tenant_id} agent=#{agent_id} project=#{project_id})"
    )

    :ok
  end

  # Issue #517: a `:kb`-kind scope OWNED by the caller's tenant is a shared,
  # custody-free knowledge partition, writable by any agent in that tenant. The
  # `tenant_id` predicate is what keeps this tenant-safe — a kb-scope in another
  # tenant never matches. `exists?` compiles to `SELECT 1 ... LIMIT 1` and seeks the
  # `projects` primary key, so it never materializes a row. Like the sibling
  # `agent_member_of_project?/3`, `project_id` is assumed already validated by the
  # upstream `get_project/2`/`get_post/2` chokepoint every caller runs first (a
  # malformed id is `:not_found` there, long before it reaches this predicate).
  #
  # Lifecycle: this probe matches on `(id, tenant_id, kind)` only and DELIBERATELY
  # does not gate on `projects.status`, so an ARCHIVED kb-scope (`archive_kb_scope`)
  # stays writable. That is the CONSISTENT choice, not an oversight: the coordination
  # write path is status-agnostic for work projects too (a member may post to an
  # archived work project — `get_project/2` returns archived rows and no caller
  # status-checks), so status-gating only the kb path would be a lone inconsistency.
  # A tenant that wants to freeze a channel deletes/expires its posts; a blanket
  # "reject writes to archived scopes" gate (both kinds) is a separate, deliberate
  # product decision left out of the #517 carve-out.
  defp kb_scope?(tenant_id, project_id) do
    Project
    |> where([p], p.id == ^project_id and p.tenant_id == ^tenant_id and p.kind == :kb)
    |> AdminRepo.exists?()
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

  # ---------------------------------------------------------------------------
  # US-40.4 — ADVISORY FILE SOFT-LOCKS
  #
  # NOT the exactly-once handoff claim (`claim/5`/`release/5`/`done/5` +
  # `channel_claims`). A soft-lock is a collision-avoidance HINT on a FILE target:
  # it is advisory, it NEVER blocks a caller, and two sessions MAY hold one on the
  # same file simultaneously. Never cite this primitive as the handoff-claim
  # mechanism, and never merge the two.
  # ---------------------------------------------------------------------------

  @doc """
  Takes (or REFRESHES) an ADVISORY soft-lock on a file `target` — US-40.4.

  This posts a normal channel post carrying the `"#{@lock_key_prefix}<target>"` key
  convention, a `refs` entry `[%{"type" => "file", "value" => target}]`, and a
  SHORT server-clamped TTL, through the SAME `post/4` write path every other post
  uses — so it inherits the project-membership gate, the secret denylist, the audit
  write, and the keyed-slot upsert without a second copy of any of them.

  ## Advisory — it NEVER blocks (AC-40.4.1 / AC-40.4.4)

  There is NO server-side exclusion: a second session (or a second agent) locking
  the SAME target succeeds and both locks are surfaced. This is coordination, not a
  mutex — the reading agent decides what to do with the hint. Nothing here ever
  prevents an edit.

  ## Slot identity, refresh and release

  A lock occupies the caller's HARDENED 5-column slot
  `(tenant_id, project_id, agent_id, session_id, key)` — the
  `channel_posts_session_key_uidx` rebuilt in migration
  `20260718000000_harden_channel_posts_slot_and_ordering` (the server-stamped
  `agent_id` is part of the slot key; it is NOT the old 4-column form). So the SAME
  session re-locking the same target UPSERTS in place (one row, refreshed TTL),
  while a different session/agent gets its own row.

  `:session_id` is therefore load-bearing and **REQUIRED** — a lock write without one
  is rejected with `{:error, :missing_session}` (review #451). It deliberately does
  NOT fall through to `post/4`'s `maybe_surrogate_session/1`: a `srvgen-<uuid>`
  surrogate is minted fresh on EVERY write, so a surrogate lock is neither
  refreshable (each re-lock of the same file lands a NEW row instead of upserting in
  place) nor releasable by slot — an unreleasable row per lock attempt, at up to the
  120/min write cap, against the 100-row pinned read. Bounded by TTL, but not
  harmless. The MCP proxy and every documented client supply a session id; a client
  that genuinely cannot must post an ordinary keyed note instead.

  ## TTL clamp (the ONE caller-influenced `expires_at`)

  `:ttl_seconds` is clamped to `[#{@min_lock_ttl_seconds}, #{@max_lock_ttl_seconds}]`
  seconds (default `#{@default_lock_ttl_seconds}`); anything absent or non-numeric
  falls back to the default. See `lock_ttl_seconds/1`. The clamped value rides into
  `post/4` on a PRIVATE marker key, never on `:key` — see `resolve_expires_at/1`.

  `opts`: `:role` (the VERIFIED key role — membership bypass only), `:ttl_seconds`,
  `:session_id` (required), `:host`, `:body` (an optional human note replacing the
  default one-liner), `:audit`.

  Returns `post/4`'s result (`{:ok, post, :created | :updated}` and its error
  shapes), plus `{:error, :invalid_target}` for a blank/oversized/non-binary target
  and `{:error, :missing_session}` for a blank/absent `:session_id`.
  """
  @spec lock_file(Ecto.UUID.t(), Ecto.UUID.t(), term(), term(), keyword()) ::
          {:ok, ChannelPost.t(), :created | :updated | :deduplicated}
          | {:error, :invalid_target}
          | {:error, :missing_session}
          | {:error, :not_found}
          | {:error, :agent_not_found}
          | {:error, :conflict}
          | {:error, :supersede_target_not_found}
          | {:error, :unprocessable_entity, String.t()}
          | {:error, Ecto.Changeset.t()}
  def lock_file(tenant_id, agent_id, project_id, target, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)

    with {:ok, normalized} <- normalize_lock_target(target),
         :ok <- require_lock_session(session_id) do
      attrs =
        %{
          project_id: project_id,
          body: lock_body(normalized, Keyword.get(opts, :body)),
          key: lock_key(normalized),
          # US-40.A1 reshaped `refs` from a fixed-key map into a bounded LIST of
          # `%{"type", "value", "label"?}` items — the story's `refs.file = target`
          # predates that. The file target rides as a typed ref ITEM.
          refs: [%{"type" => "file", "value" => normalized}],
          session_id: session_id,
          host: Keyword.get(opts, :host),
          audit: lock_audit(Keyword.get(opts, :audit, []), normalized)
        }
        # The PRIVATE soft-lock marker: its PRESENCE (never the key prefix) is what
        # earns the short clamped TTL, and it is also what clears the reserved-prefix
        # guard in `post/4`. It is never cast into the changeset.
        |> Map.put(@soft_lock_ttl_attr, Keyword.get(opts, :ttl_seconds))

      post(tenant_id, agent_id, Keyword.get(opts, :role, :agent), attrs)
    end
  end

  # A soft-lock without a client session id would be neither refreshable nor
  # releasable by slot (see the `lock_file/5` docstring) — reject it instead of
  # minting an unreleasable surrogate row.
  defp require_lock_session(session_id) do
    if present_string?(session_id), do: :ok, else: {:error, :missing_session}
  end

  @doc """
  RELEASES the caller's OWN advisory soft-lock on `target` — US-40.4 (AC-40.4.3).

  ## Why a real DELETE by slot (and not an upsert-to-already-expired)

  AC-40.4.3 admits either; this ships the DELETE. `delete_post/5` deletes by post
  ID only, so the minimal addition is a delete addressed by the same hardened
  5-column slot key the lock occupies. The rejected alternative — re-posting the
  slot with `expires_at` in the past — leaves a LIVE row behind that only the sweep
  eventually reaps, and that row still counts toward the keyed-slot uniqueness and
  toward every `has_more`/preview read's page budget. A released lock should simply
  be gone; the DELETE is also what makes an immediate re-lock by the same session a
  clean `:created` rather than a resurrection of a tombstone.

  A lock ALSO self-expires via its short TTL (reads filter `expires_at > now`
  independently of the sweep, and `Loopctl.Workers.ChannelPostSweeper` reaps the
  row), so a crashed session can never hold a file indefinitely even if it never
  calls this.

  ## Scope of the ownership guarantee (read this before citing it — review #451)

  Addressed by the slot `(tenant_id, project_id, agent_id, session_id, key)`. Of
  those, `tenant_id` and `agent_id` are SERVER-STAMPED from the verified key and are
  therefore genuine trust boundaries: no caller can release across tenants, and no
  agent can release another agent's lock.

  **`session_id` is NOT a trust boundary — it is caller-supplied**, and
  `active_locks_page/3` publishes every live lock's `session_id`. So two sessions
  SHARING ONE AGENT KEY are not isolated from each other: either can read the other's
  `session_id` from the lock listing and then release (or, via `lock_file/5`,
  overwrite) that lock. The enforced guarantee is therefore **"scoped to your AGENT,
  not to your session"** — the same author-scoped model as `delete_post/5`. That is
  acceptable for advisory hint data (same tenant, same agent identity, nothing
  custody-bearing rides on it), but do NOT document or rely on it as per-session
  isolation.

  ## Oracle-safety

  A nonexistent lock, ANOTHER AGENT's lock, a lock held by a DIFFERENT session id
  than the one supplied, a cross-tenant/cross-project lock, a missing session id,
  and a malformed target ALL return a byte-identical `{:error, :not_found}`: no
  existence oracle (the same posture as `delete_post/5` and `release/5`).

  The delete and its audit entry run in ONE transaction (`run_delete/5`), recorded
  under the DISTINCT action `#{@soft_lock_release_action}` — never the `deleted`
  action the US-39.7 secret-redaction path uses, so routine lock churn cannot dilute
  that security signal.

  `opts`: `:session_id` (required — see `lock_file/5`), `:audit`.
  """
  @spec unlock_file(Ecto.UUID.t(), Ecto.UUID.t(), term(), term(), keyword()) ::
          {:ok, ChannelPost.t()} | {:error, :not_found | :audit_write_failed}
  def unlock_file(tenant_id, agent_id, project_id, target, opts \\ []) do
    with {:ok, normalized} <- normalize_lock_target(target),
         %ChannelPost{} = post <-
           fetch_owned_lock(
             tenant_id,
             agent_id,
             project_id,
             Keyword.get(opts, :session_id),
             lock_key(normalized)
           ) do
      run_delete(
        tenant_id,
        agent_id,
        post,
        lock_audit(Keyword.get(opts, :audit, []), normalized),
        @soft_lock_release_action
      )
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The PINNED active advisory-lock read for a channel — US-40.4 (AC-40.4.2).

  A DEDICATED read rather than a flag on `recent_page/3`: an active lock must be
  visible BEFORE a session edits a file, and the newest-N recency preview can
  truncate it away on a busy channel. Same rationale (and same left-anchored
  `key LIKE` prefix approach) as `directed_handoffs_page/3` — there is deliberately
  NO `kind` column on `channel_posts`.

  Surfaces every live lock, UP TO the page cap and the per-agent fairness cap —
  both of which are reported by `active_locks_page/3` (`overflowed?` /
  `holders_truncated?`), so a truncated page is never presented as a complete one.
  A live lock is: unexpired (`expires_at > now`, independent of the
  sweep — so an expired lock disappears IMMEDIATELY, TC-40.4.2), inside the soft-lock
  TTL ceiling (see `live_locks_scope/3`), not quarantined,
  not superseded. Rows are NOT deduplicated by key: two sessions holding a lock on
  the same file is a legitimate advisory state and BOTH must be surfaced
  (AC-40.4.4) — deduping would hide exactly the collision the caller is looking for.

  Each row is a `select_preview/1` projection (bounded, TOAST-safe body preview)
  plus `:target` (the key with the `#{@lock_key_prefix}` prefix stripped) and
  `:expires_at`, so a consumer can render "claimed: <file> by <agent/host>, <age>".
  Newest lock first.

  Returns `[preview()]`; a malformed tenant/project id yields `[]` (never a raise).
  """
  @spec active_locks(term(), term(), keyword()) :: [map()]
  def active_locks(tenant_id, project_id, opts \\ []) do
    {locks, _overflowed?, _holders_truncated?} = active_locks_page(tenant_id, project_id, opts)
    locks
  end

  @doc """
  The same read as `active_locks/3`, additionally reporting BOTH ways the set can be
  truncated. Returns `{[preview()], overflowed?, holders_truncated?}`.

    * `overflowed?` — the PAGE CAP dropped rows. Detected without a second query by
      fetching `limit + 1` rows. `:limit` defaults to
      #{@default_active_locks_limit} and is clamped to #{@max_active_locks_limit}.
    * `holders_truncated?` — the per-agent FAIRNESS cap dropped rows. This is a
      SEPARATE signal on purpose (review #451): the fairness filter runs INSIDE the
      scope, before the `limit + 1` over-fetch, so rows it removes are structurally
      invisible to `overflowed?`. Reporting only `overflowed?` would publish
      `overflow: false` on a page that had silently dropped live locks — precisely
      the "you may edit, nobody holds this file" answer this read must never give
      wrongly. Costs one cheap aggregate over the same indexed scope.

  A caller that sees EITHER flag must treat the page as incomplete (raise `:limit`,
  or read the channel directly) rather than as "these are all the live locks".

  ## Per-agent FAIRNESS (review #451)

  The page cap truncates NEWEST-first, so a single noisy holder could otherwise fill
  every slot and evict every PEER's lock from the very read that exists to surface
  peers. Each AGENT therefore contributes at most #{@max_locks_per_holder} rows (its
  newest) — enforced in SQL by a `row_number() OVER (PARTITION BY agent_id)`
  pre-filter, so the budget applies BEFORE the page cap rather than after it. The
  partition is the SERVER-STAMPED `agent_id` only: partitioning on the
  caller-supplied `session_id` too would let a caller rotating session ids escape the
  bound entirely.
  """
  @spec active_locks_page(term(), term(), keyword()) :: {[map()], boolean(), boolean()}
  def active_locks_page(tenant_id, project_id, opts \\ []) do
    if valid_uuid?(tenant_id) and valid_uuid?(project_id) do
      now = DateTime.utc_now()
      limit = opts |> Keyword.get(:limit) |> clamp_active_locks_limit()
      base = live_locks_scope(tenant_id, project_id, now)

      rows =
        base
        |> where([p], p.id in subquery(fair_lock_ids(base)))
        |> order_by([p], desc: p.inserted_at, desc: p.seq)
        |> limit(^(limit + 1))
        |> select_preview()
        |> AdminRepo.all()
        |> Enum.map(&finalize_preview/1)
        |> Enum.map(&Map.put(&1, :target, lock_target(&1.key)))

      {Enum.take(rows, limit), length(rows) > limit, holders_truncated?(base)}
    else
      {[], false, false}
    end
  end

  # The live-lock predicate, shared by the page read and its fairness pre-filter so
  # the two can never drift.
  #
  # `@lock_key_like` is a LITERAL (never `^param`) so the partial index
  # `channel_posts_soft_lock_idx` is provably implied and actually chosen.
  #
  # The UPPER bound on `expires_at` is the read-side enforcement of the TTL ceiling
  # (review #451). A genuine soft-lock is clamped to <= @max_lock_ttl_seconds at
  # write, so it always satisfies it; a row that does NOT is not a live lock, and
  # publishing it as one would be a lie of up to 30 days. Two real classes land there:
  # a LEGACY `claim:`-keyed ordinary post written before the namespace was reserved
  # (uniform 30-day retention), and a soft-lock that was quarantined and then RELEASED
  # (`ChannelPost.release_changeset/3` restores `inserted_at + retention_days`, which
  # for a lock is far looser than its own lease).
  defp live_locks_scope(tenant_id, project_id, now) do
    horizon = DateTime.add(now, @max_lock_ttl_seconds, :second)

    ChannelPost
    |> where([p], p.tenant_id == ^tenant_id and p.project_id == ^project_id)
    |> where([p], like(p.key, @lock_key_like))
    |> where([p], p.expires_at > ^now and p.expires_at <= ^horizon)
    |> where([p], is_nil(p.quarantined_at))
    |> where([p], is_nil(p.superseded_by))
  end

  # The ids of the newest @max_locks_per_holder locks PER AGENT (see the attribute
  # comment for why the partition deliberately excludes the caller-supplied
  # `session_id`).
  defp fair_lock_ids(base) do
    ranked =
      base
      |> select([p], %{
        id: p.id,
        holder_rank:
          over(row_number(),
            partition_by: [p.agent_id],
            order_by: [desc: p.inserted_at, desc: p.seq]
          )
      })

    from(r in subquery(ranked), where: r.holder_rank <= ^@max_locks_per_holder, select: r.id)
  end

  # Did the fairness cap drop any LIVE lock? One aggregate over the same scope: an
  # agent holding more than the budget is exactly an agent whose overflow rows were
  # removed before the page cap could see them.
  defp holders_truncated?(base) do
    base
    |> group_by([p], p.agent_id)
    |> having([p], count(p.id) > ^@max_locks_per_holder)
    |> select([p], 1)
    |> limit(1)
    |> AdminRepo.all()
    |> Kernel.!=([])
  end

  @doc """
  The EFFECTIVE soft-lock TTL, in seconds, for a requested `ttl_seconds` — clamped
  to `[#{@min_lock_ttl_seconds}, #{@max_lock_ttl_seconds}]`, defaulting to
  #{@default_lock_ttl_seconds} for anything absent or not integer-shaped.

  Public so the endpoint can report the ACTUALLY-applied TTL from the SAME source of
  truth the write uses, never a divergent second copy.
  """
  @spec lock_ttl_seconds(term()) :: pos_integer()
  def lock_ttl_seconds(ttl) when is_integer(ttl),
    do: ttl |> max(@min_lock_ttl_seconds) |> min(@max_lock_ttl_seconds)

  def lock_ttl_seconds(ttl) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, ""} -> lock_ttl_seconds(n)
      _ -> @default_lock_ttl_seconds
    end
  end

  def lock_ttl_seconds(_), do: @default_lock_ttl_seconds

  @doc "The advisory soft-lock key prefix (`#{@lock_key_prefix}`) — the ONLY routing signal (no `kind` column)."
  @spec lock_key_prefix() :: String.t()
  def lock_key_prefix, do: @lock_key_prefix

  @doc "The soft-lock TTL ceiling in seconds (#{@max_lock_ttl_seconds}) — the single source of truth for every lock liveness bound."
  @spec max_lock_ttl_seconds() :: pos_integer()
  def max_lock_ttl_seconds, do: @max_lock_ttl_seconds

  @doc """
  Is this READ-MODEL ROW an advisory soft-lock? — the discriminator every consumer
  must use instead of a bare key-prefix test (review #451).

  The `#{@lock_key_prefix}` namespace is reserved server-side going forward, but the
  prefix ALONE is not sufficient evidence for a row that already exists: a legacy
  post keyed `#{@lock_key_prefix}...` (written before the reservation) carries the
  uniform 30-day retention, and so does a soft-lock that was quarantined and then
  released. Both would be mislabeled as live file locks. A genuine lock's lease is
  clamped to at most #{@max_lock_ttl_seconds}s at EVERY write, so
  `expires_at <= updated_at + #{@max_lock_ttl_seconds}s` is the bound that
  distinguishes them.

  The bound is against `updated_at`, NOT `inserted_at`: a refresh is a keyed upsert
  that deliberately PRESERVES `inserted_at` while extending the lease, so a lock
  refreshed 50 minutes after it was first taken legitimately has
  `expires_at > inserted_at + #{@max_lock_ttl_seconds}s` — anchoring on `inserted_at`
  would silently stop marking exactly the long-running edits the marker matters most
  for. (`live_locks_scope/3` anchors its SQL bound on `now` instead, which every
  refreshed lock also satisfies.)
  """
  @spec soft_lock_row?(map()) :: boolean()
  def soft_lock_row?(%{key: key, expires_at: %DateTime{} = expires_at} = row) do
    case Map.get(row, :updated_at) do
      %DateTime{} = updated_at ->
        soft_lock_key?(key) and
          DateTime.compare(expires_at, DateTime.add(updated_at, @max_lock_ttl_seconds, :second)) !=
            :gt

      _ ->
        false
    end
  end

  def soft_lock_row?(_row), do: false

  @doc "The default page size `active_locks/3` applies, shared with the endpoint's `meta.limit`."
  @spec default_active_locks_limit() :: pos_integer()
  def default_active_locks_limit, do: @default_active_locks_limit

  @doc "The EFFECTIVE `active_locks/3` page size for a requested `limit` (clamped; exposed for `meta.limit`)."
  @spec clamp_active_locks_limit(term()) :: pos_integer()
  def clamp_active_locks_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_active_locks_limit)

  def clamp_active_locks_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 -> clamp_active_locks_limit(n)
      _ -> @default_active_locks_limit
    end
  end

  def clamp_active_locks_limit(_), do: @default_active_locks_limit

  # The lock's slot key. `lock_target/1` is its inverse for the read model.
  defp lock_key(target), do: @lock_key_prefix <> target

  defp lock_target(key) when is_binary(key),
    do: String.replace_prefix(key, @lock_key_prefix, "")

  defp lock_target(_), do: nil

  # A soft-lock target must be a present binary that keeps the derived key within
  # the `channel_posts.key` bound (200 bytes). A blank / oversized / non-binary
  # target is rejected up front with a DISTINCT error so the endpoint can 422 with
  # an honest message, rather than surfacing a confusing key-length changeset error.
  @max_lock_target_bytes 200 - byte_size(@lock_key_prefix)

  # The target is also PATH-NORMALIZED (review #451). The slot identity IS the
  # derived key, so without normalization `lib/foo.ex`, `./lib/foo.ex`,
  # `lib//foo.ex` and `/lib/foo.ex` are four DIFFERENT slots on the same file: two
  # sessions editing it with different spellings each take a lock and each sees the
  # other's as an unrelated target — the collision avoidance the story exists to
  # provide silently never fires — while one session that spells the path
  # differently across refreshes leaks an extra un-refreshable row per spelling
  # instead of upserting in place. Normalizing makes slot identity match the thing
  # being protected: drop `.` and empty segments (so `./a`, `a//b` and `a/./b`
  # collapse) and RELATIVIZE a leading `/` rather than rejecting it (an absolute
  # path is a legitimate spelling of the same repo file from a different cwd). `..`
  # segments are left alone — resolving them without a repo root would be a guess,
  # and the target is advisory display data, never a filesystem operation.
  defp normalize_lock_target(target) when is_binary(target) do
    normalized =
      target
      |> String.trim()
      |> String.split("/")
      |> Enum.reject(&(&1 == "" or &1 == "."))
      |> Enum.join("/")

    cond do
      normalized == "" -> {:error, :invalid_target}
      byte_size(normalized) > @max_lock_target_bytes -> {:error, :invalid_target}
      true -> {:ok, normalized}
    end
  end

  defp normalize_lock_target(_target), do: {:error, :invalid_target}

  # The default lock body. Deliberately terse and self-describing: it lands on the
  # shared channel and is injected into peer sessions as untrusted DATA, so it says
  # what the lock IS (advisory) rather than issuing an instruction.
  defp lock_body(target, note) do
    if is_binary(note) and String.trim(note) != "" do
      String.trim(note)
    else
      "advisory soft-lock: editing #{target} (advisory only — it does not block you)"
    end
  end

  # Carry the lock target into the audit metadata for BOTH lock and unlock so the
  # trail names the file, not just the post id.
  defp lock_audit(audit, target) do
    metadata = audit |> Keyword.get(:metadata, %{}) |> Map.put("soft_lock_target", target)
    Keyword.put(audit, :metadata, metadata)
  end

  # Fetch the caller's OWN lock by the HARDENED 5-column slot key — the delete-by-slot
  # path AC-40.4.3 calls for (`delete_post/5` addresses by post id only). The index
  # `channel_posts_session_key_uidx` makes this at most one row. Every miss (foreign
  # tenant/project/agent/session, malformed id, blank session) returns nil so the
  # caller collapses to one byte-identical `{:error, :not_found}`.
  #
  # QUARANTINED rows are excluded (review #451), matching `live_locks_scope/3`. Two
  # reasons: (1) a release is a HARD DELETE recorded under the benign
  # `#{@soft_lock_release_action}` action, so without this an author could destroy a
  # post the secret-denylist rescan flagged — the operator's only reviewable artifact
  # — under a routine-churn label instead of the `deleted` redaction action operators
  # watch; (2) read/write consistency — no lock read will show a quarantined row, so
  # no lock write may address one. `delete_post/5` remains the explicit (and
  # explicitly-labeled) redaction path.
  defp fetch_owned_lock(tenant_id, agent_id, project_id, session_id, key) do
    if valid_uuid?(tenant_id) and valid_uuid?(agent_id) and valid_uuid?(project_id) and
         present_string?(session_id) do
      ChannelPost
      |> where(
        [p],
        p.tenant_id == ^tenant_id and p.project_id == ^project_id and
          p.agent_id == ^agent_id and p.session_id == ^session_id and p.key == ^key
      )
      |> where([p], is_nil(p.quarantined_at))
      |> AdminRepo.one()
    else
      nil
    end
  end

  # US-40.4: the SINGLE place `expires_at` is caller-influenced. Routing is on the
  # PRIVATE `@soft_lock_ttl_attr` marker that only `lock_file/5` stamps — NOT on the
  # caller-chosen `key`. Every other post keeps the uniform `now + @retention_days`
  # retention, so no request body can shorten or extend channel retention (review
  # #451: the earlier key-prefix routing made that stated invariant false — a
  # perfectly ordinary post keyed `claim:story-812` was silently cut to 900s).
  defp resolve_expires_at(attrs) do
    case Map.fetch(attrs, @soft_lock_ttl_attr) do
      {:ok, ttl} -> DateTime.add(DateTime.utc_now(), lock_ttl_seconds(ttl), :second)
      :error -> default_expires_at()
    end
  end

  # The `claim:` key namespace is RESERVED for advisory soft-locks (review #451).
  # Every lock read routes on `key LIKE 'claim:%'` alone — there is no `kind` column
  # — so a caller-keyed post in that namespace would masquerade as a live file lock
  # in `active_locks_page/3` and in `channel_recent`'s lock marker. Rejecting it here
  # (rather than silently reinterpreting it, as the first cut did) keeps the prefix a
  # sound predicate and tells the caller exactly what to do instead. Enforced by
  # BOTH writers (`post/4` and `create_post/4`), so the namespace is not guaranteed by
  # a single call site.
  #
  # The reservation is forward-looking only, so it is NOT the whole defense: rows
  # written BEFORE it (the `claim:` key convention predates this branch) carry the
  # uniform 30-day retention and would otherwise be published as live file locks for
  # up to 30 days. Every lock read therefore ALSO carries the TTL-ceiling bound (see
  # `live_locks_scope/3` and `soft_lock_row?/1`), which no such row can satisfy.
  defp reserved_key_prefix_check(attrs) do
    if soft_lock_key?(Map.get(attrs, :key)) and not Map.has_key?(attrs, @soft_lock_ttl_attr) do
      {:error, :unprocessable_entity, @reserved_key_prefix_message}
    else
      :ok
    end
  end

  defp soft_lock_key?(key) when is_binary(key), do: String.starts_with?(key, @lock_key_prefix)
  defp soft_lock_key?(_key), do: false

  @doc "The retention window, in days, a DONE claim is kept before the sweep reaps it."
  @spec claim_done_retention_days() :: pos_integer()
  def claim_done_retention_days, do: @claim_done_retention_days

  @doc "The default claim lease, in seconds (overridable per claim, clamped)."
  @spec default_lease_seconds() :: pos_integer()
  def default_lease_seconds, do: @default_lease_seconds

  @doc """
  Claims a handoff `ref` for exactly ONE agent — the INSERT-to-claim write
  (US-40.B1). A successful INSERT returns `{:ok, %ChannelClaim{}}`; a concurrent
  loser hits the `(tenant_id, project_id, ref)` UNIQUE index and gets
  `{:error, :already_claimed}` (→ HTTP 409). This is a PURE INSERT, never a
  read-then-insert: Postgres serializes concurrent inserts on the unique index, so
  exactly one commits and the rest raise a unique violation `unique_constraint/3`
  converts to a changeset error — NO TOCTOU window (the reason INSERT-to-claim was
  chosen over a SELECT-FOR-UPDATE / upsert claim).

  `tenant_id` and `agent_id` are server-stamped from the verified key identity
  (never the request body). `agent_id` is the CLAIMANT. `ref` is the caller-supplied
  anchor (a free string, e.g. `"handoff:repo#812"`). `opts`:

    * `:role` — the caller's VERIFIED key role, used only for the elevated-role
      membership bypass in `project_writable_by_agent/4`. Defaults to `:agent`
      (default-deny) when absent.
    * `:lease_seconds` — the claim's lease length; clamped to
      `[1, #{@max_lease_seconds}]`, default `#{@default_lease_seconds}`.
    * `:audit` — the actor-context keyword list from
      `LoopctlWeb.AuditContext.from_conn/1`, written into the audit entry.

  ## Authorization (AC-40.B1.7 — shares the 40.D3 predicate)

  Owning the target project's TENANT is NOT sufficient: the caller must ALSO be a
  writable MEMBER of the specific project (`project_writable_by_agent/4`) — the SAME
  default-deny gate `post/4` uses. A missing/cross-tenant project, a foreign-tenant
  agent, and a non-member agent all collapse to a byte-identical error the endpoint
  maps to the shared 422 (no "not a member" vs "not your tenant" oracle).

  NON-CIRCULARITY (coordination.ex `project_writable_by_agent/4` moduledoc): claiming
  a STORY is HOW an agent obtains assignment-membership (`stories.assigned_agent_id`).
  This COORDINATION claim is a SEPARATE surface — gating it on membership does NOT
  touch `Progress.claim_story/3`, so there is no bootstrap where you need membership
  to claim the work that grants it.

  The insert and its audit entry run in ONE `AdminRepo.transaction` (Multi),
  mirroring `run_post/3`, so a claim is never recorded without an accountable trail.

  ## Idempotent owner re-claim

  INSERT-to-claim is exactly-once, but the OWNER re-claiming its OWN still-active
  (`done_at IS NULL`) ref is IDEMPOTENT — it returns `{:ok, existing}`, not a 409.
  This closes a dropped-handoff window: if the winning insert commits but the caller
  never sees the 201 (a lost HTTP response / MCP timeout), the retry must NOT be told
  "another agent owns this, move on" — the caller IS the owner and would otherwise
  abandon a handoff it holds until the lease expires. A genuine racing loser (a peer
  owns the slot), and the owner re-claiming its OWN already-DONE claim, still get
  `{:error, :already_claimed}`.

  Returns `{:ok, %ChannelClaim{}}` (fresh claim OR idempotent owner re-claim),
  `{:error, :already_claimed}`,
  `{:error, :not_found}` (missing/cross-tenant/cross-project),
  `{:error, :agent_not_found}` (foreign-tenant server-stamped agent), or
  `{:error, %Ecto.Changeset{}}` (a bad `ref` — over-length or NUL byte).
  """
  # Per-agent concurrent open claim bound (anti-squatting, AC-40.B1 review finding).
  # Deliberately generous — normal agents should never hit this — but prevents a
  # single compromised/broken agent from enumerating and claiming every open handoff.
  @max_concurrent_open_claims 50

  @spec claim(Ecto.UUID.t(), Ecto.UUID.t(), term(), term(), keyword()) ::
          {:ok, ChannelClaim.t()}
          | {:error, :already_claimed}
          | {:error, :not_found}
          | {:error, :agent_not_found}
          | {:error, Ecto.Changeset.t()}
  def claim(tenant_id, agent_id, project_id, ref, opts \\ []) do
    role = Keyword.get(opts, :role, :agent)
    audit = Keyword.get(opts, :audit, [])
    lease_seconds = normalize_lease_seconds(Keyword.get(opts, :lease_seconds))

    now = DateTime.utc_now()

    changeset =
      %ChannelClaim{
        tenant_id: tenant_id,
        project_id: project_id,
        claimant_agent_id: agent_id,
        claimed_at: now,
        lease_expires_at: DateTime.add(now, lease_seconds, :second)
      }
      |> ChannelClaim.create_changeset(%{ref: ref})

    with {:ok, _project} <- Projects.get_project(tenant_id, project_id),
         {:ok, _agent} <- agent_owned(tenant_id, agent_id),
         :ok <- project_writable_by_agent(tenant_id, agent_id, project_id, role),
         # The ref must be shown well-formed BEFORE any query compares it against a
         # `text` column: a NUL byte is valid UTF-8 that Postgres refuses (22021), so
         # `verify_ref_not_superseded/3` below would raise a 500 instead of returning
         # the 422 this changeset already carries.
         {:ok, %ChannelClaim{ref: ref}} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- verify_ref_not_superseded(tenant_id, project_id, ref),
         :ok <- verify_agent_claim_budget(tenant_id, project_id, agent_id) do
      run_claim(tenant_id, project_id, agent_id, changeset, audit)
    end
  end

  @doc """
  Marks the caller's OWN claim on `ref` done — sets `done_at = now()` (US-40.B1).

  Fetches the caller's own claim scoped by BOTH `tenant_id` AND `claimant_agent_id`
  AND `project_id` AND `ref` on `AdminRepo`, so a NON-OWNER, a cross-tenant caller,
  a cross-PROJECT caller, and a missing claim ALL collapse to a byte-identical
  `{:error, :not_found}` — no existence oracle, and no separate role needed: the
  owner-scoped fetch is a STRICTER project authorization than
  `project_writable_by_agent/4` (you must be the actual claimant in this project,
  not merely a member), satisfying AC-40.B1.7 without a `:role`.

  The update and its audit entry run in ONE `AdminRepo.transaction` (Multi).

  Returns `{:ok, %ChannelClaim{}}` (the updated claim), `{:error, :not_found}`, or
  `{:error, %Ecto.Changeset{}}` (the `:audit` Multi step's changeset insert failed —
  see `run_claim_lifecycle/7`).
  """
  @spec done(Ecto.UUID.t(), Ecto.UUID.t(), term(), term(), keyword()) ::
          {:ok, ChannelClaim.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def done(tenant_id, agent_id, project_id, ref, audit \\ []) do
    now = DateTime.utc_now()

    case fetch_owned_claim(tenant_id, agent_id, project_id, ref) do
      %ChannelClaim{lease_expires_at: lease, done_at: nil} = claim ->
        if DateTime.compare(lease, now) == :gt do
          changeset = Ecto.Changeset.change(claim, done_at: now)
          run_claim_lifecycle(tenant_id, project_id, agent_id, :update, changeset, "done", audit)
        else
          # Expired lease: the claim is no longer valid. The sweeper will reap it;
          # the caller should re-claim if they still want to mark this ref done.
          {:error, :not_found}
        end

      %ChannelClaim{} ->
        # Already done — idempotent or a race. Treat as not_found to avoid leaking
        # claim state.
        {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Releases (DELETES) the caller's OWN OPEN claim on `ref` so the ref can be re-claimed
  (US-40.B1). A DONE claim is terminal and CANNOT be released — this preserves the
  "a DONE handoff never reappears" guarantee.

  Owner-scoped exactly like `done/5`: a non-owner / cross-tenant / cross-project /
  missing claim all return a byte-identical `{:error, :not_found}` (no oracle, no
  `:role` needed). The delete and its audit entry run in ONE
  `AdminRepo.transaction` (Multi).

  Returns `{:ok, %ChannelClaim{}}` (the deleted claim), `{:error, :not_found}`,
  `{:error, :already_claimed}` (the claim is already DONE — terminal), or
  `{:error, %Ecto.Changeset{}}` (the `:audit` Multi step's changeset insert failed —
  see `run_claim_lifecycle/7`).
  """
  @spec release(Ecto.UUID.t(), Ecto.UUID.t(), term(), term(), keyword()) ::
          {:ok, ChannelClaim.t()}
          | {:error, :not_found}
          | {:error, :already_claimed}
          | {:error, Ecto.Changeset.t()}
  def release(tenant_id, agent_id, project_id, ref, audit \\ []) do
    case fetch_owned_claim(tenant_id, agent_id, project_id, ref) do
      %ChannelClaim{done_at: nil} = claim ->
        run_claim_lifecycle(
          tenant_id,
          project_id,
          agent_id,
          :delete,
          claim,
          "released",
          audit
        )

      %ChannelClaim{} ->
        {:error, :already_claimed}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  The channel's UNSWEPT claim rows — the NON-DESTRUCTIVE way to ask "is this ref
  claimed, and by whom" (#707).

  ## Why this read exists

  Until it did, the only way to learn whether a ref was claimed was to ATTEMPT a claim
  and read the result: a `201` meant it was free, a `409 already_claimed` meant it was
  taken. That probe is destructive on a shared-agent fleet. `claim/5` is IDEMPOTENT
  for the owning AGENT, and every session on this fleet authenticates as the same
  `agent_id`, so a probe issued while a PEER SESSION holds the ref returns that peer's
  claim as if it were the prober's own — and the release that tidies the probe up
  DELETES IT. The peer keeps working a handoff the bus has already reopened, and a
  second machine picks it up. That is not hypothetical: it is what #707 recorded.

  So: read with this, never by claiming.

  ## The predicate is the CLAIM-side one: does a row still hold the slot

  Every row listed here is a row `claim/5` would collide with, because the
  `(tenant_id, project_id, ref)` unique index does not care about lifecycle state: a
  DONE claim, an OPEN one, and one whose lease EXPIRED before `ChannelClaimSweeper`
  reaped it all refuse a fresh claim identically. So LISTED means "a row holds this
  ref's slot", and ABSENT means no row does.

  That is what the reader needs and it is NOT an equivalence with the claim outcome —
  say only what holds, because a reader that over-trusts this read goes back to
  probing. A listed row whose `claimant_agent_id` is the CALLER's own still-open claim
  is returned idempotently, not refused (`resolve_claim_collision/4`), which on a fleet
  sharing one `agent_id` is the common case. And `claim/5` refuses on three further
  grounds that put no row here at all: a superseded ref, an exhausted per-agent claim
  budget, and a non-member caller (the read is not membership-gated).

  It is deliberately NOT `active_claim_subquery/1`, the handoffs EXCLUSION. That
  predicate (DONE **or** unexpired) drops the expired-but-unswept row, so this read
  reported such a ref as free while `claim/5` still answered `409 already_claimed` —
  an agent told "free", then told "taken, move on", for up to one sweeper interval.
  The two flags the handoffs question needs ride on each row instead: a row with
  `done_at` set, or with a lease still in the future, is one EXCLUDING its handoff; an
  expired, not-done row has already reopened its handoff and is merely awaiting sweep.

  A RELEASED claim (row deleted) and a SWEPT one are absent, which is also exactly
  when the ref becomes claimable again.

  ## Scope, ordering, bounds

  Tenant- AND project-scoped explicitly on `AdminRepo` (the module convention — a query
  omitting the tenant filter is a bug). Optional `:ref` narrows to one anchor, which is
  the point-lookup shape a session about to claim actually wants; a MALFORMED `:ref`
  (blank, non-binary, or carrying a NUL byte, which is valid UTF-8 that Postgres refuses
  to compare against `text`) yields an EMPTY page — it must never fall back to the
  unfiltered query, which would answer another ref's claim to a caller asking about its
  own.

  Ordered OPEN claims first, then EXPIRED-awaiting-sweep, then DONE, each newest-claimed
  first, capped at `clamp_claims_limit/1`. The ordering is the truncation bound that
  matters here: DONE claims are retained `claim_done_retention_days/0` days, so on a busy
  channel they outnumber every other state, and a plain newest-first page would drop a
  row that still HOLDS a ref to make room for a week-old finished one — telling a reader
  that a held ref is free. DONE last is what prevents that; an expired-unswept row holds
  the slot just as an open one does, so it sorts ahead of DONE too. A truncated page can
  still have dropped a DONE row, so `meta.overflow` must invalidate an "absent =
  claimable" conclusion. The cap is reported rather than silently applied —
  `{claims, overflowed?}`.

  ## Oracle-safety

  Identical posture to `active_locks_page/3` and `directed_handoffs_page/3`: a malformed
  `tenant_id`/`project_id` returns `{[], false}` via the `valid_uuid?/1` guard, and a
  cross-tenant or nonexistent `project_id` naturally returns an empty page rather than a
  404. Like `GET /channel/locks`, the read is TENANT-scoped and NOT membership-gated —
  any agent in the tenant may read any of that tenant's channels' claims. The US-40.D3
  membership gate applies to the WRITE path (`claim/5`), not here.

  Returns `{[%ChannelClaim{}], overflowed?}`.
  """
  @spec claims_page(term(), term(), keyword()) :: {[ChannelClaim.t()], boolean()}
  def claims_page(tenant_id, project_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit) |> clamp_claims_limit()

    with true <- valid_uuid?(tenant_id) and valid_uuid?(project_id),
         {:ok, ref_filter} <- normalize_ref_filter(Keyword.get(opts, :ref)) do
      now = DateTime.utc_now()

      rows =
        ChannelClaim
        |> where([c], c.tenant_id == ^tenant_id and c.project_id == ^project_id)
        |> filter_claims_by_ref(ref_filter)
        # OPEN, then EXPIRED-unswept, then DONE, then newest-claimed. See the ordering
        # note above: DONE last is what keeps a week of retained finished rows from
        # evicting a row that still HOLDS its ref off the page.
        |> order_by([c],
          desc: fragment("(? IS NULL AND ? > ?)", c.done_at, c.lease_expires_at, ^now),
          desc: fragment("(? IS NULL)", c.done_at),
          desc: c.claimed_at,
          desc: c.id
        )
        # One row over the cap, so overflow is DETECTED rather than inferred from
        # `length(rows) == limit` — which is ambiguous on an exactly-full page.
        |> limit(^(limit + 1))
        |> AdminRepo.all()

      {Enum.take(rows, limit), length(rows) > limit}
    else
      _ -> {[], false}
    end
  end

  # `nil` is LIST mode; anything else must be a well-formed `ref`. The controller
  # already refuses a malformed one with a 422 — this is the defense-in-depth half, and
  # it must never fall through to the UNFILTERED query: silently widening a point lookup
  # hands a caller asking about ONE ref some OTHER ref's claim, read as "mine is taken".
  defp normalize_ref_filter(nil), do: {:ok, :all}

  defp normalize_ref_filter(ref) do
    if valid_ref?(ref), do: {:ok, ref}, else: :error
  end

  defp filter_claims_by_ref(query, :all), do: query
  defp filter_claims_by_ref(query, ref), do: where(query, [c], c.ref == ^ref)

  @doc """
  Is `ref` a well-formed claim anchor? The SINGLE definition of that, shared by the read
  filter, the pre-query write guards, and the controller's 422.

  Mirrors `ChannelClaim.create_changeset/2`'s own rules rather than restating them: a
  blank or whitespace-only ref is no anchor, a NUL byte is valid UTF-8 that Postgres
  refuses to compare against `text` (22021, i.e. a 500), and the byte cap is the stored
  column's. Two copies of this rule would drift, and the drift shows up as a ref the
  WRITE refuses with a 422 reading back from `claims_page/3` as an empty page — which
  this surface documents as "nothing holds it".
  """
  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(ref) when is_binary(ref) do
    String.trim(ref) != "" and not String.contains?(ref, <<0>>) and
      byte_size(ref) <= ChannelClaim.ref_max_length()
  end

  def valid_ref?(_ref), do: false

  @doc "Default page size for `claims_page/3`."
  @spec default_claims_limit() :: pos_integer()
  def default_claims_limit, do: @default_claims_limit

  @doc """
  Clamps a caller-supplied `claims_page/3` limit to
  `[1, #{@max_claims_limit}]`, defaulting anything unparseable to
  `#{@default_claims_limit}`. Mirrors `clamp_active_locks_limit/1`.
  """
  @spec clamp_claims_limit(term()) :: pos_integer()
  def clamp_claims_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_claims_limit)

  def clamp_claims_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 -> clamp_claims_limit(n)
      _ -> @default_claims_limit
    end
  end

  def clamp_claims_limit(_), do: @default_claims_limit

  # Fetch the caller's OWN claim CONSTRAINED to (tenant_id, project_id,
  # claimant_agent_id, ref) — the oracle-safe owner boundary on the AdminRepo
  # (BYPASSRLS) path. A non-owner, cross-tenant, cross-project, or nonexistent claim
  # all return nil, collapsing to the same `{:error, :not_found}`. `tenant_id` and
  # `project_id` are guarded with `valid_uuid?/1` (a malformed path segment is a
  # clean nil, never an `Ecto.Query.CastError`/500); `ref` is a free string but must be
  # WELL-FORMED (`valid_ref?/1`) before it is compared against a stored `text` value —
  # a NUL byte reaching this query raises 22021 (a 500) on `done`/`release`, and no
  # changeset runs on those paths to catch it first.
  defp fetch_owned_claim(tenant_id, agent_id, project_id, ref) do
    if valid_uuid?(tenant_id) and valid_uuid?(agent_id) and valid_uuid?(project_id) and
         valid_ref?(ref) do
      ChannelClaim
      |> where(
        [c],
        c.tenant_id == ^tenant_id and c.project_id == ^project_id and
          c.claimant_agent_id == ^agent_id and c.ref == ^ref
      )
      |> AdminRepo.one()
    else
      nil
    end
  end

  # Insert + audit in one transaction. A UNIQUE violation on
  # (tenant_id, project_id, ref) — declared as `unique_constraint(:ref, ...)` on the
  # changeset — is caught by Ecto and returned as an `{:error, :claim, changeset, _}`
  # carrying that constraint error. We then DISAMBIGUATE the loser via
  # `resolve_claim_collision/4`: the true owner re-claiming its own ACTIVE claim (a
  # lost-response retry) gets an idempotent `{:ok, existing}`, while a genuine racing
  # loser (or a re-claim of one's own already-done claim) gets `{:error,
  # :already_claimed}` (→ 409). A NON-unique changeset error (an over-length or
  # NUL-byte `ref`) is returned as `{:error, %Ecto.Changeset{}}` (→ 422). The
  # `:already_claimed` discriminator is the presence of the `:unique` constraint
  # error, NOT a blanket "any changeset error" — so a validation failure never
  # masquerades as a 409.
  defp run_claim(tenant_id, project_id, agent_id, changeset, audit) do
    multi =
      Multi.new()
      |> Multi.insert(:claim, changeset)
      |> Audit.log_in_multi(:audit, fn %{claim: claim} ->
        claim_audit_attrs(tenant_id, project_id, agent_id, claim, "claimed", audit)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{claim: claim}} ->
        {:ok, claim}

      {:error, :claim, %Ecto.Changeset{} = changeset, _changes} ->
        if already_claimed?(changeset) do
          ref = Ecto.Changeset.get_field(changeset, :ref)
          resolve_claim_collision(tenant_id, project_id, agent_id, ref)
        else
          {:error, changeset}
        end

      # Any OTHER failed step (today only `:audit`, whose sole failure mode is a
      # changeset) is normalised to `{:error, %Ecto.Changeset{}}`. Matching a
      # changeset explicitly keeps the compile-gate `run_post/3` has: if
      # `Audit.log_in_multi/3` ever fails with a non-changeset value, dialyzer fails
      # the build here rather than silently mis-mapping it.
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # A concurrent duplicate claim raises a UNIQUE violation Ecto surfaces as a
  # `:unique` constraint error on the changeset (declared as
  # `unique_constraint(:ref, name: :channel_claims_ref_uidx)`). Detect it by the
  # constraint kind so a validation error (over-length/NUL `ref`) is NOT misread as
  # `:already_claimed`.
  defp already_claimed?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  # An INSERT-to-claim lost the (tenant_id, project_id, ref) unique index. That is
  # EITHER a genuine racing loser (a PEER already owns the slot) OR the TRUE OWNER
  # re-claiming after a lost response (a dropped 201 / MCP timeout — the insert
  # committed but the caller never saw the reply). Disambiguate by reading the winning
  # row: an ACTIVE (done_at IS NULL) claim held by THIS caller is an idempotent owner
  # re-claim, so return {:ok, existing} — the owner keeps the handoff it actually
  # holds instead of being falsely told "another agent owns this, move on" and
  # abandoning it until the lease expires. Anything else (a peer's claim, a
  # since-released/gone row, or the caller's OWN already-DONE claim) is a real
  # collision -> {:error, :already_claimed} (409).
  #
  # No new TOCTOU window: the unique index still enforces exactly-once at INSERT time;
  # this read runs AFTER the failed insert only to CLASSIFY the loser, never to decide
  # whether to insert. A rare concurrent release between the insert and this read
  # yields a nil lookup -> a safe 409 (the caller retries), never a dropped handoff.
  defp resolve_claim_collision(tenant_id, project_id, agent_id, ref) do
    now = DateTime.utc_now()

    case fetch_claim_by_ref(tenant_id, project_id, ref) do
      %ChannelClaim{claimant_agent_id: ^agent_id, done_at: nil, lease_expires_at: lease} =
          existing ->
        if DateTime.compare(lease, now) == :gt do
          {:ok, existing}
        else
          # Expired lease: the owner is re-claiming a dead handoff. Treat as a real
          # collision so the caller learns the ref is NOT held. Discovery agrees — it
          # LISTS the row (it still holds the unique slot) and flags it `expired`, so
          # the caller is told to retry once the sweeper reaps it, not to move on.
          {:error, :already_claimed}
        end

      _ ->
        {:error, :already_claimed}
    end
  end

  # Fetch the winning claim for a ref by its (tenant_id, project_id, ref) unique key.
  # tenant_id/project_id are already validated UUIDs (claim/5 resolved the project) and
  # ref is the normalized changeset value, so no valid_uuid?/is_binary guards are
  # needed here (unlike fetch_owned_claim/4, which takes raw path segments).
  defp fetch_claim_by_ref(tenant_id, project_id, ref) do
    ChannelClaim
    |> where(
      [c],
      c.tenant_id == ^tenant_id and c.project_id == ^project_id and c.ref == ^ref
    )
    |> AdminRepo.one()
  end

  # Reject claiming a ref whose newest live post is already superseded — the ref
  # points to stale instructions that have been retired. This prevents an agent
  # from claiming a handoff whose correction already exists (US-454 defect 3).
  #
  # QUARANTINED posts are excluded (issue #499), like every other consumer: a
  # quarantined post is invisible to `recent_page/3`, `directed_handoffs_page/3` and
  # `get_post/2`, so letting one still permit or block a claim would let an agent claim a
  # ref whose instructions it can no longer fetch — and the quarantine's `expires_at`
  # extension would lengthen exactly that window.
  defp verify_ref_not_superseded(tenant_id, project_id, ref) do
    now = DateTime.utc_now()

    newest =
      ChannelPost
      |> where(
        [p],
        p.tenant_id == ^tenant_id and p.project_id == ^project_id and
          p.key == ^ref and p.expires_at > ^now and is_nil(p.quarantined_at)
      )
      |> order_by([p], desc: p.inserted_at, desc: p.seq)
      |> limit(1)
      |> AdminRepo.one()

    case newest do
      %ChannelPost{superseded_by: nil} -> :ok
      %ChannelPost{} -> {:error, :already_claimed}
      nil -> :ok
    end
  end

  # Reject claiming when the agent already holds the maximum allowed concurrent
  # open claims on this project — prevents mass-squatting of every handoff.
  defp verify_agent_claim_budget(tenant_id, project_id, agent_id) do
    now = DateTime.utc_now()

    count =
      ChannelClaim
      |> where(
        [c],
        c.tenant_id == ^tenant_id and c.project_id == ^project_id and
          c.claimant_agent_id == ^agent_id and is_nil(c.done_at) and
          c.lease_expires_at > ^now
      )
      |> AdminRepo.aggregate(:count)

    if count >= @max_concurrent_open_claims do
      {:error, :already_claimed}
    else
      :ok
    end
  end

  # Invalidate any open claims on a superseded target's ref so the successor is
  # immediately visible for claiming (US-454 defect 3: a same-key successor
  # blocked by an active claim on the predecessor's ref).
  defp invalidate_open_claims_on_supersede(repo, %ChannelPost{key: key} = target)
       when is_binary(key) do
    import Ecto.Query

    from(c in ChannelClaim,
      where:
        c.tenant_id == ^target.tenant_id and
          c.project_id == ^target.project_id and
          c.ref == ^key and
          is_nil(c.done_at)
    )
    |> repo.delete_all()
  end

  defp invalidate_open_claims_on_supersede(_repo, _target), do: nil

  # done (Multi.update) / release (Multi.delete) + audit in ONE transaction so the
  # lifecycle transition stays accountable. `record` is the changeset (update) or the
  # struct (delete); `action` is the audit action ("done"/"released").
  defp run_claim_lifecycle(tenant_id, project_id, agent_id, op, record, action, audit) do
    multi =
      Multi.new()
      |> apply_claim_op(op, record)
      |> Audit.log_in_multi(:audit, fn %{claim: claim} ->
        claim_audit_attrs(tenant_id, project_id, agent_id, claim, action, audit)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{claim: claim}} -> {:ok, claim}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  rescue
    # Concurrent double-release/done. `fetch_owned_claim/4` is an UNLOCKED read, so
    # between it and the update/delete the row can vanish (the owner double-acting,
    # or the sweep reaping a done/expired row). The losing op matches 0 rows and Ecto
    # raises `Ecto.StaleEntryError`; a just-gone claim is nonexistent, so collapse the
    # race to the SAME idempotent `{:error, :not_found}` a missing claim returns —
    # never a 500 (mirrors `run_delete/5`).
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  defp apply_claim_op(multi, :update, changeset), do: Multi.update(multi, :claim, changeset)
  defp apply_claim_op(multi, :delete, struct), do: Multi.delete(multi, :claim, struct)

  defp claim_audit_attrs(tenant_id, project_id, agent_id, claim, action, audit) do
    %{
      tenant_id: tenant_id,
      project_id: project_id,
      entity_type: "channel_claim",
      entity_id: claim.id,
      action: action,
      actor_type: Keyword.get(audit, :actor_type, "api_key"),
      actor_id: Keyword.get(audit, :actor_id),
      actor_label: Keyword.get(audit, :actor_label),
      metadata:
        audit
        |> Keyword.get(:metadata, %{})
        |> Map.merge(%{"ref" => claim.ref, "claimant_agent_id" => agent_id})
    }
  end

  # Clamp the caller's `:lease_seconds` into [1, @max_lease_seconds]; a nil/garbage
  # value falls back to @default_lease_seconds. Accepts an integer or an integer
  # string (the HTTP/MCP param arrives as a string).
  defp normalize_lease_seconds(seconds) when is_integer(seconds) and seconds > 0,
    do: min(seconds, @max_lease_seconds)

  defp normalize_lease_seconds(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {n, ""} -> normalize_lease_seconds(n)
      _ -> @default_lease_seconds
    end
  end

  defp normalize_lease_seconds(_), do: @default_lease_seconds

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
    # delete reaches `run_delete/5` (whose `{:ok, _}` / `:audit_write_failed`
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
  Lists the tenant's QUARANTINED posts — the operator review read (issue #499).

  Quarantine is deliberately not a delete because the denylist is a prefix HEURISTIC and
  a false positive must be recoverable. That only holds if a human can actually SEE the
  flagged rows: every ordinary read (`recent_page/3`, `directed_handoffs_page/3`,
  `get_post/2`) hides them, and the `:secret_detected` anomaly + audit entry carry FIELD
  NAMES only. This is the one read that resolves them, so an operator can judge true vs
  false positive and then either redact (`delete_post/5`) or exonerate
  (`release_post/5`) — without direct DB access.

  It returns the FULL body (that IS the artifact under review), which is why the endpoint
  is `role: :user`, not the agent-role coordination surface.

  Tenant-scoped on `AdminRepo` (BYPASSRLS) with the explicit tenant filter this module
  mandates. Newest-quarantine-first. Opts: `:project_id` (optional filter — a malformed
  value yields an empty list, never a cast error) and `:limit`
  (default #{@quarantined_default_limit}, clamped to #{@quarantined_max_limit}).
  """
  @spec list_quarantined_posts(term(), keyword()) :: [ChannelPost.t()]
  def list_quarantined_posts(tenant_id, opts \\ []) do
    if valid_uuid?(tenant_id) do
      ChannelPost
      |> where([p], p.tenant_id == ^tenant_id and not is_nil(p.quarantined_at))
      |> apply_quarantined_project(Keyword.get(opts, :project_id))
      |> order_by([p], desc: p.quarantined_at, desc: p.seq)
      |> limit(^quarantined_limit(Keyword.get(opts, :limit)))
      |> AdminRepo.all()
    else
      []
    end
  end

  defp apply_quarantined_project(query, nil), do: query

  defp apply_quarantined_project(query, project_id) do
    if valid_uuid?(project_id) do
      where(query, [p], p.project_id == ^project_id)
    else
      # A malformed project filter must never widen the read to the whole tenant, and
      # must never raise a CastError — return nothing.
      where(query, [p], false)
    end
  end

  @doc """
  Default page size for `list_quarantined_posts/2` — the single source of truth shared
  with the endpoint's `meta.limit`, so the two can never drift.
  """
  @spec quarantined_default_limit() :: pos_integer()
  def quarantined_default_limit, do: @quarantined_default_limit

  @doc """
  The EFFECTIVE page size `list_quarantined_posts/2` will apply for a requested `limit`
  (default #{@quarantined_default_limit}, clamped to #{@quarantined_max_limit}; anything
  not a positive integer falls back to the default).

  Public because the endpoint must report the CLAMPED value in `meta.limit`, not the
  requested one: reporting `limit: 1000` while returning at most 100 rows (or `limit: 0`
  / `limit: -5` while returning 25) is exactly the drift `quarantined_default_limit/0`
  exists to prevent.
  """
  @spec quarantined_limit(term()) :: pos_integer()
  def quarantined_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @quarantined_max_limit)

  def quarantined_limit(_), do: @quarantined_default_limit

  @doc """
  RELEASES a quarantined post — the operator's exoneration path (issue #499).

  The counterpart to `delete_post/5`: redact when the flag was RIGHT, release when it was
  WRONG. Without it, the only remedy for a false positive is the destructive one that
  quarantine-over-delete was chosen to avoid.

  Clears `quarantined_at`/`quarantine_reason` (so every read surfaces the post again) and
  stamps `quarantine_released_at`, which removes the row from the rescan candidate set for
  the denylist revision the operator judged it against — otherwise the next run, under the
  SAME patterns that flagged it, would re-quarantine it within the hour and the release
  would be cosmetic. The exemption is revision-SCOPED, not permanent: a later denylist
  revision bump makes a released row a candidate again, since that revision may add a
  wholly unrelated credential shape the row does carry.

  Tenant-scoped and ORACLE-SAFE exactly like `delete_post/5`: a malformed, nonexistent,
  foreign-tenant, NOT-quarantined, or UNAUTHORIZED id all return `{:error, :not_found}` —
  byte-identical.

  Authorization is enforced HERE as well as at the route (`role: :user`), mirroring
  `delete_post/5`'s in-context `authorized_to_delete?/3`: releasing un-hides a post the
  security rescan flagged AND exempts it from the rescan for the current denylist
  revision, so it must not have LESS defence in depth than the redaction path. `role` is
  the caller's VERIFIED key role (never client-supplied) and must be `>= :user`; a
  non-HTTP caller (Oban worker, mix task, a new controller action that forgets the plug)
  therefore cannot perform an unauthorized release. `agent_id` is the caller's
  server-stamped identity, recorded in the audit entry.

  The update and its audit entry (`entity_type: "channel_post"`, action
  `"quarantine_released"`, carrying the cleared reason) run in ONE transaction, so an
  exoneration is as accountable as the detection that preceded it.
  """
  @spec release_post(term(), term(), atom(), term(), keyword()) ::
          {:ok, ChannelPost.t()} | {:error, :not_found | :audit_write_failed}
  def release_post(tenant_id, agent_id, role, post_id, audit \\ []) do
    with true <- valid_uuid?(tenant_id) and valid_uuid?(post_id),
         true <- Role.role_at_least?(role, :user),
         %ChannelPost{quarantined_at: %DateTime{}} = post <- fetch_owned_post(tenant_id, post_id) do
      run_release(tenant_id, agent_id, post, audit)
    else
      _ -> {:error, :not_found}
    end
  end

  defp run_release(tenant_id, releaser_agent_id, %ChannelPost{} = post, audit) do
    reason = post.quarantine_reason

    multi =
      Multi.new()
      |> Multi.update(
        :post,
        ChannelPost.release_changeset(post, DateTime.utc_now(), @retention_days)
      )
      |> Audit.log_in_multi(:audit, fn %{post: released} ->
        %{
          tenant_id: tenant_id,
          project_id: released.project_id,
          entity_type: "channel_post",
          entity_id: released.id,
          action: "quarantine_released",
          actor_type: Keyword.get(audit, :actor_type, "api_key"),
          actor_id: Keyword.get(audit, :actor_id),
          actor_label: Keyword.get(audit, :actor_label),
          # FIELD NAMES only, carried over from the quarantine — never the value.
          metadata: %{
            "cleared_reason" => reason,
            "author_agent_id" => released.agent_id,
            "released_by_agent_id" => releaser_agent_id
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{post: released}} -> {:ok, released}
      {:error, _step, _reason, _changes} -> {:error, :audit_write_failed}
    end
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
        # Issue #499: a QUARANTINED post is invisible to every READ (the by-id read
        # included — otherwise a flagged credential is still one GET away, and
        # graduate/2 could promote it into the durable wiki). The DELETE path
        # deliberately still resolves it through `fetch_owned_post/2`, so an operator
        # can redact a quarantined post.
        %ChannelPost{quarantined_at: %DateTime{}} -> {:error, :not_found}
        post -> {:ok, post}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Graduates ONE coordination post into the durable Knowledge wiki (US-40.E1).

  This is the CONTENT-SELECTIVE promotion of a genuinely reusable finding that has
  no external tracker — NOT the general handoff-durability answer. A transient
  "run this SQL" directive is left to expire (the 30-day TTL sweep reclaims it); a
  reusable lesson graduates. There is NO automatic graduation — this is only ever
  an explicit, deliberate agent call.

  The orchestration lives HERE (not the controller) so the module boundary owns
  the multi-context sequence, and it REUSES Knowledge's existing guardrails rather
  than bypassing them:

    1. `get_post/2` — tenant-scoped, oracle-safe fetch (foreign-tenant /
       nonexistent / malformed id all collapse to `{:error, :not_found}`).
    2. `project_writable_by_agent/4` — the SHARED project-membership gate
       (US-40.D3): a non-member agent graduating a sibling-project post is denied
       identically to a not-found (`{:error, :not_found}`), no oracle. Elevated
       roles (`>= :user`) bypass, matching the redact/claim surfaces.
    3. `SecretDenylist.contains_secret?/1` over BOTH the caller-supplied title and
       the post body BEFORE proposing — neither `propose_article/3` nor
       `create_article/3` runs a secret scan, so this explicit step is what stops a
       credential being smuggled from the coordination plane into the durable plane
       (both title and body land in the tenant-wide-readable knowledge plane). A hit
       returns `{:error, :unprocessable_entity, msg}` (→ 422) and nothing lands.
    4. `Loopctl.Knowledge.propose_article/3` — the SEMANTIC NOVELTY gate (never
       `create_article/3` directly). A near-duplicate returns
       `%{verdict: :duplicate, article: existing, created: false}` and creates
       nothing, so a single-use / duplicate finding does not pollute the wiki.

  Provenance (AC-40.E1.3): the article carries `source_type: "channel_graduation"`
  and `source_id` = the originating post id, attributed to the graduating agent
  via the caller's audit context.

  The source post is KEPT — the 30-day TTL sweep reclaims it (there is no
  `graduated` column on `channel_posts`); the author may separately redact it via
  the DELETE path.

  Returns the `propose_article/3` result unchanged on success, or `{:error,
  :not_found}` / `{:error, :unprocessable_entity, msg}` from the gates above, or a
  forwarded `{:error, :duplicate_title, %Article{}}` / `{:error,
  %Ecto.Changeset{}}` (e.g. a missing required title). Because propose is called
  with `on_gate_unavailable: :skip`, an embedding-backend outage returns `{:error,
  :gate_unavailable}` WITHOUT creating an un-deduplicated article (retry once the
  gate can assess) — matching the reviewed Memory graduation posture.
  """
  @spec graduate_post(Ecto.UUID.t(), Ecto.UUID.t(), atom(), term(), map()) ::
          {:ok, map()}
          | {:error, :not_found}
          | {:error, :agent_not_found}
          | {:error, :unprocessable_entity, String.t()}
          | {:error, :duplicate_title, Knowledge.Article.t()}
          | {:error, :gate_unavailable}
          | {:error, Ecto.Changeset.t()}
  def graduate_post(tenant_id, agent_id, role, post_id, %{} = params) do
    with {:ok, post} <- get_post(tenant_id, post_id),
         # Restore the agent-in-tenant binding that the membership probe used to give
         # for free (review). `project_writable_by_agent/4` no longer implies it on the
         # kb path — `kb_scope?/2` ignores `agent_id` entirely (#517), so a misconfigured
         # key carrying a foreign-tenant `agent_id` (the agents/api_keys FKs are
         # non-composite, see the comment at post/4) could otherwise graduate a kb post
         # whose article carries a foreign agent's `visibility_agent_id`. Mirroring the
         # sibling post/4 and claim/4 defense-in-depth closes that mis-attribution class.
         {:ok, _agent} <- agent_owned(tenant_id, agent_id),
         :ok <- project_writable_by_agent(tenant_id, agent_id, post.project_id, role),
         :ok <- scan_graduation_content(params[:title], post.body, params[:tags]) do
      attrs = %{
        title: params[:title],
        body: post.body,
        # A graduated post is a reusable FINDING by default (the durable home for a
        # lesson with no external tracker); an explicit `category` may override it.
        category: params[:category] || :finding,
        # PUBLISHED, not draft: knowledge_search/knowledge_context return PUBLISHED
        # articles only, and the novelty gate assesses only the published corpus — so a
        # draft graduation would be invisible AND would never dedup a sibling graduation,
        # the exact wiki-pollution AC-40.E1 prevents. This mirrors the reviewed
        # memory→knowledge precedent (Memory.memory_to_article_attrs/2). The novelty gate
        # may still downgrade to :draft on a :low_novelty verdict — the ONE intended
        # unpublished outcome (the human-review queue).
        status: :published,
        project_id: post.project_id,
        # `articles.tags` is NOT NULL (schema default []); casting an explicit nil
        # overrides that default and 500s the insert, so a tag-less graduation must
        # coalesce to [] here rather than pass nil through.
        tags: params[:tags] || [],
        source_type: "channel_graduation",
        source_id: post.id,
        scope: :tenant
      }

      Knowledge.propose_article(tenant_id, attrs, propose_opts(agent_id, role, params))
    end
  end

  # Build the opts passed to `Knowledge.propose_article/3`, mirroring the reviewed
  # sibling graduation paths (ArticleController.create + Memory graduation):
  #
  #   * `:visibility_agent_id` for AGENT-role callers (= the caller's agent id, #163).
  #     The novelty-gate dedup assesses against the published corpus; WITHOUT a
  #     visibility scope its near-neighbor pool would include OTHER agents' private/
  #     owner memory articles, and a `:duplicate` verdict re-fetches + echoes that
  #     article's id/title/status back to the caller — a cross-agent oracle. Scoping
  #     the pool (and the canonical_neighbor re-fetch) to the caller's own visibility
  #     closes the boundary #163 isolates. Higher roles (orchestrator/user/superadmin)
  #     are trusted/observability and see everything, so no filter is applied — parity
  #     with `LoopctlWeb.Helpers.Visibility.scope_opts/1`.
  #   * `on_gate_unavailable: :skip` — automated graduation must NOT fall open and
  #     inject an un-deduplicated published article during an embedding outage; it
  #     returns `{:error, :gate_unavailable}` so the caller retries once embeddings
  #     recover. Matches the reviewed Memory graduation posture (Memory.propose_opts/2).
  # `on_low_novelty: :skip` for the same reason as `Memory.propose_opts/2`: channel-post
  # graduation is an UNATTENDED writer, so the gate's `:draft` default produces articles
  # nobody will ever publish. `propose_article/3`'s own comment names this failure, and it
  # was measured — 26 stranded drafts, seven producers, zero automatic consumers. A
  # low-novelty proposal means the knowledge is already published somewhere; skipping loses
  # only the duplicate.
  defp propose_opts(agent_id, role, params) do
    (params[:audit] || [])
    |> Keyword.put(:on_gate_unavailable, :skip)
    |> Keyword.put(:on_low_novelty, :skip)
    |> Keyword.merge(visibility_opts(agent_id, role))
  end

  defp visibility_opts(agent_id, :agent), do: [visibility_agent_id: to_string(agent_id)]
  defp visibility_opts(_agent_id, _role), do: []

  # Explicit secret scan over the caller-supplied title, the caller-supplied tags, and
  # the post body BEFORE they reach Knowledge. Neither propose_article/3 nor
  # create_article/3 scans, so this is the ONLY thing keeping a credential out of the
  # durable, tenant-wide-readable knowledge plane on this path. The title AND tags are
  # caller-supplied and brand-new at graduation (channel_posts carry no tags, so tags
  # never passed the creation-path denylist), and they land in the durable plane just
  # like the body — a token-shaped tag (e.g. a PAT/AWS key/Slack token, all of which fit
  # Article's `^[A-Za-z0-9_-]+$` tag pattern) is the adjacent smuggling vector, so tags
  # are scanned too. A hit is an explicit 422 rejection, never a silent drop.
  defp scan_graduation_content(title, body, tags) do
    tags_list = if is_list(tags), do: tags, else: []

    if SecretDenylist.contains_secret?(title) or SecretDenylist.contains_secret?(body) or
         Enum.any?(tags_list, &SecretDenylist.contains_secret?/1) do
      {:error, :unprocessable_entity,
       "graduation content contains a denylisted secret pattern; it cannot be graduated to the durable knowledge plane"}
    else
      :ok
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
  # `action` is the audit action the delete is recorded under. It defaults to the
  # US-39.7 redaction action ("deleted"); `unlock_file/5` overrides it so routine
  # soft-lock churn is a DISTINCT, separately-greppable event (review #451).
  defp run_delete(tenant_id, agent_id, post, audit, action \\ "deleted") do
    multi =
      Multi.new()
      |> Multi.delete(:post, post)
      |> Audit.log_in_multi(:audit, fn %{post: deleted} ->
        delete_audit_attrs(tenant_id, agent_id, deleted, audit, action)
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
      # the compile-gate `run_delete/5` had: if `Audit.log_in_multi/3` is ever
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

  defp delete_audit_attrs(tenant_id, agent_id, post, audit, action) do
    %{
      tenant_id: tenant_id,
      project_id: post.project_id,
      entity_type: "channel_post",
      entity_id: post.id,
      action: action,
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
  defp run_post(tenant_id, changeset, audit, supersedes, retries_left \\ 1)

  # `retries_left` bounds the idempotency-recovery re-attempt (see
  # `resolve_idempotency_collision/5`): a hard-delete of the winning row between the
  # failed insert and the recovery SELECT frees the idempotency slot, so we re-run
  # the append ONCE (budget 1) rather than bounce a misleading non-retryable 422.
  defp run_post(tenant_id, changeset, audit, supersedes, retries_left) do
    key = Ecto.Changeset.get_field(changeset, :key)
    insert_opts = insert_opts(key)

    multi =
      Multi.new()
      |> Multi.insert(:post, changeset, insert_opts)
      |> secret_guard_step()
      |> maybe_supersede_step(supersedes)
      |> Audit.log_in_multi(:audit_post, fn %{post: post} ->
        audit_attrs(tenant_id, post, post_outcome(post), audit, changeset, supersedes)
      end)
      |> maybe_supersede_audit_step(tenant_id, supersedes, audit)

    case AdminRepo.transaction(multi) do
      {:ok, %{post: post}} ->
        {:ok, post, post_outcome(post)}

      {:error, :post, %Ecto.Changeset{} = failed, _changes} ->
        if idempotency_conflict?(failed) do
          resolve_idempotency_collision(
            tenant_id,
            failed,
            changeset,
            audit,
            supersedes,
            retries_left
          )
        else
          tap_secret_blocked({:error, failed})
        end

      {:error, :secret_guard, {:persisted_secret, post, fields}, _changes} ->
        # The STRONGEST leak signal in the module — the credential is PROVEN present on a
        # persisted row, not merely present in incoming attrs — so it must raise the same
        # `[:loopctl, :coordination, :secret_blocked]` counter the write-time rejection
        # does. Without it the security counter under-reports exactly the confirmed cases.
        ChannelPost.emit_secret_blocked_fields(post, fields)
        {:error, :unprocessable_entity, @persisted_secret_message}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  rescue
    # Concurrent redact of the supersede target (US-39.7). The target was fetched
    # OUTSIDE the transaction by `fetch_supersede_target/5`; between that unlocked
    # read and the `repo.update/2` in `maybe_supersede_step/2` the row can be hard-
    # deleted. Ecto raises `Ecto.StaleEntryError`; collapse to the same clean error
    # a nonexistent target returns — never a 500. Mirrors `run_delete/5` and
    # `run_claim_lifecycle/7`.
    Ecto.StaleEntryError -> {:error, :supersede_target_not_found}
  end

  # POST-WRITE INVARIANT (issue #499): no row may be left PERSISTED carrying a
  # denylisted credential shape in ANY scanned field. `create_changeset/2` gates the
  # INCOMING attrs, which covers every fresh insert — but a keyed UPSERT is a merge:
  # `body`/`refs` are replaced, while `host` is set-once and `to_host`/`to_capability`
  # are preserve-on-omit (COALESCE). So a slot quarantined for a credential in one of
  # those PRESERVED fields would have its quarantine cleared by the ON CONFLICT DO
  # UPDATE (which cannot know WHICH field was dirty) while the credential is still
  # there — re-exposing it. Re-running the SHARED scan (`ChannelPost.secret_fields/1`,
  # the same primitive and the same bounds as the write-time gate) over the PERSISTED
  # row closes that: a dirty preserved field rolls the whole transaction back, so the
  # slot keeps its quarantine and the caller gets an honest 422 naming the remedy,
  # instead of a silent re-publication. On every ordinary write this is a bounded,
  # already-clean scan that always passes.
  defp secret_guard_step(multi) do
    Multi.run(multi, :secret_guard, fn _repo, %{post: post} ->
      case ChannelPost.secret_fields(post) do
        [] -> {:ok, :clean}
        fields -> {:error, {:persisted_secret, post, fields}}
      end
    end)
  end

  # US-454 (defect 3): when the post declares `supersedes: <target>`, mark the
  # target retired IN THE SAME TRANSACTION as the insert/upsert, so a handoff
  # and its successor can never be half-visible (a crash between two writes
  # would leave the stale one looking live). The target was already authorized
  # and scope-checked by `fetch_supersede_target/5`. A self-supersede — only
  # reachable on the keyed UPSERT path, where the persisted slot row's id can
  # equal the target id the caller passed — is rejected as a changeset error so
  # it flows through the existing `{:error, _step, %Ecto.Changeset{}, _}`
  # normalisation (→ 422) instead of introducing a new error shape.
  defp maybe_supersede_step(multi, nil), do: multi

  defp maybe_supersede_step(multi, %ChannelPost{} = target) do
    Multi.run(multi, :supersede, fn repo, %{post: post} ->
      cond do
        target.id == post.id ->
          {:error,
           target
           |> Ecto.Changeset.change()
           |> Ecto.Changeset.add_error(:superseded_by, "cannot supersede itself")}

        not is_nil(target.superseded_by) ->
          {:error,
           target
           |> Ecto.Changeset.change()
           |> Ecto.Changeset.add_error(:superseded_by, "target is already superseded")}

        true ->
          invalidate_open_claims_on_supersede(repo, target)

          target
          |> Ecto.Changeset.change(superseded_by: post.id)
          |> repo.update()
      end
    end)
  end

  # When a post supersedes another, write a SECOND audit entry for the target
  # retirement so the audit trail records the mutation (not just the new post).
  defp maybe_supersede_audit_step(multi, _tenant_id, nil, _audit), do: multi

  defp maybe_supersede_audit_step(multi, tenant_id, %ChannelPost{} = target, audit) do
    Audit.log_in_multi(multi, :audit_supersede, fn %{post: post} ->
      %{
        tenant_id: tenant_id,
        project_id: target.project_id,
        entity_type: "channel_post",
        entity_id: target.id,
        action: "superseded",
        actor_type: Keyword.get(audit, :actor_type, "api_key"),
        actor_id: Keyword.get(audit, :actor_id),
        actor_label: Keyword.get(audit, :actor_label),
        metadata: %{"successor_id" => post.id}
      }
    end)
  end

  # A KEYLESS idempotent write lost the
  # `(tenant_id, project_id, agent_id, idempotency_key)` partial unique index.
  # Detect it by the constraint kind + name so a non-idempotency unique violation
  # (the keyed working-state slot) or a validation error is NOT misread as a dedup.
  defp idempotency_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "channel_posts_idempotency_uidx"
    end)
  end

  # Resolve a lost idempotency insert to the EXISTING row and report it as a
  # `:deduplicated` outcome (the third documented `post/4` result). The scope
  # fields are the SERVER-STAMPED struct values (tenant_id/project_id/agent_id) plus
  # the normalized changeset `idempotency_key` — never client-echoed.
  #
  # The nil case is a rare double race: the winning row was HARD-deleted (US-39.7)
  # between the failed insert and this recovery SELECT. That is NOT a duplicate and
  # NOT bad input — the idempotency slot is now FREE, so the caller's append would
  # succeed on a fresh insert. Returning the raw changeset here would surface a
  # NON-retryable 422 ("has already been used") that MCP/HTTP clients don't retry,
  # silently losing the append and lying about the token being taken. Instead we
  # RE-RUN the append once (`retries_left`), which either lands cleanly or — if a
  # concurrent writer re-took the slot in the meantime — re-collides and dedups to
  # THAT row. Only if the slot keeps churning past the budget do we return a
  # retryable `{:error, :conflict}` (→ 409), an honest "transient race, retry"
  # signal rather than a misleading 422. `original_changeset` is the pre-failure
  # changeset (the `failed` one carries the added unique-constraint error), reused to
  # rebuild a fresh insert Multi.
  defp resolve_idempotency_collision(
         tenant_id,
         %Ecto.Changeset{} = failed,
         %Ecto.Changeset{} = original_changeset,
         audit,
         supersedes,
         retries_left
       ) do
    project_id = Ecto.Changeset.get_field(failed, :project_id)
    agent_id = Ecto.Changeset.get_field(failed, :agent_id)
    idempotency_key = Ecto.Changeset.get_field(failed, :idempotency_key)

    case get_post_by_idempotency_key(tenant_id, project_id, agent_id, idempotency_key) do
      # Issue #499: the row holding this token was QUARANTINED (it carries a credential
      # shape under the current denylist) and is hidden from every read. Reporting
      # `:deduplicated` would tell the caller "your post is on the channel" about a row
      # nobody can see — the same silent black hole the keyed-slot upsert avoids, except
      # here the stored content is provably DIRTY, so it cannot simply be released.
      # Fail LOUDLY instead, mirroring the write-time gate's contract (the caller learns
      # the information did not land) and name the remedy.
      %ChannelPost{quarantined_at: %DateTime{}} = quarantined ->
        # A confirmed credential-leak attempt against a row already proven dirty: raise
        # the SAME security counter the write-time rejection does, or the signal
        # under-reports repeated attempts on exactly the worst case.
        ChannelPost.emit_secret_blocked_fields(quarantined, blocked_fields(quarantined))
        {:error, :unprocessable_entity, @quarantined_idempotency_message}

      %ChannelPost{} = existing ->
        {:ok, existing, :deduplicated}

      nil when retries_left > 0 ->
        run_post(tenant_id, original_changeset, audit, supersedes, retries_left - 1)

      nil ->
        {:error, :conflict}
    end
  end

  # Look up a post by its `(tenant_id, project_id, agent_id, idempotency_key)`
  # scope — the exact columns of `channel_posts_idempotency_uidx` — on `AdminRepo`
  # (BYPASSRLS) with the EXPLICIT tenant filter the module mandates. Mirrors
  # `Knowledge.get_article_by_idempotency_key/3` and `fetch_claim_by_ref/3`. Only a
  # binary key ever matched the index, so a non-binary key never resolves.
  defp get_post_by_idempotency_key(tenant_id, project_id, agent_id, key) when is_binary(key) do
    ChannelPost
    |> where(
      [p],
      p.tenant_id == ^tenant_id and p.project_id == ^project_id and
        p.agent_id == ^agent_id and p.idempotency_key == ^key
    )
    |> AdminRepo.one()
  end

  defp get_post_by_idempotency_key(_tenant_id, _project_id, _agent_id, _key), do: nil

  # The fields to attribute a quarantined row's blocked write to. Re-derived from the
  # CURRENT patterns; a row quarantined under a pattern that has since been removed no
  # longer trips the scan, so fall back to the dedup dimension the caller actually
  # collided with rather than emitting nothing.
  defp blocked_fields(%ChannelPost{} = post) do
    case ChannelPost.secret_fields(post) do
      [] -> [:idempotency_key]
      fields -> fields
    end
  end

  # Keyless posts are always a new append-only row. A keyed post UPSERTS on the
  # LIVE PARTIAL unique index (`... WHERE key IS NOT NULL`, index
  # `channel_posts_session_key_uidx`). Postgres cannot INFER a partial index from a
  # bare column list — the ON CONFLICT must carry the matching predicate — so the
  # conflict_target is an unsafe_fragment mirroring the index columns AND its WHERE
  # clause (same pattern as memory.ex:2729). `agent_id` participates so a spoofed
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
  # Issue #499: the DO UPDATE also CLEARS the quarantine bookkeeping
  # (`quarantined_at`/`quarantine_reason`/`quarantine_released_at`/`rescanned_at`).
  # Without it, a quarantined keyed slot is a permanent BLACK HOLE: the partial unique
  # index does not exclude quarantined rows, so the single most likely remediation —
  # the same agent+session reposting that key WITHOUT the credential — takes DO UPDATE,
  # returns 200 with `:updated`, and the row stays hidden from `recent_page/3`,
  # `directed_handoffs_page/3` and `get_post/2` forever, carrying a
  # `quarantine_reason` that describes content no longer present. Clearing is safe
  # BECAUSE the incoming write already passed the write-time denylist gate in
  # `create_changeset/2` — it is provably clean under the CURRENT pattern set, which is
  # exactly the standard the rescan applies. `rescanned_at` is nulled (not stamped) so
  # the new content is re-examined on the next rescan, and the operator's release marker
  # is cleared with it so an exonerated slot never becomes a permanently scan-exempt
  # channel for later content.
  defp keyed_slot_on_conflict do
    from(p in ChannelPost,
      update: [
        set: [
          body: fragment("EXCLUDED.body"),
          refs: fragment("EXCLUDED.refs"),
          to_host: fragment("COALESCE(EXCLUDED.to_host, ?)", p.to_host),
          to_capability: fragment("COALESCE(EXCLUDED.to_capability, ?)", p.to_capability),
          updated_at: fragment("EXCLUDED.updated_at"),
          expires_at: fragment("EXCLUDED.expires_at"),
          quarantined_at: fragment("NULL::timestamptz"),
          quarantine_reason: fragment("NULL::text"),
          quarantine_released_at: fragment("NULL::timestamptz"),
          rescanned_at: fragment("NULL::timestamptz")
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

  defp audit_attrs(tenant_id, post, outcome, audit, changeset, supersedes) do
    metadata =
      Keyword.get(audit, :metadata, %{})
      |> maybe_put("supersedes_target_id", if(supersedes, do: supersedes.id))
      |> maybe_put("key_source", Ecto.Changeset.get_field(changeset, :key_source))
      |> maybe_put("session_id_source", Ecto.Changeset.get_field(changeset, :session_id_source))

    %{
      tenant_id: tenant_id,
      project_id: post.project_id,
      entity_type: "channel_post",
      entity_id: post.id,
      action: if(outcome == :created, do: "posted", else: "upserted"),
      actor_type: Keyword.get(audit, :actor_type, "api_key"),
      actor_id: Keyword.get(audit, :actor_id),
      actor_label: Keyword.get(audit, :actor_label),
      metadata: metadata
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
      `count == limit`. ONE STATED EXCEPTION (review #451): advisory soft-locks are
      capped at #{@max_recent_locks} rows per page by `apply_lock_share_cap/4` in the
      newest and delta reads, and suppressed locks do NOT contribute to `has_more` —
      so on a channel with many live locks this read can return `has_more: false`
      while further live LOCK rows exist. That is deliberate (locks are the bus's
      highest-churn write and this is a recency preview), and it is why
      **a consumer that relies on lock visibility MUST read `active_locks_page/3` /
      `GET /api/v1/channel/locks`** — the dedicated pinned read — rather than
      inferring the live lock set from this one. Non-lock rows are unaffected: for
      them `has_more` is exact. TRUNCATION-DRAIN RULE (delta mode): because delta orders
      GREATEST(inserted_at, updated_at) DESC, an overflowing window truncates the
      OLDEST-touched matching rows. A consumer MUST NOT advance its `since` watermark
      while `has_more` is true — the newest-first truncation means advancing steps
      PAST the dropped older rows permanently (a lost-write gap). Instead, drain the
      backlog via the HISTORY read (`cursor:` walked to exhaustion), which returns
      every live NON-LOCK row including the truncated ones, then advance
      `since` only once a delta read returns `has_more == false`. **The drain
      guarantee covers non-lock rows only** (review #451): the entry page of a walk
      carries no cursor, so the lock share cap applies to it and can drop live locks
      that the subsequent (uncapped — see `apply_lock_share_cap/4`) cursor pages
      cannot recover, because a dropped lock may sort ABOVE the entry page's cursor.
      That is accepted rather than papered over: locks are advisory hint data with a
      <= 1h lease and a DEDICATED complete read (`active_locks_page/3` /
      `GET /api/v1/channel/locks`), which is what a consumer relying on lock
      visibility must call. (Delta mode emits no `next_cursor`, so
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

      base =
        ChannelPost
        |> where([p], p.tenant_id == ^tenant_id and p.project_id == ^project_id)
        |> where([p], p.expires_at > ^now)
        |> where([p], is_nil(p.quarantined_at))
        |> apply_since(commit_lag_since(since))
        |> apply_cursor(cursor)

      rows =
        base
        |> apply_lock_share_cap(base, since, cursor)
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

  # Bound the SHARE of one `recent_page/3` page that advisory soft-locks may occupy
  # (review #451). Locks stay on this read — AC-40.4.2 requires `channel_recent` to
  # surface them, and `channel_post_json/1` marks them distinctly — but they are the
  # bus's highest-churn write: a lock is refreshed while editing, each refresh bumps
  # `updated_at`, and the `since` DELTA ordering ranks by
  # `GREATEST(inserted_at, updated_at)`, so a refreshing fleet would repeatedly
  # re-float its locks to the top of the 25-row window and crowd out genuine
  # coordination posts and handoffs. Only the NEWEST @max_recent_locks locks in the
  # same filtered scope (same `since` window, same ordering) are admitted; the
  # complete live set is the dedicated pinned read (`active_locks_page/3`), which is
  # what a lock-visibility consumer must call — suppressed locks do NOT move
  # `has_more` here (stated on `recent_page/3`).
  #
  # Non-lock rows are never dropped — a lock displaced from this page simply frees a
  # slot for a real post. `coalesce(key, '')` keeps KEYLESS posts (NULL `key`)
  # admitted: a bare `NOT (NULL LIKE ...)` is NULL, i.e. filtered OUT, which would
  # silently drop every plain append-only message.
  #
  # NOT APPLIED IN HISTORY (`cursor:`) MODE (review #451). The cap is a RECENCY-
  # PREVIEW concern — it exists so churn cannot crowd the newest-N window — while a
  # cursor walk is a deliberate backward page through history, which the cap was
  # actively CORRUPTING: `newest_lock_ids` is computed against `base`, which already
  # carries `apply_cursor/2`, so the cap re-applied per cursor page against that
  # page's own window — a lock ranked 6th in page N's window was excluded from page N
  # AND sat above page N+1's strict `< cursor` seek, i.e. skipped permanently on
  # EVERY page. Exempting cursor mode removes that per-page re-application entirely.
  #
  # It does NOT make the walk lock-complete, and `recent_page/3`'s docstring says so
  # plainly: the ENTRY page of a walk carries no cursor, so the cap applies there and
  # a lock it drops may sort above the entry page's cursor. Locks are advisory hint
  # data with a <= 1h lease and a DEDICATED complete read — a consumer that needs the
  # live lock set calls `active_locks_page/3`, never this one.
  #
  # The lock predicate carries the SAME TTL ceiling `live_locks_scope/3` uses, so a
  # legacy `claim:`-keyed ordinary post (30-day retention, written before the
  # namespace was reserved) is treated as the ordinary post it is and never suppressed
  # from the recency preview. `@lock_key_like` stays a LITERAL so the partial index
  # is usable.
  defp apply_lock_share_cap(query, _base, _since, cursor) when not is_nil(cursor), do: query

  defp apply_lock_share_cap(query, base, since, _cursor) do
    newest_lock_ids =
      base
      |> where(
        [p],
        like(p.key, @lock_key_like) and
          p.expires_at <= datetime_add(p.updated_at, ^@max_lock_ttl_seconds, "second")
      )
      |> order_recent(since)
      |> limit(@max_recent_locks)
      |> select([p], p.id)

    where(
      query,
      [p],
      not (like(coalesce(p.key, ""), @lock_key_like) and
             p.expires_at <= datetime_add(p.updated_at, ^@max_lock_ttl_seconds, "second")) or
        p.id in subquery(newest_lock_ids)
    )
  end

  @doc """
  Directed-handoff discovery read (US-40.C1): the DEDICATED, PINNED availability
  query that surfaces DIRECTED, OPEN, UNCLAIMED handoffs to a caller — never
  interleaved into, and never truncated by, the newest-N `recent_page/3` recency
  preview.

  A handoff IS a post carrying the stable `handoff:<anchor>` key (US-40.B2), so
  the set is `key LIKE 'handoff:%'` (a left-anchored, index-served prefix — there
  is deliberately NO `kind` column). Given a caller's advisory target
  `%{host: me, capabilities: caps}`, it returns every live handoff that is:

    * addressed to the caller — `to_host = ^me` OR `to_capability = ANY(^caps)` —
      OR is a BROADCAST handoff (both `to_host` and `to_capability` NULL). The
      broadcast rule (AC-40.C1.3) is DEFAULT-INCLUDE so an unaddressed handoff is
      never orphaned: it surfaces to everyone until someone claims it. An empty
      `caps` list is safe (`in ^[]` is always false — a caller with no
      capabilities still sees its host-directed and broadcast handoffs);
    * not expired (`expires_at > now`, independent of the TTL sweep); and
    * NOT covered by an ACTIVE claim (US-40.B1). The NOT-EXISTS join key is
      `channel_claims.ref = channel_posts.key` — the handoff post's stable key IS
      the claim ref. This coupling is always sound: every `key LIKE 'handoff:%'`
      row has a non-null key by construction, so no keyless handoff can slip past
      the correlation. A claim is ACTIVE — and therefore EXCLUDES the handoff —
      when it is DONE (`done_at IS NOT NULL`, TERMINAL) OR still OPEN
      (`lease_expires_at > now`). A handoff REOPENS only when its claim was
      RELEASED (row deleted → NOT EXISTS true) or its lease EXPIRED WITHOUT
      completion (`done_at IS NULL AND lease_expires_at <= now`). A DONE handoff
      never reappears.

      TERMINAL GUARANTEE IS DURABLE (US-40.C1). Terminality is encoded via the
      presence of the DONE claim row, but that row's own retention (7d after
      `done_at`) is far shorter than the 30d post it gates — and the upsert
      FULL-REPLACE path can even RE-EXTEND a post's `expires_at`. Left naive, the
      DONE claim would be reaped while the post stayed live, reopening a ~23d window
      in which the finished handoff both reappeared here (pinned newest-first, so
      still excluded by the claim) and accepted a fresh re-claim (double-done).
      `ChannelClaimSweeper` closes this: it NEVER reaps a DONE claim while a live
      post shares its ref (`NOT EXISTS(post WHERE key = claim.ref AND expires_at >
      now)`), so the terminal signal outlives the post for its whole life. Do NOT
      decouple the sweep from post liveness — that coupling is what makes this
      sentence true.

  ## Ordering & dedup

  Pinned NEWEST-unclaimed-first (`inserted_at DESC`, `seq DESC` tie-break) so a
  REFRESHED handoff (from a new session or corrected instructions) wins over the
  stale one — the opposite of the newest-first recency read in intent, because
  the point of this set is "the most current instructions for this handoff".

  ONE row per LOGICAL handoff: the SAME `handoff:<anchor>` key fired from two
  sessions/agents is two distinct pointer rows (the keyed-slot unique index
  includes `session_id`), so the read `DISTINCT ON (key)`s them down to the newest
  pointer per key — the pinned set reflects logical handoffs, not raw pointers. See
  `directed_handoffs_page/3` for the dedup rationale and the hard-cap overflow flag.

  ## Isolation & oracle-safety

  Runs on `AdminRepo` (BYPASSRLS) with EXPLICIT `tenant_id` AND `project_id`
  filters (the module convention — a query omitting the tenant filter is a bug).
  `host`/`capabilities` are caller-supplied ADVISORY hints that filter WHAT is
  shown; they NEVER widen WHO may read — the result is always bounded to the
  caller's tenant. Do NOT authorize on them. A malformed `tenant_id`/`project_id`
  returns `[]` (the `valid_uuid?/1` guard), and a cross-tenant or nonexistent
  `project_id` naturally returns `[]` too (never a 404) — identical oracle posture
  to `recent_page/3`.

  Returns `[preview()]` — the SAME bounded read-model projection the list read
  uses (`select_preview/1` + `finalize_preview/1`), so bodies are 512-byte bounded
  previews framed as untrusted DATA, never full un-fenced bodies.
  """
  @spec directed_handoffs(term(), term(), map()) :: [preview()]
  def directed_handoffs(tenant_id, project_id, target \\ %{}) do
    {handoffs, _overflowed?} = directed_handoffs_page(tenant_id, project_id, target)
    handoffs
  end

  @doc """
  The same pinned directed-handoff read as `directed_handoffs/3`, additionally
  reporting whether the hard safety cap (`max_directed_handoffs/0`) TRUNCATED the
  set. Returns `{[preview()], overflowed?}`.

  `overflowed?` is `true` iff MORE distinct unclaimed handoffs matched than the cap
  admits. Because the set is pinned OLDEST-first, an overflow drops the NEWEST
  directed handoffs — the very rows that have been sitting longest unclaimed — so
  the caller MUST be told (the HTTP layer surfaces it as `meta.overflow`) to read the
  channel directly rather than trust a silently-truncated pinned set. Detected
  WITHOUT a second query by fetching `cap + 1` rows: more than `cap` came back ⇒
  overflow, and the extra probe row is dropped before returning.

  ## Dedup (one row per LOGICAL handoff)

  The keyed-slot unique index includes `session_id`, so the SAME `handoff:<anchor>`
  key fired from two sessions/agents (the cross-machine offline-reconcile this epic
  targets — e.g. two boxes both firing `handoff:repo#812`) is TWO distinct pointer
  rows. This read collapses them with `DISTINCT ON (key)`, keeping the NEWEST pointer
  per key, so the pinned set — and `meta.count` — reflect LOGICAL handoffs, not raw
  pointer rows. Claiming was already safe (a single claim on `ref = key` excludes
  ALL N pointers together, so no double-work); the dedup fixes the inflated/
  duplicated SURFACING only.
  """
  @spec directed_handoffs_page(term(), term(), map()) :: {[preview()], boolean()}
  def directed_handoffs_page(tenant_id, project_id, target \\ %{}) do
    if valid_uuid?(tenant_id) and valid_uuid?(project_id) do
      host = normalize_host(target)
      caps = normalize_capabilities(target)
      # US-454 (defect 2): addressing is a HINT, never a filter. The DEFAULT is
      # "see every open, unclaimed handoff on the channel" (owner requirement:
      # any session on the repo may read — and act on — any outstanding
      # handoff, so a mistyped/offline/busy addressee never strands work).
      # `only_mine: true` restores the pre-fix narrow view explicitly.
      only_mine? = Map.get(target, :only_mine, false) == true
      now = DateTime.utc_now()

      # DISTINCT ON (key) requires `key` to LEAD the ORDER BY; keeping the NEWEST
      # `(inserted_at, seq)` per key picks the most recent pointer as each handoff's
      # representative, so a refreshed handoff from a new session/process wins over
      # the stale one. `active_claim_subquery/1` correlates to this query's `:post`
      # binding via `parent_as(:post)`.
      deduped =
        from(p in ChannelPost, as: :post)
        |> where([p], p.tenant_id == ^tenant_id and p.project_id == ^project_id)
        |> where([p], like(p.key, "handoff:%"))
        |> where([p], p.expires_at > ^now)
        # Issue #499: a QUARANTINED post carries a credential shape the write-time
        # denylist missed. It must stop being surfaced anywhere — including the
        # pinned handoff set — or flagging it buys nothing.
        |> where([p], is_nil(p.quarantined_at))
        # US-454 (defect 3): a superseded handoff is RETIRED — it leaves the
        # discovery set the same way a DONE claim removes one, so a reader never
        # picks up pre-supersession instructions.
        |> where([p], is_nil(p.superseded_by))
        |> where(^handoff_visibility_filter(only_mine?, host, caps))
        |> where([p], not exists(active_claim_subquery(now)))
        |> distinct([p], p.key)
        |> order_by([p], asc: p.key, desc: p.inserted_at, desc: p.seq)

      # Re-establish the pinned OLDEST-first ordering ACROSS keys (the DISTINCT
      # ON had to order by `key` first; within a key the NEWEST pointer is the
      # representative, so a re-fired handoff shows its freshest body). The
      # across-keys pin stays OLDEST-first by design (40.C1): the work that has
      # been waiting LONGEST floats to the top, and the hard cap drops the
      # newest overflow, never the most at-risk aging handoff. Fetch `cap + 1`
      # so overflow is detectable without a second query, then trim to the cap.
      rows =
        from(row in subquery(deduped))
        |> order_by([row], asc: row.inserted_at, asc: row.seq)
        |> limit(^(@max_directed_handoffs + 1))
        |> select_preview()
        |> AdminRepo.all()
        |> Enum.map(&finalize_preview/1)
        # US-454 (defect 2): host/caps are a LABELLING input now, not a filter —
        # every row carries `directed_to_me` so the caller can sort/surface
        # without any handoff being hidden from it.
        |> Enum.map(&Map.put(&1, :directed_to_me, directed_to_me?(&1, host, caps)))

      {Enum.take(rows, @max_directed_handoffs), length(rows) > @max_directed_handoffs}
    else
      {[], false}
    end
  end

  # Correlated NOT-EXISTS subquery: an ACTIVE claim on the handoff post's key
  # (`channel_claims.ref = channel_posts.key`, same tenant/project). ACTIVE =
  # DONE (`done_at IS NOT NULL`, terminal) OR OPEN (`lease_expires_at > now`). A
  # RELEASED claim (row gone) or an expired-without-done lease is NOT active, so
  # the handoff reappears. `parent_as(:post)` correlates to the outer query's
  # `:post` binding.
  defp active_claim_subquery(now) do
    from(c in ChannelClaim,
      where:
        c.tenant_id == parent_as(:post).tenant_id and
          c.project_id == parent_as(:post).project_id and
          c.ref == parent_as(:post).key and
          (not is_nil(c.done_at) or c.lease_expires_at > ^now)
    )
  end

  # US-454 (defect 2): the addressing WHERE now applies ONLY on the explicit
  # opt-in narrow view (`only_mine: true`). The default see-everything read has
  # no addressing filter at all — a handoff addressed to another host stays
  # visible (and claimable) by every session on the channel, so a wrong/absent
  # addressee can never strand it.
  defp handoff_visibility_filter(true = _only_mine?, host, caps),
    do: directed_target_filter(host, caps)

  defp handoff_visibility_filter(_only_mine?, _host, _caps), do: dynamic([p], true)

  # Per-row advisory label (US-454 defect 2): TRUE when the handoff is a
  # broadcast (addressed to everyone, including this caller) or is directed at
  # the caller's host / one of its capabilities; FALSE when it is directed
  # elsewhere. Purely informational — the row is returned either way; callers
  # use the label to sort/surface "mine first".
  defp directed_to_me?(row, host, caps) do
    broadcast? = is_nil(row.to_host) and is_nil(row.to_capability)
    host_hit? = is_binary(host) and row.to_host == host
    cap_hit? = is_binary(row.to_capability) and row.to_capability in caps

    broadcast? or host_hit? or cap_hit?
  end

  # Compose the advisory target WHERE (US-40.C1): a handoff surfaces when it is
  # directed to the caller's host, directed to one of the caller's capabilities,
  # OR is an unaddressed BROADCAST (both target columns NULL — default-include so
  # nothing is orphaned). `host`/`caps` are already normalized; an absent host or
  # empty caps list simply drops that OR branch. Broadcast is ALWAYS included, so
  # we seed with it and OR in the present hints — keeping each clause trivial.
  # Only consulted on the opt-in `only_mine: true` narrow view (US-454).
  defp directed_target_filter(host, caps) do
    dynamic([p], is_nil(p.to_host) and is_nil(p.to_capability))
    |> or_host_filter(host)
    |> or_capabilities_filter(caps)
  end

  defp or_host_filter(filter, host) when is_binary(host),
    do: dynamic([p], p.to_host == ^host or ^filter)

  defp or_host_filter(filter, _host), do: filter

  defp or_capabilities_filter(filter, [_ | _] = caps),
    do: dynamic([p], p.to_capability in ^caps or ^filter)

  defp or_capabilities_filter(filter, _caps), do: filter

  # A blank host is "no host hint" (drops the to_host OR branch); anything
  # non-binary is ignored. Matches the blank-normalization posture of the write path.
  defp normalize_host(%{host: host}) when is_binary(host) do
    case String.trim(host) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_host(_), do: nil

  # Normalize the caller's capability hints to a clean list of non-blank strings.
  # Accepts a list (repeated query param) or a comma-joined string (the MCP/HTTP
  # convention). Anything else → []. Empty list is safe (`in ^[]` is always false).
  defp normalize_capabilities(%{capabilities: caps}) when is_list(caps) do
    caps
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_capabilities(%{capabilities: caps}) when is_binary(caps) do
    caps
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_capabilities(_), do: []

  @typedoc """
  A single LIST-read row: a bounded read-model projection (NOT a `%ChannelPost{}`).
  Carries `body_preview` (a prefix of at most `#{@preview_bytes}` bytes) + `truncated`
  instead of the full `body`, plus the attribution/addressing/timestamp fields.
  May also carry `superseded_by` (the successor post id, nil when live) and
  `directed_to_me` (boolean, present only on the handoffs read).
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
          superseded_by: Ecto.UUID.t() | nil,
          directed_to_me: boolean() | nil,
          expires_at: DateTime.t(),
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
      # US-454 (defect 3): the history read MARKS retired posts (discovery
      # excludes them; here a reader of the stale post sees its successor's id).
      superseded_by: p.superseded_by,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at,
      # Projected for EVERY preview read (review #451): without it a `channel_recent`
      # consumer cannot tell a LIVE advisory lock from an expired-but-unswept one,
      # nor render its remaining liveness — the distinctness AC-40.4.2 asks for. The
      # pinned lock read consumes the same field rather than merging its own copy.
      expires_at: p.expires_at,
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
