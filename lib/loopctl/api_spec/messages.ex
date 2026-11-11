defmodule Loopctl.ApiSpec.Messages do
  @moduledoc """
  Error-message text that BOTH the runtime response and the published OpenAPI spec render.

  One definition, two readers. `LoopctlWeb.FallbackController` builds the body a client
  actually receives; `Loopctl.ApiSpec.Schemas` publishes the `example` and the documented
  response body. When those are two string literals they drift the moment either changes —
  and the drift is invisible, because nothing compares a spec example to a runtime body.

  It happened here (#558): the 429 copy was corrected in the controller to stop asserting a
  backlog that, on the metered fail-open path, was never measured — and the spec kept telling
  clients the opposite. Same technique as `@max_inline_content_bytes`, which CLAUDE.md already
  prescribes for a limit that is both enforced and documented.
  """

  @doc """
  The 429 `ingestion_backlog_exceeded` message.

  Deliberately does NOT claim the backlog is full. The code has TWO causes: the backlog is
  genuinely at/over threshold, OR it could not be MEASURED and the bounded fail-open allowance
  is spent. On the second, nothing was counted and the real backlog may be zero, so the older
  wording ("already has too many … once the backlog drains") stated a fact the server does not
  have and pointed the client at a remedy that may not apply.

  Route-NEUTRAL wording: the single-item route (`POST /knowledge/ingest`) renders this same
  string, so it must not speak of "this batch" to a client that submitted one item.
  """
  @spec ingestion_backlog_exceeded(pos_integer()) :: String.t()
  def ingestion_backlog_exceeded(retry_after_seconds) do
    "Ingestion is shedding for this tenant: the in-flight backlog is at or over the " <>
      "threshold, or it could not be measured. Nothing from this request was " <>
      "enqueued. Retry after #{retry_after_seconds} seconds."
  end

  # ── US-47.5: review custody for chg-dispatched reviews (Epic 47 PRD §6) ──────────────────
  # Each is rendered by `LoopctlWeb.FallbackController` AND quoted in the `operation/2` specs
  # of the endpoints that can return it, so the two cannot drift.

  @doc "The 409 `chg_reviewer_required` message (review-complete on a chg story)."
  @spec chg_reviewer_required() :: String.t()
  def chg_reviewer_required do
    "This story is bound to a chg change, so its review is accepted only from a key whose " <>
      "dispatch chg-server minted for the review: a strict descendant of the intake " <>
      "source's chg_root_dispatch_id. Neither chg-server's root key nor any key outside " <>
      "that subtree can record it."
  end

  @doc "The 422 `commit_sha_not_bound` message (review-complete on a chg story)."
  @spec commit_sha_not_bound() :: String.t()
  def commit_sha_not_bound do
    "This story is bound to a chg change, so review-complete requires `commit_sha`: the " <>
      "40- or 64-character lowercase hex sha of a submitted revision of the story's current " <>
      "change (the revision commit chg reviewed). The sha sent is absent, malformed, or not " <>
      "a revision loopctl has applied for that change."
  end

  @doc "The 409 `chg_review_already_recorded` message (one verdict per reviewer dispatch)."
  @spec chg_review_already_recorded() :: String.t()
  def chg_review_already_recorded do
    "This reviewer dispatch has already recorded its verdict. chg-server mints one reviewer " <>
      "dispatch per (change, revision) review, and each records exactly one; a further " <>
      "review needs a new dispatch."
  end

  @doc "The 409 `chg_root_cannot_verify` message (verify, reject, verify-all, bulk, backfill)."
  @spec chg_root_cannot_verify() :: String.t()
  def chg_root_cannot_verify do
    "This key descends from a dispatch an intake source registers as chg-server's " <>
      "chg_root_dispatch_id. chg-server's keys may review a story and never verify, reject, " <>
      "backfill or mark it complete: the process that mints the reviewers must not also " <>
      "certify what they reviewed. Verify with an orchestrator key outside chg's tree."
  end

  @doc "The 409 `chg_root_review_only` message (claim, bulk claim, report)."
  @spec chg_root_review_only() :: String.t()
  def chg_root_review_only do
    "This key descends from a dispatch an intake source registers as chg-server's " <>
      "chg_root_dispatch_id. chg-server's keys may only review: claiming or reporting a " <>
      "story from chg's tree would let one tree implement and review the same work."
  end

  @doc """
  The 409 `review_missing_escalated` message (verify, verify-all, bulk verify, backfill, bulk
  mark-complete on a chg story held over `:review_missing`).
  """
  @spec review_missing_escalated() :: String.t()
  def review_missing_escalated do
    "This story is bound to a chg change that landed with no chg review recorded for its " <>
      "landed revision, so its delivery stage is escalated over review_missing. It is not " <>
      "verified until a human resolves that escalation (POST /api/v1/stories/:id/stage/" <>
      "resolve, MCP resolve_escalation), and then only on a chg review of the landed revision."
  end

  @doc """
  The 409 `chg_review_not_for_landed_revision` message (verify, verify-all, bulk verify,
  backfill, bulk mark-complete on a chg story).
  """
  @spec chg_review_not_for_landed_revision() :: String.t()
  def chg_review_not_for_landed_revision do
    "This story is bound to a chg change, so it is verified only on a review a chg-minted " <>
      "reviewer recorded for its LANDED revision: the revision commit (the envelope sha) of " <>
      "the newest applied `landed` event of its current change. No such review exists — the " <>
      "change has not landed, or no chg review names that revision (a review of an earlier " <>
      "revision, or one recorded off the chg path, does not count)."
  end

  @doc """
  The 409 `chg_landing_not_trunk_verified` message (US-47.6; verify, verify-all, bulk verify,
  backfill, bulk mark-complete on a chg story).
  """
  @spec chg_landing_not_trunk_verified() :: String.t()
  def chg_landing_not_trunk_verified do
    "This story is bound to a chg change, so its CI evidence is chg's trunk verifier: the " <>
      "trunk commit its newest applied `landed` event names (data.merge_sha) must be an " <>
      "ancestor of, or equal to, the repository's verified/master. The forge says it is not " <>
      "(chg has not verified that commit yet), or the landing named no valid trunk commit. " <>
      "Retry once chg's `verified` event for a commit containing the landing has arrived."
  end

  @doc """
  The 409 `chg_landing_reverted` message (US-47.6; every verify path, on a chg story).
  """
  @spec chg_landing_reverted() :: String.t()
  def chg_landing_reverted do
    "This story is bound to a chg change whose newest landing was reverted: an applied " <>
      "`reverted` event follows it. A reverted landing is never verified; the story is " <>
      "verifiable again only after the change lands anew."
  end

  @doc """
  The 503 `chg_trunk_unevaluated` message (US-47.6; every verify path, on a chg story).
  """
  @spec chg_trunk_unevaluated() :: String.t()
  def chg_trunk_unevaluated do
    "This story is bound to a chg change, and whether its landing is in verified/master " <>
      "could not be established: the forge timed out, failed, was rate-limited, refused the " <>
      "credential, has no verified/master ref (or no such commit) yet, no credential reads " <>
      "the repository, or a new landing arrived while this call ran. Nothing was decided and " <>
      "nothing changed. `reason` names which; retry after `retry_after_seconds` (the " <>
      "Retry-After header)."
  end
end
