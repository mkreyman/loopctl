defmodule Loopctl.Threads.IssueLinks do
  @moduledoc """
  The outbox for the comment that links a story's intake issue to its thread page (US-45.7,
  AC-45.7.4, PRD §6.1: "the intake issue on GitHub links to it").

  ## When the link is written

  In the transaction that records the thread's FIRST checkpoint (`record_in/3`, called by
  `Loopctl.Threads`). A story is a thread from the moment it exists, but until its claimant
  reports a commit the page has nothing on it but the story; the first checkpoint is when there
  is work to look at, and the one moment every thread passes through once. Threads that already
  had a checkpoint when this shipped got their row once, from the migration that added the table
  (`backfill_sql/0` there), and only while their work was still in flight.

  ## Two halves, far apart, as `Loopctl.Intake.IssueClosures` is

  - `record_in/3` runs INSIDE the checkpoint's transaction and touches no network. The unique
    index on `(tenant_id, story_id)` and `ON CONFLICT DO NOTHING` make it once per story.
  - `attempt/2` runs from `Loopctl.Workers.ThreadIssueLinkWorker` with NOTHING held: a
    compare-and-set claim, one bounded forge call, one short write. The worker reads only
    pending rows; nothing scans the fleet's history.

  ## Can a retry do it twice?

  The claim is `Loopctl.ForgeOutbox.claim_attempt/3`, the CAS on `:pending` AND due the closure
  outbox uses, so two drainers cannot both post. A node that dies after GitHub accepted the comment and before
  `mark_commented/2` committed re-posts it after the in-flight backoff. That is the one window,
  and it is the cost `Loopctl.Delivery.IssueCloser` accepts for its own comment: a duplicated
  link is visible and harmless, and closing the window would need a transaction held across
  the forge call.

  ## Isolation

  `record_in/3` runs on the caller's RLS `Loopctl.Repo` transaction. The drainer's fleet-wide
  candidate read and its marker writes run on `AdminRepo` with an explicit `tenant_id` on every
  row-addressed statement, exactly as the closure outbox does.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.ForgeOutbox
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.Threads.IssueLink
  alias Loopctl.WorkBreakdown.Story

  @doc "How many transient attempts a link gets before it is abandoned (`Loopctl.ForgeOutbox`)."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: ForgeOutbox.max_attempts()

  @doc """
  Records the intent to link `story_id`'s intake issue, in the CALLER's `Loopctl.Repo`
  transaction — the one recording the thread's first checkpoint (`Loopctl.Threads`). `:ok` when
  a row now exists, `:no_link` when the story came from no intake record, its source is
  revoked, or its issue is known to be closed; the first is the ordinary case for an authored
  story.
  """
  @spec record_in(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | :no_link
  def record_in(repo, tenant_id, story_id) do
    target =
      repo.one(
        from s in Story,
          join: r in Record,
          on: r.id == s.intake_record_id and r.tenant_id == s.tenant_id,
          join: src in Source,
          on: src.id == r.source_id and src.tenant_id == r.tenant_id,
          where: s.tenant_id == ^tenant_id and s.id == ^story_id,
          where: is_nil(src.revoked_at) and r.issue_number > 0,
          where: is_nil(r.issue_state) or r.issue_state != "closed",
          select: %{repo_full_name: src.repo_full_name, issue_number: r.issue_number}
      )

    if target, do: insert(repo, tenant_id, story_id, target), else: :no_link
  end

  defp insert(repo, tenant_id, story_id, target) do
    now = DateTime.utc_now()

    row =
      Map.merge(target, %{
        id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        story_id: story_id,
        status: :pending,
        attempts: 0,
        inserted_at: now,
        updated_at: now
      })

    repo.insert_all(IssueLink, [row],
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(tenant_id, story_id)"}
    )

    :ok
  end

  @doc "One tenant's link row for a story, or nil."
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: IssueLink.t() | nil
  def get(tenant_id, story_id) do
    AdminRepo.one(
      from l in IssueLink, where: l.tenant_id == ^tenant_id and l.story_id == ^story_id
    )
  end

  @doc "The links due for an attempt, fleet-wide, oldest first — the drainer's candidates."
  @spec due(pos_integer()) :: [IssueLink.t()]
  def due(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    AdminRepo.all(
      from l in IssueLink,
        where: l.status == :pending,
        where: is_nil(l.next_attempt_at) or l.next_attempt_at <= ^now,
        order_by: [asc: l.inserted_at, asc: l.id],
        limit: ^limit
    )
  end

  @typedoc "What one attempt did."
  @type outcome :: :commented | :abandoned | :deferred | :skipped

  @doc """
  One attempt at posting `link`'s comment, carrying `url`. Returns `{outcome, retry_after}`;
  a non-nil `retry_after` tells the drainer the forge is out of quota.
  """
  @spec attempt(IssueLink.t(), String.t()) :: {outcome(), pos_integer() | nil}
  def attempt(%IssueLink{} = link, url) when is_binary(url) do
    case ForgeOutbox.claim_attempt(IssueLink, link.tenant_id, link.id) do
      {:ok, claimed} -> post(claimed, url)
      {:error, :not_pending} -> {:skipped, nil}
    end
  end

  defp post(link, url) do
    if source_live?(link) do
      link.repo_full_name
      |> PullRequestSource.impl().comment_issue(link.issue_number, body(url))
      |> recorded(link)
    else
      abandon(link, :source_revoked)
      {:abandoned, nil}
    end
  end

  defp recorded(:ok, link) do
    stamp(link,
      status: :commented,
      commented_at: DateTime.utc_now(),
      next_attempt_at: nil,
      last_error: nil
    )

    {:commented, nil}
  end

  defp recorded({:error, reason}, link) do
    cond do
      not MergePrecondition.transient?(reason) ->
        abandon(link, reason)
        {:abandoned, nil}

      link.attempts >= ForgeOutbox.max_attempts() ->
        abandon(link, {:retries_exhausted, reason})
        {:abandoned, nil}

      true ->
        retry_after = MergePrecondition.retry_after(reason)
        wait = ForgeOutbox.wait_seconds(link.attempts, retry_after)

        stamp(link,
          next_attempt_at: DateTime.add(DateTime.utc_now(), wait, :second),
          last_error: ForgeOutbox.error_text(reason)
        )

        {:deferred, retry_after}
    end
  end

  @doc false
  # The comment. Plain text and a URL loopctl built; nothing from the thread is echoed onto a
  # reporter's issue, because entries are untrusted and may name internals.
  @spec body(String.t()) :: String.t()
  def body(url), do: "loopctl is working on this. Follow the change thread here: " <> url

  defp source_live?(link) do
    AdminRepo.exists?(
      from s in Source,
        where:
          s.tenant_id == ^link.tenant_id and s.repo_full_name == ^link.repo_full_name and
            is_nil(s.revoked_at)
    )
  end

  defp abandon(link, reason) do
    Logger.warning(
      "thread issue link abandoned: tenant_id=#{link.tenant_id} story_id=#{link.story_id} " <>
        "reason=#{ForgeOutbox.error_text(reason)}"
    )

    stamp(link,
      status: :abandoned,
      next_attempt_at: nil,
      last_error: ForgeOutbox.error_text(reason)
    )
  end

  defp stamp(link, set) do
    ForgeOutbox.update_pending(IssueLink, link.tenant_id, link.id,
      set: Keyword.put(set, :updated_at, DateTime.utc_now())
    )
  end
end
