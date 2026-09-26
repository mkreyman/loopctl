defmodule Loopctl.Threads.Reviews do
  @moduledoc """
  Review on a change thread (US-45.3, Epic 45 PRD §6): loopctl places a review as its own
  dispatch, that dispatch's key writes `finding` and `verdict` entries bound to the checkpoint
  it reads, the claimant writes `fix` entries naming the findings they answer, and the round
  count and its ceiling are computed from `thread_entries` alone.

  ## Who judges: a dispatch loopctl placed, never an inferred key

  #901 decided who may judge a change by inferring separation from the calling key (its
  agent, its lineage, whether it wrote a checkpoint), and each of three review rounds found a
  way around the inference. So nothing here infers it. `place/4` MINTS the reviewer's dispatch
  and records it in `thread_reviews`; a `finding` or `verdict` is accepted only from the key
  that dispatch minted (`Dispatches.dispatch_for_api_key/2`, the exact minting row, never a
  lineage walk), and it is bound to that review and to the checkpoint it was placed to read.
  Every other key, the implementer's, a released implementer's, a user's, is refused
  `review_dispatch_required`.

  ## Where the review dispatch sits

  A SIBLING of the implementer's dispatch: its parent is the implementer's parent, so it is
  under the same orchestrator root and never on the implementer's chain (neither its ancestor
  nor its descendant, which is what `Dispatches.lineage_same_chain?/2` compares). The caller
  placing it must hold that parent in its own lineage, the lineage ceiling
  `LoopctlWeb.DispatchController` applies, and must not itself be on the implementer's chain.
  Its agent must not be a principal that recorded a checkpoint of the thread, nor the story's
  claimant, which is checked again on every judgement write because a claim can move to the
  reviewer's agent after placement.

  An implementer's parent that has been revoked or has expired cannot parent a new dispatch
  (`Dispatches.create_dispatch/3` refuses an inactive parent), so no review can be placed as
  its sibling: `review_parent_inactive`. A story whose claim no dispatch minted has no
  implementer lineage to be separate from, and is refused `implementer_dispatch_required`.

  ## Rounds and the ceiling

  A completed round IS a review's one `verdict` (a partial unique index holds it to one). A
  review placed for round N may write its verdict only while exactly N - 1 rounds are
  complete, so two reviews placed for the same round cannot both complete it
  (`review_round_superseded`), and a dispatch that ends without a verdict uses no round.
  Round 2 is always placeable after round 1. Round 3 is placeable only when a round-2 finding's
  `introduced_by` names a checkpoint a round-1 fix is carried by. Round 4 never is.

  When the ceiling is reached with a material finding (severity critical, high or medium) in
  the round that reached it, that round's verdict also writes an `escalation` entry
  (`review_ceiling`) in the same transaction, and after the commit the story's delivery stage,
  when it has one at a stage a session may escalate from, is moved to `escalated`. The stage
  move is best-effort: the placement refusal is computed from the entries and does not depend
  on it, and a failure is logged.

  ## Refusal codes

  None of them is `self_review_blocked`, which is an L6 byzantine signal that escalates to a
  tenant-wide halt. A key that is not a review dispatch's is a configuration of the caller, not
  byzantium, and gets its own code.

  ## Retries

  Every write is idempotent per author on `idempotency_key` when it is the SAME write, as a
  thread entry is (`Loopctl.Threads`). A resend is answered from its row before any other
  check, so a verdict whose acknowledgement was lost is answered rather than refused
  `review_closed`. `place/4` is NOT idempotent: it mints a credential, and a retried placement
  mints a second review dispatch for the same round, which is harmless because only one of
  them can complete the round.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.Agents.Agent
  alias Loopctl.AuditChain
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Auth.Role
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Tenants
  alias Loopctl.Threads
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.Review
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.ActorLabel

  @max_rounds 3
  @material [:critical, :high, :medium]
  @max_location_bytes 1024
  @escalation_principal "control:review_ceiling"

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

  # ---------------------------------------------------------------------------
  # Placement
  # ---------------------------------------------------------------------------

  @doc """
  Places a review of `story_id`'s thread: mints the reviewer's dispatch as a sibling of the
  implementer's and records it for the next round.

  `caller` is the key the request authenticated with; its lineage and role are resolved from
  it, never taken as options.

  ## Options

  - `:agent_id` (required) — the agent the review dispatch acts as. Not the story's claimant,
    and not a principal that recorded a checkpoint of the thread.
  - `:checkpoint_id` — the checkpoint to review; the thread's latest when absent.
  - `:expires_in_seconds` — the review key's lifetime, capped by `Dispatches.create_dispatch/3`.

  Returns `{:ok, %{review: review, raw_key: key}}`. The raw key is returned once, here.
  """
  @spec place(Ecto.UUID.t(), Ecto.UUID.t(), ApiKey.t(), keyword()) ::
          {:ok, %{review: Review.t(), raw_key: String.t()}}
          | {:error, :not_found | :not_authorized | :tenant_halted | :custody_tier_required}
          | refusal()
  def place(tenant_id, story_id, %ApiKey{tenant_id: tenant_id} = caller, opts) do
    with {:ok, agent_id} <- required_uuid(Keyword.get(opts, :agent_id), "agent_id"),
         :ok <- valid_expiry(Keyword.get(opts, :expires_in_seconds)),
         {:ok, checkpoint_ref} <-
           optional_uuid(Keyword.get(opts, :checkpoint_id), "checkpoint_id"),
         :ok <- placer_role(caller),
         :ok <- not_halted(tenant_id),
         :ok <- Tenants.require_human_anchor(tenant_id),
         {:ok, target} <- review_target(tenant_id, story_id, agent_id, checkpoint_ref),
         caller_lineage = Dispatches.lineage_for_api_key(tenant_id, caller.id),
         {:ok, parent_id} <- review_parent(tenant_id, target.story, caller, caller_lineage),
         {:ok, minted} <-
           mint(tenant_id, story_id, parent_id, agent_id, caller_lineage, opts) do
      record_review(tenant_id, target, minted, caller, caller_lineage)
    end
  end

  def place(_tenant_id, _story_id, _caller, _opts), do: {:error, :not_authorized}

  defp placer_role(%ApiKey{role: role}) do
    if Role.role_at_least?(role, :orchestrator),
      do: :ok,
      else: refuse(:forbidden, "insufficient_role", "placing a review needs an orchestrator key")
  end

  # Read FRESH, as `Loopctl.Delivery.Placement` does: a placement mints a credential, which is
  # custody progress a halted tenant must not make.
  defp not_halted(tenant_id) do
    if Runners.custody_halted?(tenant_id), do: {:error, :tenant_halted}, else: :ok
  end

  defp review_target(tenant_id, story_id, agent_id, checkpoint_ref) do
    {:ok, result} =
      Repo.with_tenant(tenant_id, fn ->
        with {:ok, story} <- story(tenant_id, story_id),
             :ok <- implementer_dispatched(story),
             :ok <- tenant_agent(tenant_id, agent_id),
             :ok <- reviewer_separate(tenant_id, story, agent_id),
             {:ok, checkpoint} <- target_checkpoint(tenant_id, story_id, checkpoint_ref),
             {:ok, round} <- placeable_round(tenant_id, story_id) do
          {:ok, %{story: story, agent_id: agent_id, checkpoint: checkpoint, round: round}}
        end
      end)

    result
  end

  defp story(tenant_id, story_id) do
    case Repo.one(from s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

  defp implementer_dispatched(%Story{implementer_dispatch_id: nil}),
    do:
      refuse(
        :conflict,
        "implementer_dispatch_required",
        "the story's claim was not made by a dispatch, so there is no implementer lineage " <>
          "for a review to be separate from"
      )

  defp implementer_dispatched(%Story{}), do: :ok

  defp tenant_agent(tenant_id, agent_id) do
    if Repo.exists?(from a in Agent, where: a.id == ^agent_id and a.tenant_id == ^tenant_id),
      do: :ok,
      else:
        refuse(:unprocessable_entity, "unknown_agent", "agent_id is not an agent of this tenant")
  end

  # The reviewer's principal is `agent:<agent_id>`, the label every key with that agent writes
  # under (`LoopctlWeb.ActorLabel`). It may not be the story's claimant, and it may not be a
  # principal that recorded a checkpoint of this thread under any claim.
  defp reviewer_separate(tenant_id, story, agent_id) do
    recorded_checkpoint? =
      Repo.exists?(
        from e in Entry,
          where:
            e.tenant_id == ^tenant_id and e.story_id == ^story.id and e.kind == :checkpoint and
              e.author_principal == ^ActorLabel.agent(agent_id)
      )

    if story.assigned_agent_id == agent_id or recorded_checkpoint?,
      do:
        refuse(
          :conflict,
          "reviewer_not_separate",
          "the review's agent is the story's claimant or recorded a checkpoint of this thread"
        ),
      else: :ok
  end

  defp target_checkpoint(tenant_id, story_id, nil) do
    case Repo.one(
           from c in Checkpoint,
             where: c.tenant_id == ^tenant_id and c.story_id == ^story_id,
             order_by: [desc: c.seq],
             limit: 1
         ) do
      nil -> refuse(:conflict, "no_checkpoint", "the thread has no checkpoint to review")
      checkpoint -> {:ok, checkpoint}
    end
  end

  defp target_checkpoint(tenant_id, story_id, checkpoint_id) do
    case checkpoint_of_story(tenant_id, story_id, checkpoint_id) do
      nil ->
        refuse(
          :unprocessable_entity,
          "unknown_checkpoint",
          "checkpoint_id is not a checkpoint of this story"
        )

      checkpoint ->
        {:ok, checkpoint}
    end
  end

  defp placeable_round(tenant_id, story_id) do
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

  # The implementer's parent, which the review shares. The caller must not be on the
  # implementer's chain, and must hold that parent in its lineage — the ceiling
  # `LoopctlWeb.DispatchController` applies, including its two unlineaged cases: the tenant's
  # operator key may parent anywhere, a root included, and a legacy unlineaged key may parent
  # under an existing dispatch but never start a root.
  defp review_parent(tenant_id, story, caller, caller_lineage) do
    implementer_id = story.implementer_dispatch_id
    operator? = caller_lineage == [] and Role.role_at_least?(caller.role, :user)

    with :ok <- off_implementer_chain(implementer_id, caller_lineage),
         {:ok, implementer} <- implementer_dispatch(tenant_id, implementer_id) do
      parent_id = implementer.parent_dispatch_id

      cond do
        is_nil(parent_id) and not operator? ->
          refuse(
            :forbidden,
            "root_dispatch_forbidden",
            "the implementer's dispatch is a root, so its sibling is a root, which only the " <>
              "tenant's operator key may mint"
          )

        is_nil(parent_id) or caller_lineage == [] or parent_id in caller_lineage ->
          {:ok, parent_id}

        true ->
          refuse(
            :forbidden,
            "parent_outside_caller_lineage",
            "the implementer's parent dispatch is not in the caller's lineage"
          )
      end
    end
  end

  defp off_implementer_chain(implementer_id, caller_lineage) do
    if implementer_id in caller_lineage,
      do:
        refuse(
          :forbidden,
          "review_placer_on_implementer_chain",
          "the caller is the implementer's dispatch or one of its descendants"
        ),
      else: :ok
  end

  defp implementer_dispatch(tenant_id, implementer_id) do
    case Dispatches.get_dispatch(tenant_id, implementer_id) do
      {:ok, dispatch} -> {:ok, dispatch}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp mint(tenant_id, story_id, parent_id, agent_id, caller_lineage, opts) do
    attrs =
      %{parent_dispatch_id: parent_id, role: :agent, agent_id: agent_id, story_id: story_id}
      |> put_expiry(Keyword.get(opts, :expires_in_seconds))

    case Dispatches.create_dispatch(tenant_id, attrs, actor_lineage: caller_lineage) do
      {:ok, minted} ->
        {:ok, minted}

      {:error, %Ecto.Changeset{} = changeset} ->
        busy_or(changeset)

      {:error, :parent_not_found} ->
        refuse(
          :conflict,
          "review_parent_inactive",
          "the implementer's parent dispatch is revoked or expired, so no review can be " <>
            "placed as the implementer's sibling"
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An agent holds one active key per role (`api_keys_one_role_per_agent_idx`), and a review
  # dispatch's key is an agent-role key, so an agent with a live one cannot take another.
  defp busy_or(%Ecto.Changeset{errors: errors} = changeset) do
    busy? =
      Enum.any?(errors, fn {_field, {_msg, opts}} ->
        opts[:constraint_name] == "api_keys_one_role_per_agent_idx"
      end)

    if busy?,
      do:
        refuse(
          :conflict,
          "reviewer_agent_busy",
          "the agent already holds an active agent-role key (one per agent); revoke its " <>
            "dispatch or place the review for another agent"
        ),
      else: {:error, changeset}
  end

  defp valid_expiry(nil), do: :ok
  defp valid_expiry(seconds) when is_integer(seconds) and seconds > 0, do: :ok

  defp valid_expiry(_seconds),
    do:
      refuse(
        :unprocessable_entity,
        "invalid_expires_in_seconds",
        "expires_in_seconds must be a positive integer"
      )

  defp put_expiry(attrs, nil), do: attrs
  defp put_expiry(attrs, seconds), do: Map.put(attrs, :expires_in_seconds, seconds)

  defp record_review(tenant_id, target, %{dispatch: dispatch, raw_key: raw_key}, caller, lineage) do
    story_id = target.story.id

    result =
      Threads.write_locked(tenant_id, story_id, fn ->
        case Threads.locked_story(tenant_id, story_id) do
          nil -> {:error, :not_found}
          _story -> insert_review(tenant_id, target, dispatch, caller, lineage)
        end
      end)

    case result do
      {:ok, review, :created} ->
        {:ok, %{review: review, raw_key: raw_key}}

      error ->
        # The dispatch committed on `AdminRepo` before this transaction opened. A review row
        # that did not follow leaves a live key nothing will accept a judgement from, so it
        # is revoked rather than left to expire.
        _ = Dispatches.revoke(tenant_id, dispatch.id, actor_lineage: lineage)
        error
    end
  end

  defp insert_review(tenant_id, target, dispatch, caller, lineage) do
    review =
      Repo.insert!(%Review{
        tenant_id: tenant_id,
        story_id: target.story.id,
        dispatch_id: dispatch.id,
        agent_id: target.agent_id,
        checkpoint_id: target.checkpoint.id,
        round: target.round,
        placed_by: ActorLabel.of(caller)
      })

    with {:ok, chain_entry} <-
           AuditChain.append_in_tenant_transaction(tenant_id, %{
             action: "thread_review_placed",
             actor_lineage: lineage,
             entity_type: "story",
             entity_id: target.story.id,
             payload: %{
               "review_id" => review.id,
               "dispatch_id" => dispatch.id,
               "lineage_path" => dispatch.lineage_path,
               "agent_id" => review.agent_id,
               "checkpoint_id" => review.checkpoint_id,
               "round" => review.round
             }
           }) do
      {:ok, review, :created, [chain_entry]}
    end
  end

  # ---------------------------------------------------------------------------
  # Findings and verdicts
  # ---------------------------------------------------------------------------

  @doc """
  Records a `finding` from the review dispatch that minted `key`, bound to that review and
  to the checkpoint it reads.

  `attrs` carries `idempotency_key`, `body` (the failure scenario), `severity` (critical,
  high, medium, low), an optional `location` (`file:line`), and `introduced_by`: refused in
  round 1, required after it, as a checkpoint id of the story at or before the reviewed
  checkpoint, or `none`. It is stored canonicalised.
  """
  @spec record_finding(Ecto.UUID.t(), Ecto.UUID.t(), ApiKey.t(), map()) ::
          {:ok, Entry.t(), :created | :existing}
          | {:error, term()}
          | {:error, :unprocessable_entity, term()}
  def record_finding(tenant_id, story_id, %ApiKey{} = key, attrs) do
    changeset = Entry.changeset(%Entry{}, entry_attrs(attrs, "finding"))

    with :ok <- valid(changeset),
         {:ok, severity} <- severity(attr(attrs, "severity")),
         {:ok, location} <- location(attr(attrs, "location")),
         {:ok, introduced_by} <- canonical_introduced_by(attr(attrs, "introduced_by")),
         :ok <- Threads.screen(changeset, tenant_id, story_id),
         :ok <- no_secret_location(location, tenant_id, story_id),
         {:ok, dispatch} <- review_dispatch(tenant_id, key) do
      changeset =
        Ecto.Changeset.change(changeset,
          severity: severity,
          location: location,
          introduced_by: introduced_by
        )

      judge(tenant_id, story_id, key, dispatch, changeset, &finding_locked/5)
    end
  end

  @doc """
  Records the `verdict` of the review dispatch that minted `key`: the one entry that
  completes its round. `attrs` carries `idempotency_key` and `body`.
  """
  @spec record_verdict(Ecto.UUID.t(), Ecto.UUID.t(), ApiKey.t(), map()) ::
          {:ok, %{entry: Entry.t(), escalation: Entry.t() | nil}, :created | :existing}
          | {:error, term()}
          | {:error, :unprocessable_entity, term()}
  def record_verdict(tenant_id, story_id, %ApiKey{} = key, attrs) do
    changeset = Entry.changeset(%Entry{}, entry_attrs(attrs, "verdict"))

    with :ok <- valid(changeset),
         :ok <- Threads.screen(changeset, tenant_id, story_id),
         {:ok, dispatch} <- review_dispatch(tenant_id, key) do
      case judge(tenant_id, story_id, key, dispatch, changeset, &verdict_locked/5) do
        {:ok, written, :created} = ok ->
          close_review_dispatch(tenant_id, dispatch)
          escalate_stage(tenant_id, story_id, dispatch.lineage_path, written.escalation)
          ok

        # A resend is answered from the verdict's row, and its escalation already happened.
        {:ok, %Entry{} = verdict, :existing} ->
          {:ok, %{entry: verdict, escalation: nil}, :existing}

        other ->
          other
      end
    end
  end

  defp entry_attrs(attrs, kind) do
    %{
      "kind" => kind,
      "idempotency_key" => attr(attrs, "idempotency_key"),
      "body" => attr(attrs, "body")
    }
  end

  defp attr(attrs, key), do: Map.get(attrs, key)

  defp valid(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid(changeset), do: {:error, changeset}

  # The dispatch that minted `key`, exactly: not a lineage, not an agent. `:none` for a key
  # no dispatch minted (an operator's, a legacy one) or whose dispatch was revoked.
  defp review_dispatch(tenant_id, %ApiKey{tenant_id: tenant_id, id: key_id}) do
    case Dispatches.dispatch_for_api_key(tenant_id, key_id) do
      {:ok, dispatch} -> {:ok, dispatch}
      :none -> not_a_review()
    end
  end

  defp review_dispatch(_tenant_id, _key), do: not_a_review()

  defp not_a_review,
    do:
      refuse(
        :forbidden,
        "review_dispatch_required",
        "findings and verdicts are accepted only on the key loopctl minted for a review " <>
          "dispatch of this story (thread_place_review)"
      )

  # The shared write: under the story lock, find the review this dispatch was placed as, bind
  # the entry to it and its checkpoint, answer a resend from its row, and only then judge.
  defp judge(tenant_id, story_id, key, dispatch, changeset, locked_fun) do
    author = ActorLabel.of(key)

    Threads.write_locked(tenant_id, story_id, fn ->
      with {:story, %Story{} = story} <- {:story, Threads.locked_story(tenant_id, story_id)},
           {:review, %Review{} = review} <-
             {:review, review_for(tenant_id, story_id, dispatch.id)} do
        changeset =
          Ecto.Changeset.change(changeset,
            review_id: review.id,
            checkpoint_id: review.checkpoint_id
          )

        Threads.replayed(tenant_id, story_id, author, changeset) ||
          judge_new(story, review, changeset, author, dispatch, locked_fun)
      else
        {:story, nil} -> {:error, :not_found}
        {:review, nil} -> not_a_review()
      end
    end)
  end

  defp judge_new(story, review, changeset, author, dispatch, locked_fun) do
    with :ok <- review_open(review.tenant_id, review),
         :ok <- reviewer_separate(review.tenant_id, story, review.agent_id) do
      locked_fun.(story, review, changeset, author, dispatch)
    end
  end

  defp review_for(tenant_id, story_id, dispatch_id) do
    Repo.one(
      from r in Review,
        where:
          r.tenant_id == ^tenant_id and r.story_id == ^story_id and
            r.dispatch_id == ^dispatch_id
    )
  end

  defp review_open(tenant_id, review) do
    if verdict_of(tenant_id, review.id),
      do:
        refuse(
          :conflict,
          "review_closed",
          "this review dispatch has recorded its verdict; it may write nothing further"
        ),
      else: :ok
  end

  defp verdict_of(tenant_id, review_id) do
    Repo.exists?(
      from e in Entry,
        where: e.tenant_id == ^tenant_id and e.review_id == ^review_id and e.kind == :verdict
    )
  end

  defp finding_locked(story, review, changeset, author, dispatch) do
    introduced_by = Ecto.Changeset.get_field(changeset, :introduced_by)

    with :ok <- current_round(review.tenant_id, story.id, review),
         :ok <- introduced_by_allowed(review, introduced_by) do
      Threads.insert_entry(review.tenant_id, story.id, changeset,
        author_principal: author,
        actor_lineage: dispatch.lineage_path
      )
    end
  end

  defp introduced_by_allowed(%Review{round: 1}, nil), do: :ok

  defp introduced_by_allowed(%Review{round: 1}, _introduced_by),
    do:
      refuse(
        :unprocessable_entity,
        "introduced_by_not_allowed",
        "a round-1 finding has no earlier review to have been introduced after"
      )

  defp introduced_by_allowed(%Review{}, nil),
    do:
      refuse(
        :unprocessable_entity,
        "introduced_by_required",
        "a finding after round 1 carries introduced_by: a checkpoint id of the story, or none"
      )

  defp introduced_by_allowed(%Review{}, "none"), do: :ok

  # "At or before the checkpoint it was found in", ordered by checkpoint seq.
  defp introduced_by_allowed(%Review{} = review, checkpoint_id) do
    found_in = Repo.get!(Checkpoint, review.checkpoint_id)

    case checkpoint_of_story(review.tenant_id, review.story_id, checkpoint_id) do
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

  defp verdict_locked(story, review, changeset, author, dispatch) do
    tenant_id = review.tenant_id

    with :ok <- current_round(tenant_id, story.id, review),
         {:ok, verdict, :created, chained} <-
           Threads.insert_entry(tenant_id, story.id, changeset,
             author_principal: author,
             actor_lineage: dispatch.lineage_path
           ),
         {:ok, escalation, escalation_chained} <-
           ceiling_escalation(tenant_id, story.id, review, dispatch) do
      {:ok, %{entry: verdict, escalation: escalation}, :created, chained ++ escalation_chained}
    end
  end

  # A review placed for round N completes it only while N - 1 rounds are complete: two reviews
  # placed for one round cannot both count, and a stale one cannot become a later round.
  defp current_round(tenant_id, story_id, review) do
    if completed_rounds(tenant_id, story_id) == review.round - 1,
      do: :ok,
      else:
        refuse(
          :conflict,
          "review_round_superseded",
          "round #{review.round} was completed by another review dispatch"
        )
  end

  # The round this verdict just completed reached the ceiling with a material finding in it:
  # the story escalates with `review_ceiling`, recorded on the thread in this transaction.
  defp ceiling_escalation(tenant_id, story_id, review, dispatch) do
    material = material_findings(tenant_id, review.id)

    case compute_rounds(tenant_id, story_id) do
      %{ceiling_reached: true} when material > 0 ->
        changeset =
          %{
            kind: :escalation,
            idempotency_key: "loopctl:review_ceiling:#{review.id}",
            body: ceiling_reason(review.round, material),
            checkpoint_id: review.checkpoint_id
          }
          |> Entry.system_changeset()
          |> Ecto.Changeset.put_change(:review_id, review.id)

        with {:ok, entry, :created, chained} <-
               Threads.insert_entry(tenant_id, story_id, changeset,
                 author_principal: @escalation_principal,
                 actor_lineage: dispatch.lineage_path
               ),
             do: {:ok, entry, chained}

      _rounds ->
        {:ok, nil, []}
    end
  end

  defp ceiling_reason(round, material) do
    "review_ceiling: round #{round} of #{@max_rounds} left #{material} material finding(s) " <>
      "and no further round is placeable; the remedy is a rewrite, not another round"
  end

  defp material_findings(tenant_id, review_id) do
    Repo.aggregate(
      from(e in Entry,
        where:
          e.tenant_id == ^tenant_id and e.review_id == ^review_id and e.kind == :finding and
            e.severity in ^@material
      ),
      :count
    )
  end

  # After the commit: the review is over, so its dispatch and key are revoked. Left live, the
  # key would hold its agent's one active agent-role key (`api_keys_one_role_per_agent_idx`)
  # until its TTL, and the next round could not be placed for that agent. A resend of the
  # verdict after this is refused at authentication; the thread shows the verdict landed.
  defp close_review_dispatch(tenant_id, dispatch) do
    case Dispatches.revoke(tenant_id, dispatch.id, actor_lineage: dispatch.lineage_path) do
      {:ok, _count} ->
        :ok

      error ->
        Logger.warning(
          "review verdict recorded but its dispatch was not revoked: #{inspect(error)} " <>
            "tenant_id=#{tenant_id} dispatch_id=#{dispatch.id}",
          tenant_id: tenant_id
        )

        :ok
    end
  end

  # After the commit: move the story's delivery stage to `escalated` when it has one at a
  # stage a session may escalate from. The entry is the record; this is the stage machine
  # catching up with it, and a failure is logged rather than raised into the verdict's reply.
  defp escalate_stage(_tenant_id, _story_id, _lineage, nil), do: :ok

  defp escalate_stage(tenant_id, story_id, lineage, %Entry{body: reason}) do
    with {:ok, %StoryStage{stage: stage}, epoch} <- stage_and_epoch(tenant_id, story_id),
         {:ok, transition} <- escalation_edge(stage),
         {:ok, _row} <-
           Stages.advance(tenant_id, story_id, transition,
             claim_epoch: epoch,
             actor_lineage: lineage,
             actor_label: @escalation_principal,
             reason: reason
           ) do
      :ok
    else
      :no_stage ->
        :ok

      error ->
        Logger.warning(
          "review_ceiling recorded on the thread but the delivery stage was not escalated: " <>
            "#{inspect(error)} tenant_id=#{tenant_id} story_id=#{story_id}",
          tenant_id: tenant_id,
          story_id: story_id
        )

        :ok
    end
  end

  defp escalation_edge(stage) do
    transition = {stage, :escalated, :session_escalated}

    if transition in StageMachine.transitions(),
      do: {:ok, transition},
      else: {:error, {:no_escalation_edge, stage}}
  end

  defp stage_and_epoch(tenant_id, story_id) do
    {:ok, found} =
      Repo.with_tenant(tenant_id, fn ->
        {Repo.one(
           from r in StoryStage, where: r.tenant_id == ^tenant_id and r.story_id == ^story_id
         ),
         Repo.one(
           from s in Story,
             where: s.id == ^story_id and s.tenant_id == ^tenant_id,
             select: s.claim_epoch
         )}
      end)

    case found do
      {nil, _epoch} -> :no_stage
      {stage, epoch} -> {:ok, stage, epoch}
    end
  end

  # ---------------------------------------------------------------------------
  # Fixes
  # ---------------------------------------------------------------------------

  @doc """
  Records a `fix` from the story's current claimant: the checkpoint that carries it and the
  findings it answers.

  `attrs` carries `claim_epoch`, `checkpoint_id`, `finding_ids` (at least one finding of a
  completed round of this story), `idempotency_key` and `body` (the fix's reasoning). The
  checkpoint must be of the current claim and recorded after every checkpoint its findings
  were found in.
  """
  @spec record_fix(Ecto.UUID.t(), Ecto.UUID.t(), ApiKey.t(), map()) ::
          {:ok, Entry.t(), :created | :existing}
          | {:error, term()}
          | {:error, :unprocessable_entity, term()}
  def record_fix(tenant_id, story_id, %ApiKey{tenant_id: tenant_id} = key, attrs) do
    changeset =
      Entry.changeset(
        %Entry{},
        Map.put(entry_attrs(attrs, "fix"), "checkpoint_id", attr(attrs, "checkpoint_id"))
      )

    with :ok <- valid(changeset),
         :ok <- fix_checkpoint_given(changeset),
         {:ok, finding_ids} <- canonical_finding_ids(attr(attrs, "finding_ids")),
         :ok <- Threads.screen(changeset, tenant_id, story_id) do
      changeset = Ecto.Changeset.change(changeset, finding_ids: finding_ids)
      author = ActorLabel.of(key)
      lineage = Dispatches.lineage_for_api_key(tenant_id, key.id)
      epoch = attr(attrs, "claim_epoch")

      Threads.write_locked(tenant_id, story_id, fn ->
        fix_locked(tenant_id, story_id, changeset,
          agent_id: key.agent_id,
          epoch: epoch,
          author: author,
          lineage: lineage
        )
      end)
    end
  end

  def record_fix(_tenant_id, _story_id, _key, _attrs), do: {:error, :not_authorized}

  # A resend is answered from its row before the fence, as a checkpoint's is.
  defp fix_locked(tenant_id, story_id, changeset, who) do
    finding_ids = Ecto.Changeset.get_field(changeset, :finding_ids)

    with {:story, %Story{} = story} <- {:story, Threads.locked_story(tenant_id, story_id)},
         nil <- Threads.replayed(tenant_id, story_id, who[:author], changeset),
         :ok <- Threads.claimant_fence(story, who[:agent_id], who[:epoch]),
         {:ok, checkpoint} <- fix_checkpoint(tenant_id, story, changeset),
         :ok <- answers_findings(tenant_id, story_id, finding_ids, checkpoint) do
      Threads.insert_entry(tenant_id, story_id, changeset,
        author_principal: who[:author],
        actor_lineage: who[:lineage]
      )
    else
      {:story, nil} -> {:error, :not_found}
      other -> other
    end
  end

  defp fix_checkpoint_given(changeset) do
    if Ecto.Changeset.get_field(changeset, :checkpoint_id),
      do: :ok,
      else:
        refuse(
          :unprocessable_entity,
          "fix_checkpoint_required",
          "a fix is carried by a checkpoint: checkpoint_id is required"
        )
  end

  defp fix_checkpoint(tenant_id, story, changeset) do
    checkpoint_id = Ecto.Changeset.get_field(changeset, :checkpoint_id)

    case checkpoint_of_story(tenant_id, story.id, checkpoint_id) do
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

  # Every named finding is a finding of a COMPLETED round of this story, and the fix's
  # checkpoint comes after every checkpoint they were found in (by checkpoint seq).
  defp answers_findings(tenant_id, story_id, finding_ids, checkpoint) do
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

  @doc """
  The story's review rounds, from `thread_entries` alone: how many are complete, the next
  placeable round (nil at the ceiling), and whether the ceiling is reached.
  """
  @spec rounds(Ecto.UUID.t(), Ecto.UUID.t()) :: rounds()
  def rounds(tenant_id, story_id) do
    {:ok, rounds} = Repo.with_tenant(tenant_id, fn -> compute_rounds(tenant_id, story_id) end)
    rounds
  end

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

  defp completed_rounds(tenant_id, story_id),
    do: map_size(completed_reviews(tenant_id, story_id))

  # `%{round => review_id}` for every review with a verdict. The verdict check in
  # `current_round/3` makes the rounds exactly 1..N.
  defp completed_reviews(tenant_id, story_id) do
    from(e in Entry,
      join: r in Review,
      on: r.id == e.review_id,
      where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :verdict,
      select: {r.round, r.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  # A round-2 finding introduced by a checkpoint that carries a fix of a round-1 finding: the
  # defect round 1's own fix put there, which is what a third round exists for.
  #
  # Every fix checkpoint a round-2 finding can name IS a round-1 fix's, so no filter on the
  # fix's findings is needed: `introduced_by` is at or before the round-2 checkpoint, a fix
  # names only findings of COMPLETED rounds, and a fix of a round-2 finding must come after
  # the checkpoint that finding was found in. A filter was written and removed when
  # `bin/mutate.sh` showed nothing could reach it.
  defp third_round_warranted?(tenant_id, story_id, %{2 => round2}) do
    fix_checkpoints =
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :fix,
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

  @doc """
  What a review dispatch reads (PRD §6): the story, the checkpoint diff reference, the
  thread's entries (the latest page), and every fix with the findings it answers. Entry
  bodies are UNTRUSTED text.
  """
  @spec payload(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :not_found}
  def payload(tenant_id, story_id, review_id) do
    {:ok, result} =
      Repo.with_tenant(tenant_id, fn ->
        with {:ok, story} <- story(tenant_id, story_id),
             %Review{} = review <-
               Repo.one(
                 from r in Review,
                   where:
                     r.id == ^review_id and r.tenant_id == ^tenant_id and
                       r.story_id == ^story_id
               ) || {:error, :not_found} do
          {:ok, build_payload(tenant_id, story, review)}
        end
      end)

    result
  end

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

    %{
      review: %{
        id: review.id,
        round: review.round,
        dispatch_id: review.dispatch_id,
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
        branch: "loop/#{story.id}",
        commit_sha: checkpoint.commit_sha,
        tree_sha: checkpoint.tree_sha,
        parent_commit_sha: parent && parent.commit_sha
      },
      entries: Enum.reverse(page),
      entries_truncated: rest != [],
      fixes: fixes_with_findings(tenant_id, story.id),
      rounds: compute_rounds(tenant_id, story.id)
    }
  end

  defp fixes_with_findings(tenant_id, story_id) do
    fixes =
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :fix,
          order_by: e.seq
      )

    findings =
      fixes
      |> Enum.flat_map(& &1.finding_ids)
      |> Enum.uniq()
      |> then(fn ids ->
        Repo.all(from e in Entry, where: e.tenant_id == ^tenant_id and e.id in ^ids)
      end)
      |> Map.new(&{&1.id, &1})

    Enum.map(fixes, fn fix ->
      %{
        fix: fix,
        findings: fix.finding_ids |> Enum.map(&Map.get(findings, &1)) |> Enum.reject(&is_nil/1)
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Validation and canonical forms
  # ---------------------------------------------------------------------------

  defp checkpoint_of_story(tenant_id, story_id, checkpoint_id) do
    Repo.one(
      from c in Checkpoint,
        where: c.id == ^checkpoint_id and c.tenant_id == ^tenant_id and c.story_id == ^story_id
    )
  end

  defp severity(value) when is_binary(value) do
    case Enum.find(Entry.severities(), &(to_string(&1) == String.downcase(String.trim(value)))) do
      nil -> bad_severity()
      severity -> {:ok, severity}
    end
  end

  defp severity(_value), do: bad_severity()

  defp bad_severity,
    do:
      refuse(
        :unprocessable_entity,
        "invalid_severity",
        "severity must be one of #{Enum.join(Entry.severities(), ", ")}"
      )

  defp location(nil), do: {:ok, nil}

  defp location(value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> {:ok, nil}
      byte_size(value) > @max_location_bytes -> bad_location()
      true -> {:ok, value}
    end
  end

  defp location(_value), do: bad_location()

  defp bad_location,
    do:
      refuse(
        :unprocessable_entity,
        "invalid_location",
        "location must be a string of at most #{@max_location_bytes} bytes"
      )

  defp no_secret_location(nil, _tenant_id, _story_id), do: :ok

  defp no_secret_location(location, tenant_id, story_id) do
    Threads.screen(
      Entry.changeset(%Entry{}, %{kind: :finding, idempotency_key: "location", body: location}),
      tenant_id,
      story_id
    )
  end

  # `none` in any case, or a checkpoint id in its canonical lowercase form.
  defp canonical_introduced_by(nil), do: {:ok, nil}

  defp canonical_introduced_by(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.downcase(trimmed) == "none" ->
        {:ok, "none"}

      match?({:ok, _}, Ecto.UUID.cast(trimmed)) ->
        Ecto.UUID.cast(trimmed)

      true ->
        bad_introduced_by()
    end
  end

  defp canonical_introduced_by(_value), do: bad_introduced_by()

  defp bad_introduced_by,
    do:
      refuse(
        :unprocessable_entity,
        "introduced_by_invalid",
        "introduced_by must be a checkpoint id of this story, or none"
      )

  defp canonical_finding_ids(ids) when is_list(ids) and ids != [] do
    cast = Enum.map(ids, &cast_uuid/1)

    if Enum.all?(cast, &match?({:ok, _}, &1)),
      do: {:ok, cast |> Enum.map(fn {:ok, id} -> id end) |> Enum.uniq() |> Enum.sort()},
      else: bad_finding_ids()
  end

  defp canonical_finding_ids(_ids), do: bad_finding_ids()

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp bad_finding_ids,
    do:
      refuse(
        :unprocessable_entity,
        "finding_ids_required",
        "finding_ids must be a non-empty list of finding ids"
      )

  defp required_uuid(value, field) do
    case cast_uuid(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> refuse(:unprocessable_entity, "invalid_#{field}", "#{field} must be a UUID")
    end
  end

  defp optional_uuid(nil, _field), do: {:ok, nil}
  defp optional_uuid(value, field), do: required_uuid(value, field)

  defp refuse(status, code, message), do: {:error, {status, code, message}}
end
