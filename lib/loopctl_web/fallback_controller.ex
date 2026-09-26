defmodule LoopctlWeb.FallbackController do
  @moduledoc """
  Centralized error handling for all API controllers.

  Maps error tuples and exceptions to consistent JSON error responses.
  Controllers use `action_fallback LoopctlWeb.FallbackController` to
  delegate error rendering to this module.

  ## Supported error shapes

  - `{:error, :not_found}` -> 404
  - `{:error, :unauthorized}` -> 401
  - `{:error, :forbidden}` -> 403
  - `{:error, :conflict}` -> 409
  - `{:error, :already_claimed}` -> 409 (US-40.B1: a coordination handoff ref is held by a live
    peer claim, or by the caller's own COMPLETED one — move on to another ref)
  - `{:error, :claim_lease_expired}` -> 409 (the ref's claim lease expired without completion and
    the row is awaiting the sweeper; nobody is working it, so RETRY THIS REF shortly. Split out of
    `:already_claimed` because "move on" is wrong for exactly this case — see #707)
  - `{:error, :ref_superseded}` -> 409 (the ref's newest live post has been superseded; its
    instructions were retired, so claim the successor instead)
  - `{:error, :claim_budget_exhausted}` -> 409 (the caller already holds the maximum concurrent
    open claims on this project; finish or release one first — the ref itself may well be free)
  - `{:error, :ambiguous_resolution}` -> 409 (a fuzzy identifier matched >1 active project)
  - `{:error, :must_contract_first}` -> 409 (claim before contracting)
  - `{:error, :must_claim_first}` -> 409 (start before claiming)
  - `{:error, :dependencies_not_met}` -> 409 `dependencies_not_met` (claim of a story with an unverified prerequisite)
  - `{:error, :story_held}` -> 409 (contract or claim of a story whose delivery stage is `escalated`, `done` or `failed`; an escalated one is claimable again once a human resolves it to `queued`)
  - `{:error, :stale_claim_epoch}` -> 409 (#803: the presented `claim_epoch` is not the story's current one — the caller's claim has ended)
  - `{:error, :claim_not_live}` -> 409 (US-45.1: the claim no longer accepts work — lease lapsed, review requested, or not in a claimed status)
  - `{:error, :not_claimant}` -> 409 (#803: renew-claim or escalate by a caller that is not the story's assigned agent)
  - `{:error, :not_claimed}` -> 422 (#803: renew-claim on a story that is not assigned or implementing)
  - `{:error, :lease_cap_reached}` -> 409 (#879: renew-claim on a driver-placed claim whose `claim_lease_cap` has passed; no renewal can extend it)
  - `{:error, :stale_stage}` -> 409 (#803: the delivery stage row is not where the caller believed; the CLAIM is still good, unlike `stale_claim_epoch`)
  - `{:error, :unknown_story_stage}` -> 404 (#803: the story has no `story_stages` row, so it is not in the delivery loop)
  - `{:error, :busy}` -> 503 with `Retry-After` (#803: a delivery-stage write gave up waiting on a lock; nothing was written)
  - `{:error, :invalid_transition}` -> 409 (#803: the stage machine has no such transition; the story-lifecycle `{:invalid_transition, ctx}` above is a different thing)
  - `{:error, :reason_required | :invalid_reason | :invalid_event_data | :invalid_effect | :missing_required_effect | :wrong_stage | :effect_conflict | :human_required}` -> 422 (#803: the stage machine refusing the REQUEST, `code` says which)
  - `{:error, :audit_chain_append_failed}` -> 500 (#803: the transition's chain entry did not land, so it rolled back)
  - `{:error, atom}` with no clause above -> 500, the atom LOGGED and never echoed. The last clause, and an atom only: a changeset, an `{:error, reason, message}` triple and every struct clause keep their own rendering.
  - `{:error, :self_verify_blocked}` -> 409 (same agent implemented and tries to verify)
  - `{:error, :self_report_blocked}` -> 409 (implementer tries to report their own work)
  - `{:error, :self_review_blocked}` -> 409 (implementer tries to review their own work)
  - `{:error, :missing_assigned_agent}` -> 409 (reported_done story has no assigned agent/dispatch lineage; custody chain broken)
  - `{:error, :unresolvable_dispatch_lineage}` -> 409 (a dispatch the story references — implementer, or verifier on verify — could not be resolved; custody gate failed closed on an integrity error, tenant NOT halted)
  - `{:error, :caller_lineage_required}` -> 409 (a key no dispatch minted tried to report/review/verify dispatch-minted work; a configuration refusal, tenant NOT halted)
  - `{:error, :rate_limited}` -> 429 with retry_after_seconds from header
  - `{:error, :ingestion_backlog_exceeded, retry_after}` -> 429 with `Retry-After` header and
    a machine-readable `code: "ingestion_backlog_exceeded"` (US-36.3 ingest backpressure —
    the backlog is at/over threshold OR it could not be measured and the bounded fail-open
    allowance is spent; distinct from the generic Hammer request-rate 429, which has no `code`)
  - `{:error, :ingestion_gate_unavailable, retry_after}` -> 503 with `Retry-After` and
    `code: "ingestion_gate_unavailable"` (the same gate refusing for a fault that is NOT
    backlog pressure, so the refusal does not claim a backlog nobody measured)
  - `{:error, %Ecto.Changeset{}}` -> 422 with field-level details
  - `{:error, :bad_request, message}` -> 400 with custom message
  - `{:error, :unprocessable_entity, message}` -> 422 with custom message
  - `{:error, :audit_write_failed}` -> 500 (a mutation whose audit insert failed, rolling
    the whole write back — the US-39.7 redact path and every corpus-tier mutation; the
    message is caller-neutral and it is never masked as a 404)
  - `{:error, %Postgrex.Error{}}` -> 504/503/500 by SQLSTATE class (US-27.3)
  - `{:error, %DBConnection.ConnectionError{}}` -> 503 with Retry-After (US-27.3)
  """

  use LoopctlWeb, :controller

  require Logger

  alias Ecto.Changeset
  alias Loopctl.ApiSpec.Messages
  alias Loopctl.Custody.ViolationMonitor
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Llm.Remediation
  alias Loopctl.Runners.Capacity
  alias LoopctlWeb.DBError
  alias LoopctlWeb.DBErrorLogger

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{status: 404, message: "Not found"}})
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{status: 401, message: "Unauthorized"}})
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{status: 403, message: "Forbidden"}})
  end

  def call(conn, {:error, :conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{status: 409, message: "Conflict"}})
  end

  # A fuzzy identifier (repo_url or name) matched more than one active project,
  # so resolution refused to silently attach new work to whichever is older.
  def call(conn, {:error, :ambiguous_resolution}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "ambiguous_resolution",
        message:
          "The supplied identifier matches more than one active project. " <>
            "Disambiguate with an exact slug (or a fully-qualified, single-host repo_url)."
      }
    })
  end

  # US-40.B1: a coordination handoff `ref` is already claimed — the loser of an
  # INSERT-to-claim race on the (tenant_id, project_id, ref) unique index. A distinct
  # `code` so a losing agent learns the ref is taken and moves on (never confused with
  # the generic 409 conflict). The message does NOT assert "another agent": the true
  # owner re-claiming its own ACTIVE ref is served idempotently (200) upstream, so a
  # 409 here means either a PEER owns the ref or the caller already completed it — in
  # both cases the caller should move on rather than retry the same ref.
  def call(conn, {:error, :already_claimed}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "already_claimed",
        message:
          "This ref is already claimed (by another agent, or already completed by you). Do not retry the same ref; move on to other work."
      }
    })
  end

  # The ONE 409 on this surface where "move on" is wrong (#707). The row still holds the
  # unique slot, so the INSERT failed — but its lease expired without completion, nobody
  # is working it, and `ChannelClaimSweeper` will reap it. `retry-after` is advisory and
  # deliberately short: the caller is waiting on a sweep, not on a peer finishing.
  def call(conn, {:error, :claim_lease_expired}) do
    conn
    |> put_resp_header("retry-after", "60")
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "claim_lease_expired",
        message:
          "This ref's claim lease expired without completion and the row is awaiting the sweeper. Nobody is working it — retry THIS ref shortly rather than moving on. GET /api/v1/channel/claims?ref=... shows the row with expired: true."
      }
    })
  end

  # Not a claim collision at all: the ref's instructions were retired by a successor
  # post. Distinct from `already_claimed` so a caller does not conclude a peer holds it.
  def call(conn, {:error, :ref_superseded}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "ref_superseded",
        message:
          "This ref's newest live post has been superseded — its instructions were retired. Claim the successor handoff instead; nobody holds this ref."
      }
    })
  end

  # A limit on the CALLER, not a statement about the ref — which may well be free. Kept
  # distinct so an agent throttled by its own budget does not record the ref as taken.
  def call(conn, {:error, :claim_budget_exhausted}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "claim_budget_exhausted",
        message:
          "You already hold the maximum concurrent open claims on this project. Finish one with channel_done or give one up with channel_release, then retry. This says nothing about whether the ref is free."
      }
    })
  end

  # Issue #779. The caller IS the claim's agent in the owning tenant and project — the
  # owner fetch already proved that — but the row was stamped by a DIFFERENT session.
  # This guard is ADVISORY: it stops a peer session accidentally ending work someone
  # else is doing (the `release` in KB 07f5e839 deleted a live claim), and it stops
  # nothing a caller intends, because `force: true` clears it and `session_id` is
  # client-supplied. The message names the override, because a session that crashed and
  # relaunched carries a NEW session id and must be able to finish its own work without
  # waiting out the lease.
  def call(conn, {:error, :claim_session_mismatch}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "claim_session_mismatch",
        message:
          "This claim was made by a DIFFERENT session on your agent key. Check GET /api/v1/channel/claims?ref=... — claimed_by_session and claimed_by_host say whose it is. If a peer session is still working it, leave it alone. If it is your own work from a session that has since restarted, retry with force: true."
      }
    })
  end

  def call(conn, {:error, {:invalid_transition, ctx}}) do
    current_agent = ctx |> Map.get(:current_agent_status) |> to_string()
    current_verified = ctx |> Map.get(:current_verified_status) |> to_string()
    attempted = Map.get(ctx, :attempted_action, "transition")
    hint = Map.get(ctx, :hint)

    message =
      if hint do
        "Cannot #{attempted}: story is in agent_status='#{current_agent}', " <>
          "verified_status='#{current_verified}'. #{hint}"
      else
        "Cannot #{attempted}: story is in agent_status='#{current_agent}', " <>
          "verified_status='#{current_verified}'"
      end

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        message: message,
        context: %{
          current_agent_status: current_agent,
          current_verified_status: current_verified,
          attempted_action: attempted
        }
      }
    })
  end

  def call(conn, {:error, {:contract_mismatch, ctx}}) do
    expected = Map.get(ctx, :expected_ac_count)
    provided = Map.get(ctx, :provided_ac_count)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message:
          "Contract mismatch: expected ac_count #{expected} but got #{provided}. " <>
            "Story has #{expected} acceptance criteria.",
        context: %{expected_ac_count: expected, provided_ac_count: provided}
      }
    })
  end

  def call(conn, {:error, :stale_claim_epoch}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "stale_claim_epoch",
        message:
          "The claim_epoch you presented is not this story's current epoch, so the claim " <>
            "it came from has ended — its lease expired and it was reclaimed, it was " <>
            "released, or the story was claimed again. Stop working this claim; read the " <>
            "story and claim it afresh if it is still available.",
        remediation: %{learn_more: "https://loopctl.com/wiki/agent-pattern"}
      }
    })
  end

  # US-45.1: the epoch is current but the claim no longer accepts the implementer's work: its
  # lease lapsed, review was requested, or the story left a claimed status. Renewing fixes
  # none of the last two, so the message does not tell the caller to renew.
  def call(conn, {:error, :claim_not_live}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "claim_not_live",
        message:
          "Your claim on this story no longer accepts work: its lease expired, you " <>
            "requested review, or the story is no longer in a claimed status. Stop adding " <>
            "to it; read the story's stage to see which.",
        remediation: %{learn_more: "https://loopctl.com/wiki/agent-pattern"}
      }
    })
  end

  # #803: the delivery stage row is not where the caller believed it was, so its
  # compare-and-set matched nothing. Distinct from `stale_claim_epoch` on purpose — the claim
  # is fine and the caller should keep working; only its picture of the stage is out of date.
  def call(conn, {:error, :stale_stage}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "stale_stage",
        message:
          "This story's delivery stage moved while this call was being made, twice, so " <>
            "nothing was written. Your claim is still good — only your picture of the " <>
            "stage is out of date, which usually means your own runner is advancing the " <>
            "story at the same time. Re-read the story's stage and make the call again."
      }
    })
  end

  # #803: a story with no `story_stages` row at all. It is a control-plane state, not
  # something the caller can clear by retrying or by giving up its claim, which is why it is
  # a 404 naming the stage row rather than the story.
  def call(conn, {:error, :unknown_story_stage}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{
        status: 404,
        code: "unknown_story_stage",
        message:
          "This story has no delivery stage row, so it is not in the delivery loop. " <>
            "Nothing was written."
      }
    })
  end

  # #803: a lock a delivery-stage write could not get inside its bounded wait, or a deadlock
  # Postgres broke by choosing it. NOTHING was written and the request is fine, so it is
  # retryable — with a `retry-after` LONGER than the wait that just ran out, because retrying
  # at exactly that wait puts the caller back in the same queue with no backoff.
  def call(conn, {:error, :busy}) do
    conn
    |> maybe_put_retry_after(div(Capacity.busy_retry_ms(), 1000) + 1)
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        status: 503,
        code: "busy",
        message:
          "The delivery stage row was locked by another writer and this call gave up " <>
            "waiting. Nothing was written; retry after the retry-after interval."
      }
    })
  end

  def call(conn, {:error, :not_claimant}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "not_claimant",
        message:
          "Only the story's assigned agent can do this, and your key's agent is not it. " <>
            "Renewing a claim and escalating a story are both the claimant's."
      }
    })
  end

  def call(conn, {:error, :lease_cap_reached}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "lease_cap_reached",
        message:
          "This claim was placed for a runner dispatch and has reached its lease cap " <>
            "(claim_lease_cap). No renewal extends a claim past its cap, so nothing was " <>
            "renewed, and this refusal releases nothing: the claim's lease ended at the cap, " <>
            "and the reclaim sweep releases the story — unless review has been requested on " <>
            "it, which the sweep skips. Stop working it."
      }
    })
  end

  def call(conn, {:error, :not_claimed}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "not_claimed",
        message:
          "This story is not held by a claim (it is not assigned or implementing), so " <>
            "there is no lease to renew. Claim it with POST /stories/:id/claim."
      }
    })
  end

  # Claim of a story whose prerequisites are not verified (#890): named, not a bare Conflict,
  # so a caller can tell it from a lost race and knows where to look.
  def call(conn, {:error, :dependencies_not_met}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "dependencies_not_met",
        message:
          "A story this one depends on, or a story in an epic its epic depends on, is not " <>
            "verified. GET /api/v1/stories/blocked (MCP list_blocked_stories) names them."
      }
    })
  end

  # US-44.3: a story whose delivery stage is HELD — `escalated`, `done` or `failed`
  # (`Loopctl.Delivery.Stages.held_story_ids/2`) — cannot be contracted or claimed, even when
  # its claim has ended and it reads `pending`/`contracted`. Not `invalid_transition`: the
  # story's own status allows the call; the stage is what refuses it.
  def call(conn, {:error, :story_held}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "story_held",
        message:
          "This story's delivery stage is `escalated`, `done` or `failed`, so it cannot be " <>
            "contracted or claimed. An escalated story waits for a human and becomes " <>
            "available again only once it is resolved to `queued` " <>
            "(POST /api/v1/stories/:id/stage/resolve); a done or failed one never does. " <>
            "Move on to other work."
      }
    })
  end

  def call(conn, {:error, :must_contract_first}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        message:
          "Story must be contracted before claiming. " <>
            "Call POST /stories/:id/contract first."
      }
    })
  end

  def call(conn, {:error, :must_claim_first}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        message:
          "Story must be claimed before starting. " <>
            "Call POST /stories/:id/claim first."
      }
    })
  end

  def call(conn, {:error, :self_verify_blocked}) do
    # L6: self-verify is a byzantine condition. It is RECORDED here; the tenant
    # is halted only once a repeated pattern is established
    # (Loopctl.Custody.ViolationMonitor). Either way this operation is refused.
    record_custody_violation(conn, "self_verify_blocked")

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "self_verify_blocked",
        message: "Cannot verify your own implementation.",
        remediation: %{learn_more: "https://loopctl.com/wiki/self-verify-blocked"}
      }
    })
  end

  def call(conn, {:error, :missing_assigned_agent}) do
    # INVARIANT 1: verify/review attempted on a custody-orphaned reported_done
    # story (no assigned agent, no dispatch lineage). This is a data-integrity /
    # custody-chain violation, NOT a byzantine self-verify attempt, so we do NOT
    # halt the tenant — we return a clear 409 so the caller re-establishes
    # provenance (the DB CHECK stories_reported_done_requires_agent makes this
    # unreachable for well-formed data).
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "missing_assigned_agent",
        message:
          "Story is reported_done but has no assigned agent or dispatch lineage. " <>
            "Its custody chain is broken, so it cannot be verified or reviewed. " <>
            "Re-establish provenance (claim/report or backfill) before proceeding.",
        remediation: %{learn_more: "https://loopctl.com/wiki/chain-of-custody"}
      }
    })
  end

  def call(conn, {:error, :unresolvable_dispatch_lineage}) do
    # A custody gate (report/review/verify) failed CLOSED because a dispatch this
    # story references — the implementer's (report/review/verify) or, on verify,
    # the verifier's — could not be resolved (e.g. it belongs to another tenant, or
    # the row is gone). This is a lineage-INTEGRITY failure, not a byzantine
    # self-claim attempt, so — like :missing_assigned_agent — we do NOT halt the
    # tenant; we return a clear 409 whose code names the real cause rather than
    # mislabeling it self_report/self_review/self_verify.
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "unresolvable_dispatch_lineage",
        message:
          "A dispatch referenced by this story could not be resolved, so the custody " <>
            "gate cannot prove the caller's lineage is separated from the implementer's. " <>
            "This is a lineage-integrity failure; re-establish the dispatch provenance " <>
            "before reporting, reviewing, or verifying.",
        remediation: %{learn_more: "https://loopctl.com/wiki/chain-of-custody"}
      }
    })
  end

  def call(conn, {:error, :caller_lineage_required}) do
    # The caller's key was not minted by a dispatch, so its separation from
    # dispatch-minted work cannot be SHOWN. That is a credential/configuration
    # condition, not a byzantine self-claim: it must NOT record a custody violation
    # (which escalates to a tenant-wide halt), because it fires on every call an
    # unmigrated legacy key makes.
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "caller_lineage_required",
        message:
          "This story's work was dispatch-minted, so the custody gate compares dispatch " <>
            "lineages — and your key was not minted by a dispatch, so it has none. Call " <>
            "again with an ephemeral key from POST /api/v1/dispatches.",
        remediation: %{learn_more: "https://loopctl.com/wiki/dispatch-lineage"}
      }
    })
  end

  def call(conn, {:error, :self_report_blocked}) do
    record_custody_violation(conn, "self_report_blocked")

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "self_report_blocked",
        message: "Cannot report your own implementation.",
        remediation: %{learn_more: "https://loopctl.com/wiki/self-report-blocked"}
      }
    })
  end

  # A custody transition that MINTS a capability could not mint one for a keyed
  # tenant (an unreachable secret store, a cleared audit key), so the whole
  # transition rolled back rather than committing a state the agent cannot act on
  # — a claimed story whose `start` demands a capability that was never issued and
  # whose recovery path needs a dispatch a legacy bearer claim never records.
  # Nothing changed server-side, so retrying is both safe and the entire remedy;
  # 503 (not 4xx) because the fault is ours.
  def call(conn, {:error, :capability_mint_failed}) do
    conn
    |> put_resp_header("retry-after", "5")
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        status: 503,
        code: "capability_mint_failed",
        message:
          "The capability token this operation must issue could not be minted, so nothing " <>
            "was changed — the story is exactly as it was. This is a server-side condition " <>
            "(the tenant's audit signing key could not be read), not something your request " <>
            "can fix. Retry shortly; if it persists an operator must check the tenant's " <>
            "audit key.",
        retry_after_seconds: 5,
        remediation: %{learn_more: "https://loopctl.com/wiki/capability-tokens"}
      }
    })
  end

  # The tenant's audit signing key cannot be USED: absent from the secret store,
  # corrupt in it, or replaced out of band. A rotation whose new private half is
  # merely not DEPLOYED yet is NOT this — that closes on its own and answers
  # `capability_mint_failed`. Every capability path is blocked by it and NONE is the
  # caller's to fix — `recover-cap` in particular mints through the same key, so
  # the `missing_capability` remediation this used to share sent the caller round
  # a loop that cannot terminate. Deliberately NO `retry-after`: unlike
  # `capability_mint_failed` this does not clear on its own, and advertising it as
  # transient is what turned agents into hot-loops against an operator condition.
  def call(conn, {:error, :capability_key_unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        status: 503,
        code: "capability_key_unavailable",
        message:
          "This tenant's audit signing key is unavailable, so no capability token can be " <>
            "minted or checked. Nothing about your request is wrong, and re-minting via " <>
            "POST /stories/:id/recover-cap will fail the same way. An operator must restore " <>
            "the tenant's audit signing key (or archive the rotated-out one) before this " <>
            "operation can succeed.",
        remediation: %{learn_more: "https://loopctl.com/wiki/capability-tokens"}
      }
    })
  end

  def call(conn, {:error, :missing_capability}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "missing_capability",
        message: "A capability token is required for this operation.",
        remediation: %{learn_more: "https://loopctl.com/wiki/capability-tokens"}
      }
    })
  end

  # A capability token was refused. This is NOT a byzantine signal and does NOT
  # count toward a custody halt: a capability is SINGLE-USE with a bounded TTL, so
  # every rejection reason it can produce is reachable by ordinary operation — a
  # retry of a request whose first attempt already consumed the token, a resumed
  # agent presenting an expired one, an audit-key rotation invalidating signatures
  # in flight. The operation is refused with this 403, which is the enforcement;
  # escalating a client retry to a tenant-wide freeze is not. Genuine abuse shows
  # up as a SPIKE, so the signal is preserved as telemetry + a warning log for an
  # operator to alert on. See Loopctl.Custody.ViolationMonitor.
  def call(conn, {:error, {:cap_rejected, reason}}) do
    report_cap_rejection(conn, reason)

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "cap_rejected",
        message: "Capability token rejected: #{reason}.",
        remediation: %{learn_more: "https://loopctl.com/wiki/capability-tokens"}
      }
    })
  end

  def call(conn, {:error, :self_review_blocked}) do
    # The third lineage-aware self-* gate, and byzantine on the same terms as the
    # other two, so it counts. A CORRECTLY configured client never reaches here:
    # `exact_role: [:orchestrator, :user]` means a user key passes a nil reviewer
    # (deliberately permitted), and the documented dispatch tree puts the reviewer
    # BESIDE the implementer, which `:chain` separation admits. The two shapes that
    # do reach it are the implementer's own agent reviewing, and a parent
    # rubber-stamping the sub-agent it dispatched — each named a violation by the
    # custody spec, and neither producible by a retry, timeout or crash-resume.
    record_custody_violation(conn, "self_review_blocked")

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "self_review_blocked",
        message:
          "Cannot review your own implementation. " <>
            "The reviewer agent must be different from the implementing agent.",
        remediation: %{learn_more: "https://loopctl.com/wiki/self-review-blocked"}
      }
    })
  end

  def call(conn, {:error, :review_required}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message:
          "Review evidence required. " <>
            "Include 'review_type' (e.g. 'enhanced', 'team', 'adversarial') and " <>
            "a non-empty 'summary' describing review findings. " <>
            "Verification without independent review is not allowed."
      }
    })
  end

  def call(conn, {:error, :review_not_conducted}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message:
          "No review record found for this story. " <>
            "Run the review pipeline and call POST /stories/:id/review-complete " <>
            "before attempting to verify. " <>
            "The review must be completed AFTER the story was reported done."
      }
    })
  end

  def call(conn, {:error, :story_not_reported_done}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message:
          "Story must be in reported_done status before a review record can be created. " <>
            "The agent must call POST /stories/:id/report first."
      }
    })
  end

  def call(conn, {:error, :rate_limited}) do
    retry_after = conn |> get_resp_header("retry-after") |> List.first() || "60"

    conn
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        status: 429,
        message: "Too many requests. Retry after #{retry_after} seconds.",
        retry_after_seconds: String.to_integer(retry_after)
      }
    })
  end

  # US-36.3: batch-ingest backlog backpressure. The calling tenant's in-flight
  # :ingestion backlog is at/over the OBAN_INGEST_BACKLOG_MAX threshold, so the whole
  # batch was rejected all-or-nothing (ZERO jobs enqueued). A distinct `code` and the
  # `Retry-After` header make this unambiguously distinguishable from the Hammer
  # request-rate 429 (`message: "Rate limit exceeded"`, no `code`).
  def call(conn, {:error, :ingestion_backlog_exceeded, retry_after})
      when is_integer(retry_after) and retry_after > 0 do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        status: 429,
        code: "ingestion_backlog_exceeded",
        # #558: does NOT assert a measured backlog. This code now has TWO causes — the
        # backlog is genuinely at/over threshold, OR the server could not measure it and
        # the bounded fail-open allowance is spent. On the second, nothing was counted and
        # the real backlog may be zero, so the old copy ("already has too many ... once the
        # backlog drains") told the client a fact the server does not have, and pointed it
        # at a remedy that may not apply.
        # ONE definition, shared with the published OpenAPI example/body (#558) so the spec
        # cannot keep telling clients something this response stopped saying.
        message: Messages.ingestion_backlog_exceeded(retry_after),
        retry_after_seconds: retry_after
      }
    })
  end

  # #558: the SAME admission gate, refusing for a fault that is NOT backlog pressure — the
  # backlog could not be measured (a driver/config fault, or a defect in the counting code)
  # and the bounded fail-open allowance for it is spent. Answering `429
  # ingestion_backlog_exceeded` there asserted a backlog nobody counted and pointed the client
  # at a drain that a deterministic fault never reaches; this is a server-side condition, so it
  # gets the server-side status. `Retry-After` is still set — retrying is all the client can do.
  def call(conn, {:error, :ingestion_gate_unavailable, retry_after})
      when is_integer(retry_after) and retry_after > 0 do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        status: 503,
        code: "ingestion_gate_unavailable",
        message:
          "Ingestion is shedding for this tenant: the in-flight backlog could not be " <>
            "measured, and the bounded allowance for admitting unmeasured work is spent. " <>
            "This is a server-side condition, not your backlog. Nothing from this request " <>
            "was enqueued. Retry after #{retry_after} seconds.",
        retry_after_seconds: retry_after
      }
    })
  end

  # US-27.3: map a recognized DB exception (returned as a tuple by a controller
  # that rescued it) to a pinned status + safe body + structured error log
  # carrying the real SQLSTATE. NEVER leaks SQL/params/vectors/stack traces.
  def call(conn, {:error, %Postgrex.Error{} = error}), do: render_db_error(conn, error)

  def call(conn, {:error, %DBConnection.ConnectionError{} = error}),
    do: render_db_error(conn, error)

  # A mutation whose audit entry could not be written, rolling the whole transaction
  # back — the US-39.7 channel-post redact path, and every corpus-tier mutation
  # (US-43.2 AC-43.2.7). Fail-safe-on-security-path: a rolled-back write is NEVER
  # reported as a 404 ("already gone/handled"), which would let an agent believe a
  # leaked secret was removed when it was not. The message is CALLER-NEUTRAL: it says
  # the write did not happen and the prior state stands, because a corpus index request
  # has no post to still exist and naming one asserted something that did not occur.
  def call(conn, {:error, :audit_write_failed}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        status: 500,
        code: "audit_write_failed",
        message:
          "The write could not be recorded in the audit trail and was rolled back, so it " <>
            "did NOT happen — nothing was persisted and the prior state still stands. " <>
            "Retry the request."
      }
    })
  end

  # A claim's transaction failed in a step that is not the caller's to fix (the
  # custody audit entry, the webhook events) and rolled back, so the story is
  # exactly as it was. ONE stable code rather than the failing step's own term:
  # an audit-log changeset rendered as 422 asserted the request body was invalid
  # using fields the caller never sent, and an unrenderable term crashed the
  # controller that was supposed to answer it.
  def call(conn, {:error, :claim_failed}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        status: 500,
        code: "claim_failed",
        message:
          "The claim could not be recorded and was rolled back; the story is unclaimed. " <>
            "Nothing about your request is wrong — retry it."
      }
    })
  end

  def call(conn, {:error, %Changeset{} = changeset}) do
    details = format_changeset_errors(changeset)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        message: changeset_error_message(changeset),
        details: details
      }
    })
  end

  # A 400 that carries a machine-readable `code` because the remedy differs per cause
  # (#779: `confirm_removed` vs `dry_run_required` on the bulk-delete surface). MUST
  # precede the `{:error, refusal, %{code:, message:}}` clause below, which would
  # otherwise match this same shape and answer 422.
  def call(conn, {:error, :bad_request, %{code: code, message: message}})
      when is_binary(code) and is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{status: 400, code: code, message: message}})
  end

  # US-41.3 (AC-41.3.3): a chat-endpoint write refused by the credential rule or by
  # the config-time probe. The details map is built by `Loopctl.Llm.ChatProbe` and
  # is SECRET-FREE: it echoes the endpoint URL (the tenant's own declared host) and
  # a machine-readable `code` + ACTION-REQUIRED `remediation`, never the key.
  # Nothing was persisted.
  def call(conn, {:error, refusal, %{code: code, message: message} = details})
      when is_atom(refusal) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: code,
        message: message,
        remediation: Map.get(details, :remediation, %{})
      }
    })
  end

  def call(conn, {:error, :bad_request, message}) when is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{status: 400, message: message}})
  end

  # #730: a verdict on an ASSERTED conflict pair, recorded by the principal that asserted
  # it. Deliberately NOT `record_custody_violation/2`: unlike the `self_*_blocked` story
  # gates above this is not an L6 byzantine signal, it is a separation-of-duties refusal on
  # a curation surface — the caller did nothing dishonest, it simply cannot both name a
  # pair and judge it. Recording it as byzantium would escalate ordinary curation into a
  # tenant-wide halt. 409 (not 422) because the request is well-formed and the pair exists;
  # what is wrong is WHO is asking.
  def call(conn, {:error, :self_asserted_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "self_asserted_conflict",
        message:
          "You asserted this conflict pair, so you cannot also record its verdict. An " <>
            "asserted pair is named by its caller; a pair the system flagged independently " <>
            "(GET /api/v1/knowledge/conflicts, origin \"system\") carries no such " <>
            "restriction. The pair stays in the queue for another key to judge."
      }
    })
  end

  # #730: the assertion's transaction failed in a step the caller cannot fix (the audit
  # entry) and rolled back, so no link exists. ONE stable code rather than the failing
  # step's own term — an audit-log changeset rendered as a 422 would assert the request
  # body was invalid using fields the caller never sent.
  def call(conn, {:error, :assertion_not_recorded}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        status: 500,
        code: "assertion_not_recorded",
        message:
          "The conflict assertion could not be recorded in the audit trail and was rolled " <>
            "back; no pair was flagged. Nothing about your request is wrong — retry it."
      }
    })
  end

  def call(conn, {:error, :unprocessable_entity, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{status: 422, message: message}})
  end

  # Epic 28 (#179): mandatory BYO — a tenant knowledge-LLM operation was blocked
  # because the tenant has no Anthropic key configured. Carries a machine-readable
  # `code` PLUS a structured, self-service `remediation` (naming the `set_llm_config`
  # MCP tool, the REST endpoint, a copy-paste example, and the onboarding docs) so a
  # stranger agent can provision its own key from the response ALONE — no human
  # needed. Ingest is always the Anthropic path, so the missing credential is the
  # `api_key`.
  # US-43.2 AC-43.2.9: mode A embeds SERVER-SIDE on the TENANT's own key, so a corpus
  # created in that mode by a keyless tenant could only fail at first index — long
  # after the call that could have said so. The remediation is the EMBEDDING
  # credential (`Remediation.for_credential(:embedding)`), not the Anthropic one the
  # clause below carries: they are different fields and naming the wrong one sends an
  # agent to provision a key that would not have helped.
  def call(conn, {:error, :no_embedding_key_configured, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "no_embedding_key",
        message: message,
        remediation: Remediation.for_credential(:embedding)
      }
    })
  end

  # US-43.2 AC-43.2.10: BOTH lanes of a heavy read were shed by the per-tenant gate.
  # A single shed lane never reaches here — the caller degrades to the surviving lane
  # and names the degradation in `meta`. This is the case where nothing ran, so it is
  # reported as the transient capacity condition it is rather than as an empty result
  # set, which a caller would read as "the corpus has nothing".
  #
  # 429, NOT 503, and the status is the load-bearing part: the SAME condition already
  # has a rendering — `LoopctlWeb.Plugs.HeavyReadOverloadHandler` raising through to
  # `ErrorJSON.render("429.json", ...)` — which answers 429 under this exact `code`.
  # The code exists so a client can tell per-tenant heavy-read backpressure apart from a
  # generic rate-limit 429; two statuses for one code would put that client back to
  # guessing, decided only by whether the endpoint asked for `on_overload: :raise` or
  # `:tag` — which is not observable to it. AC-43.2.10 forbids RAISING a 429 through to
  # the agent, which this does not: the tag is caught, the lanes degrade first, and only
  # a both-lanes shed reaches here, as a coded body with a Retry-After.
  def call(conn, {:error, :heavy_read_overloaded}) do
    conn
    |> put_resp_header("retry-after", "1")
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        status: 429,
        code: "heavy_read_overloaded",
        message:
          "This tenant has too many heavy reads in flight; the query was shed rather " <>
            "than queued. Retry shortly."
      }
    })
  end

  def call(conn, {:error, :no_api_key_configured, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "no_api_key",
        message: message,
        remediation: Remediation.for_credential(:anthropic)
      }
    })
  end

  # #803: the delivery stage machine refusing the TRANSITION a caller asked for. Distinct
  # `Progress.force_unclaim_story/3`'s own 500, NAMED rather than left to the last clause.
  # Two endpoints return it — `POST /stories/:id/force-unclaim` and
  # `POST /stories/:id/stage/resolve`, whose `:queued` path releases the claim first — and
  # without a clause here both answered a bare `internal_error` while the last clause logged
  # "add a clause, or map it in the controller" on every occurrence. It is a known shape with
  # a known remedy, so it says so: the release rolled back whole, the story is untouched, and
  # re-running the call is the right next move.
  def call(conn, {:error, :force_unclaim_failed}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        status: 500,
        code: "force_unclaim_failed",
        message:
          "The release rolled back at a step that is not supposed to be able to refuse. " <>
            "The story is UNCHANGED — still claimed, still held — and nothing was written. " <>
            "The cause is logged server-side with the step name. Re-run this call."
      }
    })
  end

  # `Loopctl.Delivery.Escalations.resolve/3`'s own refusal when the requested target is not a
  # stage `:human_resolution` can reach. It is DECLARED in that module's public `@type
  # error()` and had no clause here, so rendering it raised `FunctionClauseError` — the exact
  # shape the last-clause note below says it deliberately does not absorb, which is right for
  # an UNDECLARED shape and wrong for a declared one (846.8 review round 2).
  #
  # Unreachable over HTTP today: `StoryEscalationController.resolution_target/1` admits only
  # `queued`, `done` and `failed`, and `StageMachine`'s `@human_resolution` has an edge to all
  # three. So this is for a direct caller and for the day that enum and that table disagree —
  # which is precisely when a raise would be least welcome.
  #
  # 422, not 409: the request is well formed and the story is genuinely escalated; what is
  # wrong is the VALUE asked for.
  def call(conn, {:error, {:unresolvable_target, to}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "unresolvable_target",
        message:
          "There is no human resolution from `escalated` to `#{inspect(to)}`. Resolve to " <>
            "queued, done or failed. Nothing was written."
      }
    })
  end

  # from `{:invalid_transition, ctx}` above, which is the story lifecycle's and carries the
  # statuses it would have moved between; this one is bare because the stage machine's table
  # is a fixed triple and the caller already knows the one it sent.
  def call(conn, {:error, :invalid_transition}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "invalid_transition",
        message:
          "The delivery stage machine has no such transition from this story's current " <>
            "stage. Nothing was written."
      }
    })
  end

  # #803: everything the stage machine refuses about the REQUEST rather than about the
  # story's state. One clause, because the remedy is the same for all of them — the call as
  # sent cannot be made, and resending it unchanged will not help — and the `code` says which.
  @stage_request_faults %{
    reason_required: "A reason is required for this transition.",
    invalid_reason:
      "The reason is empty or too long. The bound is " <>
        "#{StageMachine.max_reason_length()} codepoints of the text you SEND, which is what " <>
        "Postgres counts and not graphemes — measure what you are about to send, not what " <>
        "is stored: a hidden character is escaped to a visible `<U+XXXX>` on the way in, so " <>
        "the stored value is longer and its own bound is wider. A NUL is no longer a cause " <>
        "here; it is escaped rather than refused.",
    invalid_event_data:
      "The structured payload is not a JSON object, is over 8000 bytes once encoded, or " <>
        "contains a NUL.",
    invalid_effect: "One of the side-effect identities is malformed or is not a known effect.",
    missing_required_effect:
      "This transition must carry an identity it did not: entering `merged` has to name " <>
        "the merge sha.",
    wrong_stage: "This story's stage does not produce the side-effect identity given.",
    effect_conflict:
      "That side-effect identity is already recorded with a DIFFERENT value. A replay may " <>
        "re-send the same value; it may never record a second one.",
    human_required:
      "Only a human principal may take this transition: a role of at least `user` on a key " <>
        "no dispatch minted."
  }

  def call(conn, {:error, fault}) when is_map_key(@stage_request_faults, fault) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: Atom.to_string(fault),
        message: Map.fetch!(@stage_request_faults, fault)
      }
    })
  end

  # #803: a custody transition whose hash-chain entry did not land, so the whole transition
  # rolled back. A 500 because it is a server-side fault an operator has to look at — the
  # caller did nothing wrong and retrying will not help while the chain is refusing — and
  # `Loopctl.Delivery.Stages` has already logged it with the tenant, story and reason.
  def call(conn, {:error, :audit_chain_append_failed}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        status: 500,
        code: "audit_chain_append_failed",
        message:
          "The audit chain refused this transition's entry, so nothing was written. This " <>
            "is a server-side condition; it has been logged."
      }
    })
  end

  # THE LAST CLAUSE. An `{:error, atom}` no clause above names used to raise
  # `FunctionClauseError` here, which reaches the client as a 500 that is indistinguishable
  # from a crash and reaches the operator as a stack trace naming this module rather than the
  # atom. Both halves were the problem: #824 shipped four reachable atoms with no clause and
  # nothing failed until a request hit one.
  #
  # It answers 500, not 422: an unmapped atom is a GAP, and rendering it as a client error
  # would tell the caller its request was wrong when nobody has decided that. The atom is
  # logged, never echoed — a context's internal vocabulary is not a public error code.
  #
  # Deliberately narrow. It matches an ATOM only, so a changeset, a `{:error, reason, message}`
  # triple and every struct clause above keep their own rendering, and a new refusal shape
  # still fails loudly rather than being absorbed here.
  def call(conn, {:error, reason}) when is_atom(reason) do
    Logger.error(
      "FallbackController has no clause for #{inspect(reason)}; answered 500. " <>
        "Add a clause, or map it in the controller. " <>
        "path=#{conn.request_path} method=#{conn.method}"
    )

    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        status: 500,
        code: "internal_error",
        message: "The server could not complete this request. It has been logged."
      }
    })
  end

  # US-27.3: shared DB-error rendering for both Postgrex.Error and
  # DBConnection.ConnectionError. `DBError.map/1` returns the pinned status,
  # safe client message, and the real SQLSTATE for the log. A non-DB error
  # never reaches here (the call/2 clauses only match the two DB structs).
  defp render_db_error(conn, error) do
    case DBError.map(error) do
      {:ok, mapping} ->
        DBErrorLogger.log(conn, error, mapping)

        conn
        |> maybe_put_retry_after(mapping.retry_after)
        |> put_status(mapping.status)
        |> json(%{
          error: %{status: mapping.status, code: mapping.code, message: mapping.message}
        })

      :unmapped ->
        # Should be unreachable: call/2 only dispatches here for the two DB
        # structs DBError knows. Re-raise rather than silently swallow.
        raise error
    end
  end

  defp maybe_put_retry_after(conn, nil), do: conn

  defp maybe_put_retry_after(conn, seconds) when is_integer(seconds) do
    put_resp_header(conn, "retry-after", Integer.to_string(seconds))
  end

  defp format_changeset_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Translate recognized changeset errors into actionable domain messages.
  # Falls back to the generic "Validation failed" when no domain rule matches
  # so callers still get the field-level details array.
  defp changeset_error_message(%Changeset{data: %mod{}} = changeset)
       when mod in [Loopctl.WorkBreakdown.Epic, Loopctl.WorkBreakdown.Story] do
    if unique_constraint_violation?(changeset) do
      number = Changeset.get_field(changeset, :number)
      entity = if mod == Loopctl.WorkBreakdown.Epic, do: "Epic", else: "Story"

      "#{entity} #{number} already exists in this project. " <>
        "Pick a different number, or use the import endpoint with `merge=true` " <>
        "to update the existing record."
    else
      "Validation failed"
    end
  end

  defp changeset_error_message(_), do: "Validation failed"

  # Epic/Story schemas put a single unique_constraint on (tenant_id,
  # project_id, number); Ecto auto-names the index to include "_number_index".
  # We detect the number-collision case by inspecting constraint_name so that
  # future schemas adding unrelated unique constraints (e.g. external_id,
  # slug) don't get falsely reported as "X already exists".
  defp unique_constraint_violation?(%Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        (Keyword.get(opts, :constraint_name) || "") |> String.contains?("number")
    end)
  end

  # L6: record the violation. The halt decision (threshold over a window) and the
  # alerting both live in Loopctl.Custody.ViolationMonitor — a single violation no
  # longer halts a tenant, but a repeated pattern still does.
  defp record_custody_violation(conn, violation_type) do
    case conn.assigns do
      %{current_api_key: %{tenant_id: tid} = key} when not is_nil(tid) ->
        ViolationMonitor.record(tid, violation_type,
          story_id: story_id_param(conn),
          api_key_id: Map.get(key, :id),
          agent_id: Map.get(key, :agent_id)
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Observability for a refusal that must NOT arm a halt (see the :cap_rejected
  # clause). Alert on the RATE of this event, not on a single occurrence.
  defp report_cap_rejection(conn, reason) do
    tenant_id =
      case conn.assigns do
        %{current_api_key: %{tenant_id: tid}} when not is_nil(tid) -> tid
        _ -> nil
      end

    story_id = story_id_param(conn)

    Logger.warning(
      "cap_rejected: capability token refused tenant_id=#{inspect(tenant_id)} " <>
        "reason=#{inspect(reason)} story_id=#{inspect(story_id)}"
    )

    :telemetry.execute(
      [:loopctl, :custody, :cap_rejected],
      %{count: 1},
      %{tenant_id: tenant_id, reason: reason, story_id: story_id}
    )

    :ok
  rescue
    _ -> :ok
  end

  # `conn.params` is `%Plug.Conn.Unfetched{}` on the direct-`call/2` paths, which
  # is a struct and therefore matches neither clause's map pattern.
  defp story_id_param(%Plug.Conn{params: %{"id" => id}}) when is_binary(id), do: id
  defp story_id_param(%Plug.Conn{}), do: nil
end
