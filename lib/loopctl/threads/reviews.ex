defmodule Loopctl.Threads.Reviews do
  @moduledoc """
  The RULES of review on a change thread (US-45.3, Epic 45 PRD §6), and its reads. Nothing
  here writes: every review write goes through one narrow `Loopctl.Threads` entry point
  (`record_review/3`, `record_judgement/5`, `record_fix/4`), which takes the thread lock and
  calls the rules below inside it.

  ## Who judges

  A review is a RUNNER dispatch of kind `review`, placed by loopctl
  (`Loopctl.Delivery.Placement.place_review/4`). Its findings and its verdict arrive over the
  runner socket from the runner holding that dispatch (`Loopctl.Delivery.RunnerReviews`), bound
  to the `thread_reviews` row the placement recorded. No API key is minted for a review and
  none is handed to anyone, so there is no credential whose ceiling, separation or lifetime
  has to be defended: #901 and #905 each lost that defence one round at a time.

  ## Separation

  The reviewer is the runner's AGENT. It is refused `reviewer_not_separate` when it is the
  story's claimant, when it recorded a checkpoint of the thread, or when it is the agent of any
  dispatch on the implementer's lineage CHAIN, above or below the implementer
  (`Loopctl.Dispatches.lineage_same_chain?/2`, the comparison the custody gates use). Decided
  at placement and again, under the thread lock, on every judgement.

  ## Rounds and the ceiling

  A completed round IS a review's one `verdict`. A review placed for round N completes it only
  while exactly N - 1 rounds are complete (`review_round_superseded`), so two reviews of one
  round cannot both count, and a review that ends without a verdict uses no round. Round 2
  always follows round 1. Round 3 is placeable only when a round-2 finding's `introduced_by`
  names a checkpoint that carries a fix written BEFORE the round-2 verdict, so the decision is
  made once and a later fix cannot reopen it. There is never a round 4. When the round that
  reaches the ceiling has a material finding (critical, high or medium), its verdict records a
  `review_ceiling` escalation in the same transaction, and `Loopctl.Workers.ReviewCeilingWorker`
  moves the delivery stage until it lands.

  ## The checkpoint a review reads

  The story's LATEST checkpoint at placement, and only if the current claim recorded it:
  callers never choose one, so a round cannot be placed on a stale checkpoint.

  ## Refusal codes

  None is `self_review_blocked`, which is an L6 byzantine signal that escalates to a tenant-wide
  halt. Every refusal here is `{:error, {status, code, message}}`.
  """

  import Ecto.Query

  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.Review
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.ActorLabel

  @max_rounds 3
  @material [:critical, :high, :medium]
  @max_location_bytes 1024
  # The most fixes a review payload carries, the latest ones; `fixes_truncated` says more exist.
  @max_payload_fixes 100

  @type refusal ::
          {:error, {:forbidden | :conflict | :unprocessable_entity, String.t(), String.t()}}

  @type rounds :: %{
          completed: non_neg_integer(),
          next_round: 1..3 | nil,
          ceiling_reached: boolean()
        }

  @doc "The most rounds a story's review may take."
  @spec max_rounds() :: pos_integer()
  def max_rounds, do: @max_rounds

  @doc "The largest `location`, in bytes, a finding may carry."
  @spec max_location_bytes() :: pos_integer()
  def max_location_bytes, do: @max_location_bytes

  @doc "The most fixes a review payload carries."
  @spec max_payload_fixes() :: pos_integer()
  def max_payload_fixes, do: @max_payload_fixes

  @doc "The severities that count as material for the ceiling."
  @spec material() :: [atom()]
  def material, do: @material

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  The story's review rounds, from `thread_entries` alone: how many are complete, the next
  placeable round (nil at the ceiling), and whether the ceiling is reached.
  """
  @spec rounds(Ecto.UUID.t(), Ecto.UUID.t()) :: rounds()
  def rounds(tenant_id, story_id) do
    {:ok, rounds} = Repo.with_tenant(tenant_id, fn -> compute_rounds(tenant_id, story_id) end)
    rounds
  end

  @doc """
  What a review reads (PRD §6): the story, the checkpoint diff reference, the thread's latest
  page of entries, and the latest #{@max_payload_fixes} fixes with the findings each answers
  (`fixes_truncated` when there are more). Entry bodies are UNTRUSTED text.
  """
  @spec payload(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :not_found}
  def payload(tenant_id, story_id, review_id) do
    {:ok, result} =
      Repo.with_tenant(tenant_id, fn ->
        with %Story{} = story <- Threads.story(tenant_id, story_id) || {:error, :not_found},
             %Review{} = review <- review(tenant_id, story_id, review_id) || {:error, :not_found} do
          {:ok, build_payload(tenant_id, story, review)}
        end
      end)

    result
  end

  defp review(tenant_id, story_id, review_id) do
    Repo.one(
      from r in Review,
        where: r.id == ^review_id and r.tenant_id == ^tenant_id and r.story_id == ^story_id
    )
  end

  # ---------------------------------------------------------------------------
  # Rules, called by `Loopctl.Threads` under the thread lock. Each READS; none writes.
  # ---------------------------------------------------------------------------

  @doc false
  # The story's latest checkpoint, provided the CURRENT claim recorded it.
  @spec latest_checkpoint(Ecto.UUID.t(), Story.t()) :: {:ok, Checkpoint.t()} | refusal()
  def latest_checkpoint(tenant_id, story) do
    latest =
      Repo.one(
        from c in Checkpoint,
          where: c.tenant_id == ^tenant_id and c.story_id == ^story.id,
          order_by: [desc: c.seq],
          limit: 1
      )

    case latest do
      %Checkpoint{claim_epoch: epoch} = checkpoint when epoch == story.claim_epoch ->
        {:ok, checkpoint}

      _none_or_stale ->
        refuse(
          :conflict,
          "no_checkpoint",
          "the current claim has recorded no checkpoint yet; a review reads the latest one"
        )
    end
  end

  @doc false
  @spec implementer_dispatched(Story.t()) :: :ok | refusal()
  def implementer_dispatched(%Story{implementer_dispatch_id: nil}),
    do:
      refuse(
        :conflict,
        "implementer_dispatch_required",
        "the story's claim was not made by a dispatch, so there is no implementer lineage " <>
          "for a review to be separate from"
      )

  def implementer_dispatched(%Story{}), do: :ok

  @doc false
  @spec placeable_round(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, 1..3} | refusal()
  def placeable_round(tenant_id, story_id) do
    case compute_rounds(tenant_id, story_id) do
      %{next_round: nil, completed: completed} ->
        refuse(
          :conflict,
          "review_ceiling_reached",
          "#{completed} review rounds are complete and no further round is placeable: a " <>
            "third round needs a round-2 finding introduced by a round-1 fix, and there is " <>
            "never a fourth"
        )

      %{next_round: round} ->
        {:ok, round}
    end
  end

  @doc false
  # The runner agent `agent_id` may review this story only when it is not the claimant, did
  # not record a checkpoint of the thread, and is the agent of no dispatch on the implementer's
  # lineage chain — an ancestor of the implementer, the implementer itself, or anything below.
  @spec reviewer_separate(Ecto.UUID.t(), Story.t(), Ecto.UUID.t()) :: :ok | refusal()
  def reviewer_separate(tenant_id, story, agent_id) do
    if story.assigned_agent_id == agent_id or
         recorded_checkpoint?(tenant_id, story, agent_id) or
         on_implementer_chain?(tenant_id, story, agent_id),
       do: not_separate(),
       else: :ok
  end

  defp recorded_checkpoint?(tenant_id, story, agent_id) do
    Repo.exists?(
      from e in Entry,
        where:
          e.tenant_id == ^tenant_id and e.story_id == ^story.id and e.kind == :checkpoint and
            e.author_principal == ^ActorLabel.agent(agent_id)
    )
  end

  # Every dispatch of this agent in the implementer's TREE (same root), compared by the
  # custody gates' own same-chain test. A dispatch in another tree cannot be on the chain.
  defp on_implementer_chain?(_tenant_id, %Story{implementer_dispatch_id: nil}, _agent_id),
    do: false

  defp on_implementer_chain?(tenant_id, story, agent_id) do
    case implementer_lineage(tenant_id, story.implementer_dispatch_id) do
      [] ->
        false

      [root | _] = implementer ->
        from(d in Dispatch,
          where: d.tenant_id == ^tenant_id and d.agent_id == ^agent_id,
          where: fragment("?[1] = ?", d.lineage_path, type(^root, Ecto.UUID)),
          select: d.lineage_path
        )
        |> Repo.all()
        |> Enum.any?(&Dispatches.lineage_same_chain?(&1, implementer))
    end
  end

  defp implementer_lineage(tenant_id, implementer_id) do
    Repo.one(
      from d in Dispatch,
        where: d.id == ^implementer_id and d.tenant_id == ^tenant_id,
        select: d.lineage_path
    ) || []
  end

  defp not_separate,
    do:
      refuse(
        :conflict,
        "reviewer_not_separate",
        "the reviewing runner's agent is the story's claimant, recorded a checkpoint of this " <>
          "thread, or is the agent of a dispatch on the implementer's lineage chain"
      )

  @doc false
  @spec review_open(Ecto.UUID.t(), Review.t()) :: :ok | refusal()
  def review_open(tenant_id, review) do
    if Repo.exists?(
         from e in Entry,
           where: e.tenant_id == ^tenant_id and e.review_id == ^review.id and e.kind == :verdict
       ),
       do:
         refuse(
           :conflict,
           "review_closed",
           "this review has recorded its verdict; it may write nothing further"
         ),
       else: :ok
  end

  @doc false
  # A review placed for round N completes it only while N - 1 rounds are complete.
  @spec current_round(Ecto.UUID.t(), Ecto.UUID.t(), Review.t()) :: :ok | refusal()
  def current_round(tenant_id, story_id, review) do
    if map_size(completed_reviews(tenant_id, story_id)) == review.round - 1,
      do: :ok,
      else:
        refuse(
          :conflict,
          "review_round_superseded",
          "round #{review.round} was completed by another review"
        )
  end

  @doc false
  @spec introduced_by_allowed(Review.t(), String.t() | nil) :: :ok | refusal()
  def introduced_by_allowed(%Review{round: 1}, nil), do: :ok

  def introduced_by_allowed(%Review{round: 1}, _introduced_by),
    do:
      refuse(
        :unprocessable_entity,
        "introduced_by_not_allowed",
        "a round-1 finding has no earlier review to have been introduced after"
      )

  def introduced_by_allowed(%Review{}, nil),
    do:
      refuse(
        :unprocessable_entity,
        "introduced_by_required",
        "a finding after round 1 carries introduced_by: a checkpoint id of the story, or none"
      )

  def introduced_by_allowed(%Review{}, "none"), do: :ok

  # "At or before the checkpoint it was found in", ordered by checkpoint seq.
  def introduced_by_allowed(%Review{} = review, checkpoint_id) do
    found_in = Repo.get!(Checkpoint, review.checkpoint_id)

    case Threads.checkpoint_of(review.tenant_id, review.story_id, checkpoint_id) do
      %Checkpoint{seq: seq} when seq <= found_in.seq ->
        :ok

      _other ->
        refuse(
          :unprocessable_entity,
          "introduced_by_invalid",
          "introduced_by must be a checkpoint of this story at or before the reviewed " <>
            "checkpoint, or none"
        )
    end
  end

  @doc false
  # The number of material findings the review recorded, when its verdict reaches the ceiling;
  # zero otherwise. Called after the verdict is inserted, so the count includes it.
  @spec ceiling_material(Ecto.UUID.t(), Ecto.UUID.t(), Review.t()) :: non_neg_integer()
  def ceiling_material(tenant_id, story_id, review) do
    case compute_rounds(tenant_id, story_id) do
      %{ceiling_reached: true} ->
        Repo.aggregate(
          from(e in Entry,
            where:
              e.tenant_id == ^tenant_id and e.review_id == ^review.id and e.kind == :finding and
                e.severity in ^@material
          ),
          :count
        )

      _rounds ->
        0
    end
  end

  @doc false
  @spec fix_checkpoint(Ecto.UUID.t(), Story.t(), Ecto.UUID.t()) ::
          {:ok, Checkpoint.t()} | refusal()
  def fix_checkpoint(tenant_id, story, checkpoint_id) do
    case Threads.checkpoint_of(tenant_id, story.id, checkpoint_id) do
      %Checkpoint{claim_epoch: epoch} = checkpoint when epoch == story.claim_epoch ->
        {:ok, checkpoint}

      _other ->
        refuse(
          :unprocessable_entity,
          "fix_checkpoint_not_current_claim",
          "checkpoint_id must be a checkpoint this story's current claim recorded"
        )
    end
  end

  @doc false
  # Every named finding is a finding of a COMPLETED round of this story, and the fix's
  # checkpoint comes after every checkpoint they were found in (by checkpoint seq).
  @spec answers_findings(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()], Checkpoint.t()) ::
          :ok | refusal()
  def answers_findings(tenant_id, story_id, finding_ids, checkpoint) do
    found_in =
      Repo.all(
        from e in Entry,
          join: c in Checkpoint,
          on: c.id == e.checkpoint_id,
          join: v in Entry,
          on: v.review_id == e.review_id and v.kind == :verdict,
          where:
            e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :finding and
              e.id in ^finding_ids,
          select: c.seq
      )

    cond do
      length(found_in) != length(finding_ids) ->
        refuse(
          :unprocessable_entity,
          "unknown_finding",
          "finding_ids must name findings of this story's completed review rounds"
        )

      Enum.any?(found_in, &(&1 >= checkpoint.seq)) ->
        refuse(
          :unprocessable_entity,
          "fix_checkpoint_not_after_findings",
          "the fix's checkpoint must be recorded after every checkpoint its findings were " <>
            "found in"
        )

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Rounds
  # ---------------------------------------------------------------------------

  defp compute_rounds(tenant_id, story_id) do
    completed = completed_reviews(tenant_id, story_id)
    count = map_size(completed)

    next_round =
      cond do
        count < 2 -> count + 1
        count == 2 and third_round_warranted?(tenant_id, story_id, completed) -> 3
        true -> nil
      end

    %{completed: count, next_round: next_round, ceiling_reached: is_nil(next_round)}
  end

  # `%{round => {review_id, verdict_seq}}` for every review with a verdict. The verdict check
  # in `current_round/3` makes the rounds exactly 1..N.
  defp completed_reviews(tenant_id, story_id) do
    from(e in Entry,
      join: r in Review,
      on: r.id == e.review_id,
      where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :verdict,
      select: {r.round, {r.id, e.seq}}
    )
    |> Repo.all()
    |> Map.new()
  end

  # A round-2 finding introduced by a checkpoint that carries a fix: the defect round 1's own
  # fix put there, which is what a third round exists for. Every fix checkpoint a round-2
  # finding can name IS a round-1 fix's: `introduced_by` is at or before the round-2
  # checkpoint, a fix names only findings of COMPLETED rounds, and a fix of a round-2 finding
  # comes after the checkpoint it was found in.
  #
  # DECIDED ONCE, AT THE ROUND-2 VERDICT: only fixes written before it (by thread `seq`) count.
  defp third_round_warranted?(tenant_id, story_id, %{2 => {round2, verdict_seq}}) do
    fix_checkpoints =
      Repo.all(
        from e in Entry,
          where:
            e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :fix and
              e.seq < ^verdict_seq,
          select: e.checkpoint_id
      )

    fix_checkpoints != [] and
      Repo.exists?(
        from e in Entry,
          where:
            e.tenant_id == ^tenant_id and e.review_id == ^round2 and e.kind == :finding and
              e.introduced_by in ^fix_checkpoints
      )
  end

  # ---------------------------------------------------------------------------
  # The review payload
  # ---------------------------------------------------------------------------

  defp build_payload(tenant_id, story, review) do
    checkpoint = Repo.get!(Checkpoint, review.checkpoint_id)

    parent =
      checkpoint.parent_checkpoint_id && Repo.get(Checkpoint, checkpoint.parent_checkpoint_id)

    max = Threads.max_entry_page()

    latest =
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id and e.story_id == ^story.id,
          order_by: [desc: e.seq],
          limit: ^(max + 1)
      )

    {page, rest} = Enum.split(latest, max)
    {fixes, fixes_truncated} = fixes_with_findings(tenant_id, story.id)

    %{
      review: %{
        id: review.id,
        round: review.round,
        dispatch_id: review.dispatch_id,
        runner_id: review.runner_id,
        agent_id: review.agent_id,
        checkpoint_id: review.checkpoint_id
      },
      story: %{
        id: story.id,
        number: story.number,
        title: story.title,
        description: story.description,
        acceptance_criteria: story.acceptance_criteria
      },
      checkpoint: %{
        id: checkpoint.id,
        seq: checkpoint.seq,
        commit_sha: checkpoint.commit_sha,
        tree_sha: checkpoint.tree_sha,
        parent_commit_sha: parent && parent.commit_sha
      },
      entries: Enum.reverse(page),
      entries_truncated: rest != [],
      fixes: fixes,
      fixes_truncated: fixes_truncated,
      rounds: compute_rounds(tenant_id, story.id)
    }
  end

  # The LATEST page of fixes, oldest first, and the findings they answer. The findings are
  # read by joining the page's fixes (`= ANY(finding_ids)`), so no id list travels as a
  # parameter however many a fix names.
  defp fixes_with_findings(tenant_id, story_id) do
    latest =
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :fix,
          order_by: [desc: e.seq],
          limit: ^(@max_payload_fixes + 1)
      )

    {page, rest} = Enum.split(latest, @max_payload_fixes)
    fixes = Enum.reverse(page)

    findings =
      case fixes do
        [] -> %{}
        [oldest | _] -> answered_findings(tenant_id, story_id, oldest.seq)
      end

    {Enum.map(fixes, fn fix ->
       %{fix: fix, findings: fix.finding_ids |> Enum.map(&findings[&1]) |> Enum.reject(&is_nil/1)}
     end), rest != []}
  end

  defp answered_findings(tenant_id, story_id, from_seq) do
    from(f in Entry,
      join: x in Entry,
      on: x.tenant_id == f.tenant_id and x.story_id == f.story_id,
      where:
        x.tenant_id == ^tenant_id and x.story_id == ^story_id and x.kind == :fix and
          x.seq >= ^from_seq and f.kind == :finding and
          fragment("? = ANY(?)", f.id, x.finding_ids),
      distinct: true,
      select: f
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # ---------------------------------------------------------------------------
  # Canonical forms of what a caller sends
  # ---------------------------------------------------------------------------

  @doc false
  @spec severity(term()) :: {:ok, atom()} | refusal()
  def severity(value) when is_binary(value) do
    case Enum.find(Entry.severities(), &(to_string(&1) == String.downcase(String.trim(value)))) do
      nil -> bad_severity()
      severity -> {:ok, severity}
    end
  end

  def severity(_value), do: bad_severity()

  defp bad_severity,
    do:
      refuse(
        :unprocessable_entity,
        "invalid_severity",
        "severity must be one of #{Enum.join(Entry.severities(), ", ")}"
      )

  @doc false
  @spec location(term()) :: {:ok, String.t() | nil} | refusal()
  def location(nil), do: {:ok, nil}

  def location(value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> {:ok, nil}
      byte_size(value) > @max_location_bytes -> bad_location()
      true -> {:ok, value}
    end
  end

  def location(_value), do: bad_location()

  defp bad_location,
    do:
      refuse(
        :unprocessable_entity,
        "invalid_location",
        "location must be a string of at most #{@max_location_bytes} bytes"
      )

  @doc false
  # `none` in any case, or a checkpoint id in its canonical lowercase form.
  @spec introduced_by(term()) :: {:ok, String.t() | nil} | refusal()
  def introduced_by(nil), do: {:ok, nil}

  def introduced_by(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.downcase(trimmed) == "none" -> {:ok, "none"}
      match?({:ok, _}, Ecto.UUID.cast(trimmed)) -> Ecto.UUID.cast(trimmed)
      true -> bad_introduced_by()
    end
  end

  def introduced_by(_value), do: bad_introduced_by()

  defp bad_introduced_by,
    do:
      refuse(
        :unprocessable_entity,
        "introduced_by_invalid",
        "introduced_by must be a checkpoint id of this story, or none"
      )

  @doc false
  @spec finding_ids(term()) :: {:ok, [Ecto.UUID.t()]} | refusal()
  def finding_ids(ids) when is_list(ids) and ids != [] do
    cast = Enum.map(ids, &cast_uuid/1)

    if Enum.all?(cast, &match?({:ok, _}, &1)),
      do: {:ok, cast |> Enum.map(fn {:ok, id} -> id end) |> Enum.uniq() |> Enum.sort()},
      else: bad_finding_ids()
  end

  def finding_ids(_ids), do: bad_finding_ids()

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp bad_finding_ids,
    do:
      refuse(
        :unprocessable_entity,
        "finding_ids_required",
        "finding_ids must be a non-empty list of finding ids"
      )

  defp refuse(status, code, message), do: {:error, {status, code, message}}
end
