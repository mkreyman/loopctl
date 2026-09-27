defmodule Loopctl.Threads.IssueLinks do
  @moduledoc """
  The outbox for the comment that links a story's intake issue to its thread page (US-45.7,
  AC-45.7.4, PRD §6.1: "the intake issue on GitHub links to it").

  ## When the link is written

  Once the thread has a checkpoint. A story is a thread from the moment it exists, but until
  its claimant reports a commit the page has nothing on it but the story; the first checkpoint
  is when there is work to look at. Linking at claim time instead would link threads that never
  produce a commit.

  The intent is DERIVED from durable state rather than written beside the checkpoint:
  `record_due/1` finds every intake story with a checkpoint and no link row and writes one. So
  a thread whose checkpoints predate this code is linked the same way as a new one, and no
  checkpoint path carries a second write it could forget.

  ## Two halves, both from `Loopctl.Workers.ThreadIssueLinkWorker`

  - `record_due/1` — a bounded fleet-wide read and an insert per story. The unique index on
    `(tenant_id, story_id)` and `ON CONFLICT DO NOTHING` make it once per story, however many
    sweeps overlap.
  - `attempt/2` — with NOTHING held: a compare-and-set claim, one bounded forge call, one short
    write.

  ## Can a retry do it twice?

  The claim is a CAS on `:pending` AND due that pushes `next_attempt_at` forward, so two
  drainers cannot both post. A node that dies after GitHub accepted the comment and before
  `mark_commented/2` committed re-posts it after the in-flight backoff. That is the one window,
  and it is the cost `Loopctl.Delivery.IssueCloser` accepts for its own comment: a duplicated
  link is visible and harmless, and closing the window would need a transaction held across
  the forge call.

  ## Isolation

  Both halves are fleet-wide on `AdminRepo`, as the closure outbox's drain is: every statement
  that addresses a row carries an explicit `tenant_id`, and every join matches it on both sides.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Threads.IssueLink
  alias Loopctl.WorkBreakdown.Story

  @max_attempts 6
  # The same schedule the closure outbox settled on, starting above the two-minute cron.
  @backoff_seconds [180, 360, 720, 1_440, 2_880]
  @in_flight_backoff_seconds 180

  @doc "How many transient attempts a link gets before it is abandoned."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  Writes a link row for up to `limit` intake stories whose thread has a checkpoint and has
  none yet, fleet-wide. A story whose intake source is revoked is skipped: the tenant
  disconnected that repository. Returns how many rows it wrote.
  """
  @spec record_due(pos_integer()) :: non_neg_integer()
  def record_due(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    rows =
      from(s in Story,
        as: :story,
        join: r in Record,
        on: r.id == s.intake_record_id and r.tenant_id == s.tenant_id,
        join: src in Source,
        on: src.id == r.source_id and src.tenant_id == r.tenant_id,
        where: is_nil(src.revoked_at) and r.issue_number > 0,
        where:
          exists(
            from c in Checkpoint,
              where:
                c.tenant_id == parent_as(:story).tenant_id and
                  c.story_id == parent_as(:story).id and c.kind == :checkpoint
          ),
        where:
          not exists(
            from l in IssueLink,
              where:
                l.tenant_id == parent_as(:story).tenant_id and
                  l.story_id == parent_as(:story).id
          ),
        limit: ^limit,
        select: %{
          tenant_id: s.tenant_id,
          story_id: s.id,
          repo_full_name: src.repo_full_name,
          issue_number: r.issue_number
        }
      )
      |> AdminRepo.all()
      |> Enum.map(
        &Map.merge(&1, %{
          id: Ecto.UUID.generate(),
          status: :pending,
          attempts: 0,
          inserted_at: now,
          updated_at: now
        })
      )

    {count, _} =
      AdminRepo.insert_all(IssueLink, rows,
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, "(tenant_id, story_id)"}
      )

    count
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
    case claim(link) do
      {:ok, claimed} -> post(claimed, url)
      :not_pending -> {:skipped, nil}
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

      link.attempts >= @max_attempts ->
        abandon(link, {:retries_exhausted, reason})
        {:abandoned, nil}

      true ->
        retry_after = MergePrecondition.retry_after(reason)
        backoff = Enum.at(@backoff_seconds, link.attempts - 1, List.last(@backoff_seconds))
        wait = max(backoff, retry_after || 0)

        stamp(link,
          next_attempt_at: DateTime.add(DateTime.utc_now(), wait, :second),
          last_error: error_text(reason)
        )

        {:deferred, retry_after}
    end
  end

  @doc false
  # The comment. Plain text and a URL loopctl built; nothing from the thread is echoed onto a
  # reporter's issue, because entries are untrusted and may name internals.
  @spec body(String.t()) :: String.t()
  def body(url), do: "loopctl is working on this. Follow the change thread here: " <> url

  # The CAS: `:pending` AND due, pushing `next_attempt_at` forward so a second drainer holding
  # the same candidate matches nothing.
  defp claim(link) do
    now = DateTime.utc_now()

    AdminRepo.update_all(
      from(l in IssueLink,
        where: l.id == ^link.id and l.tenant_id == ^link.tenant_id and l.status == :pending,
        where: is_nil(l.next_attempt_at) or l.next_attempt_at <= ^now,
        select: l
      ),
      set: [
        next_attempt_at: DateTime.add(now, @in_flight_backoff_seconds, :second),
        updated_at: now
      ],
      inc: [attempts: 1]
    )
    |> case do
      {1, [claimed]} -> {:ok, claimed}
      {0, _} -> :not_pending
    end
  end

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
        "reason=#{error_text(reason)}"
    )

    stamp(link, status: :abandoned, next_attempt_at: nil, last_error: error_text(reason))
  end

  defp stamp(link, set) do
    AdminRepo.update_all(
      from(l in IssueLink,
        where: l.id == ^link.id and l.tenant_id == ^link.tenant_id and l.status == :pending
      ),
      set: Keyword.put(set, :updated_at, DateTime.utc_now())
    )
  end

  defp error_text(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 2_000)
end
