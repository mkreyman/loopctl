defmodule Loopctl.Knowledge.DraftConsumer do
  @moduledoc """
  The automatic consumer for articles left in `status: :draft`.

  ## The leak this closes

  A draft is invisible: no read path serves one, so an agent cannot distinguish a held
  draft from a capture that never happened. Measured in production 2026-08-27, **113
  articles sat in `:draft`, growing ~11 a night** (10, 11, 5, 17, 20, 10, 13, 9, 10, 7
  over ten days) with **zero automatic consumers**. A holding area with no drain is not a
  safety mechanism, it is a landfill — the same argument
  `Loopctl.Workers.DraftDuplicateSweepWorker` makes about its own half of the queue.

  ## Why the default is PUBLISH, and why the gate's job is annotation rather than gatekeeping

  Owner decision, 2026-08-27: **there is no human approver and there never will be.** That
  settles the asymmetry the whole design turns on.

    * holding is **TOTAL LOSS** — an agent never sees a draft, so a held article is
      indistinguishable from one that was never captured at all;
    * publishing is **RECOVERABLE** — an agent can read a caveat, the redundancy is
      recorded as a link, and `Knowledge.unpublish_article/3` is the exact inverse of the
      `publish_article/3` this takes.

  So reversibility replaces approval, and **there are no terminal acts here**.

  ## Why it ASSESSES rather than reading a stamp

  loopctl#765 specifies disposing of drafts by their `metadata.proposal_novelty` stamp.
  That mechanism does not exist for these rows: all 113 carry EMPTY metadata, because they
  were created directly as drafts by an orchestrator key (`article.created`) and never went
  through `Knowledge.propose_article/3`'s novelty branch. Only ONE of the 113 carries an
  embedding, either — publishing enqueues one, being created as a draft does not.

  So the per-item cost is a real embedding call, and the assessment is made here through the
  EXISTING seam, `Loopctl.Knowledge.ProposalGate.assess/3` (the
  `ProposalAssessorBehaviour`), rather than in a second novelty implementation that would
  drift from the one the write path uses.

  A draft is therefore embedded TWICE across the night: once synchronously here to assess
  it, and once asynchronously by the embedding worker that `publish_article/3` enqueues,
  which is what writes the STORED vector and chains on to `ArticleLinkingWorker`. The gate
  returns a verdict and neighbours, never the vector, so the second call is the price of
  reusing it. It is paid on a bounded handful of drafts a night (`default_max_publishes/0`),
  inside a job whose clock this step is carved out of.

  ## What happens to each draft

    * `:novel` → **published**. The common case and the default.
    * `:low_novelty` / `:duplicate` → **published AND linked** to its nearest published
      neighbour with a `relates_to` edge carrying the cosine `similarity_score` and
      `auto_generated: true`. That edge is exactly what
      `KnowledgeLintWorker.promote_conflicts/1` reads, so a pair at or above the conflict
      threshold is flagged `:potential_conflict` and judged the SAME night, and a confirmed
      duplicate is later retracted by the nightly consolidation pass with `unpublish` —
      reversibly. The redundancy is handled by machinery that already works (226/226 pairs
      judged on 2026-08-27) instead of by a decision taken here.
    * assessment genuinely **unavailable** (`:unknown` — provider down, no BYO key, heavy
      read shed) → the draft is **left alone and counted**. `ProposalGate` falls open by
      contract, so `:unknown` means "not assessed", never "not a duplicate". Publishing on
      it would publish unassessed drafts through a provider outage, and dropping it would be
      the loss this worker exists to stop.

  ## What it must NOT do: archive

  loopctl#765 item 4 proposes archiving the twin of a near-duplicate on the premise that
  archive is a soft delete and therefore reversible. **The premise is false.**
  `Loopctl.Knowledge.Article`'s `@valid_transitions` carries no `{:archived, _}` entry and
  there is no unarchive function, so `:archived` is TERMINAL: only a `user`-role PATCH
  carrying an explicit status brings a row back. Non-destructive and reversible are
  different properties (#605/#606), and an unattended writer may only have the second. It is
  why the consolidation pass retracts with `unpublish` and never `archive` (#608), and it is
  why nothing here merges bodies or discards one.

  ## The flip-flop guard

  Consolidation's retraction of a confirmed duplicate PRODUCES a draft. Republishing it
  would put this step in a nightly fight with that one — publish, retract, publish — burning
  an embedding call each way, forever. So a draft carrying
  `articles.consolidation_retracted_at` is never a candidate, and neither is one the
  `audit_log` shows `worker:consolidation` unpublished (the marker only exists from
  migration `20260818055453` onward). Both records are read for exactly the reason
  `DraftDuplicateSweepWorker` reads both.

  Unlike that worker, this one does NOT additionally fail closed past the audit-retention
  horizon. The direction of the danger is inverted: the sweep's action is terminal, so an
  unprovable retraction must be spared; this step's action is reversible, so the cost of
  getting it wrong on a pre-marker retraction is one republish, which consolidation
  re-confirms and retracts — stamping the durable marker as it does, after which this step
  never offers it again. The flip-flop terminates in one round, whereas failing closed here
  would strand every pre-marker draft permanently, which is the total loss.

  ## What bounds one night

  A **WALL CLOCK** (`:budget_ms`), because the per-item cost is an outbound provider call
  and a count bounds attempts rather than cost — #761, in this same job, for six consecutive
  nights. `:max_publishes` bounds the candidate QUERY only, and `0` PAUSES the drain
  (`gate: :drain_disabled`) without a deploy, through the
  `knowledge_draft_consumer_max_publishes` `SystemConfig` row.

  The cap sits deliberately ABOVE the producer rate: ~11 drafts a night arrive, so
  `default_max_publishes/0` both clears the 113-draft backlog inside four nights and stays
  ahead of inflow. A cap at or below the producer rate is not a drain at all.

  The return carries `offered` and `budget_exhausted` so a truncated night and a night with
  nothing to do are never the same numbers; the worker puts both in its log line and in the
  `knowledge.lint_completed` audit event. `published + unassessed + skipped + failed` is
  what was PROCESSED, so it falls below `offered` exactly when the clock fired.

  ## Overlap with `DraftDuplicateSweepWorker`

  That worker ARCHIVES a draft whose nearest published neighbour clears 0.95. This one
  PUBLISHES the same draft and links it. They disagree, and running nightly against its
  weekly schedule means this one reaches the capture-path backlog first. That is the owner
  decision applied — the sweep predates it — not an oversight; it is called out here because
  a reader arriving from that moduledoc will expect the two to agree.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings.TextBudget
  alias Loopctl.ExitTag
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ProposalGate
  alias Loopctl.Llm

  @actor_label "worker:draft_consumer"

  # The nightly consolidation pass's actor label. Its retractions are SPARED — see the
  # flip-flop guard in the moduledoc and `draft_scope/1`.
  @consolidation_actor "worker:consolidation"

  # How many drafts one nightly run may OFFER. Bounds the candidate query, never the step:
  # each item costs an outbound embedding call, so the bound that holds is the wall clock
  # below (#761). Chosen ABOVE the measured producer rate (~11 a night) so the backlog
  # actually falls: at 30 the 113 standing drafts clear in four nights while inflow is
  # absorbed. `0` is honoured as an explicit operator PAUSE.
  @default_max_publishes 30
  @hard_max_publishes 500

  # Fallback wall clock. `Loopctl.Workers.KnowledgeLintWorker` always passes `:budget_ms` —
  # the time ITS job has left (`draft_budget_remaining/1`) — so this applies only to a direct
  # call, and it is deliberately not larger than the reserve that worker carves out for this
  # step. `test/loopctl/workers/knowledge_lint_worker_test.exs` binds the two so they cannot
  # drift into a budget bigger than the job containing it.
  @default_budget_ms :timer.minutes(2)

  @type tally :: %{
          published: non_neg_integer(),
          linked: non_neg_integer(),
          link_failed: non_neg_integer(),
          unassessed: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          offered: non_neg_integer(),
          budget_exhausted: boolean(),
          gate: :open | :drain_disabled
        }

  @doc "Default cap on drafts one run may offer to the consumer."
  @spec default_max_publishes() :: pos_integer()
  def default_max_publishes, do: @default_max_publishes

  @doc "Fallback wall-clock budget (ms) when no `:budget_ms` is given."
  @spec default_budget_ms() :: pos_integer()
  def default_budget_ms, do: @default_budget_ms

  @doc "The actor label every publish and every link this step writes is attributed to."
  @spec actor_label() :: String.t()
  def actor_label, do: @actor_label

  @doc """
  Assess every eligible draft and publish it, linking a near-duplicate to its neighbour.

  ## Options

    * `:max_publishes` — candidate-query cap; `0` pauses the drain. Defaults to
      `default_max_publishes/0`, clamped to `#{@hard_max_publishes}`.
    * `:budget_ms` — wall clock for the whole drain. Defaults to `default_budget_ms/0`.
    * `:proposal_assessor` — the `ProposalAssessorBehaviour` implementation, PER CALL. The
      config layer underneath is untouched and still resolves to `ProposalGate` in
      production and to the Mox mock in tests; the opt exists because a test must drive one
      call's assessor without `Application.put_env`, which mutates VM-global state every
      other test in this `async: true` suite would see. Mirrors
      `Loopctl.Knowledge.Consolidation.extractor/1` and `ConflictJudge.impl/1` exactly.
  """
  @spec consume(Ecto.UUID.t(), keyword()) :: tally()
  def consume(tenant_id, opts \\ []) do
    cap = clamp_cap(Keyword.get(opts, :max_publishes, @default_max_publishes))

    if cap == 0 do
      Logger.info(
        "DraftConsumer: tenant=#{tenant_id} drain is PAUSED by its cap (0); drafts stay held."
      )

      tally(:drain_disabled)
    else
      drain(tenant_id, candidates(tenant_id, cap), opts)
    end
  end

  @doc """
  The novelty assessor this step calls.

  See the `:proposal_assessor` option on `consume/2` for why the seam is per-call.
  """
  @spec assessor(keyword()) :: module()
  def assessor(opts \\ []) do
    Keyword.get(
      opts,
      :proposal_assessor,
      Application.get_env(:loopctl, :proposal_assessor, ProposalGate)
    )
  end

  # --- Private ---

  # A NEGATIVE cap is a pause, not a licence: `0` and below both stop the drain rather than
  # wrapping round to "unbounded". A non-integer falls back to the default rather than
  # raising inside the nightly's rescue, where it would surface as an outage instead of the
  # config typo it is (the `coerce_int/2` lesson).
  defp clamp_cap(value) when is_integer(value) and value <= 0, do: 0
  defp clamp_cap(value) when is_integer(value), do: min(value, @hard_max_publishes)

  defp clamp_cap(other) do
    Logger.warning(
      "DraftConsumer: ignoring non-integer cap #{inspect(other)}; using #{@default_max_publishes}."
    )

    @default_max_publishes
  end

  # ONE constructor for every tally, so no fail-soft path can ship a map missing a key the
  # worker's summary line interpolates — the `empty_tally/2` lesson, which once cost a
  # fail-soft rescue a KeyError one line after it had swallowed the original error.
  defp tally(gate) do
    %{
      published: 0,
      linked: 0,
      link_failed: 0,
      unassessed: 0,
      skipped: 0,
      failed: 0,
      offered: 0,
      budget_exhausted: false,
      gate: gate
    }
  end

  defp candidates(tenant_id, cap) do
    tenant_id
    |> draft_scope()
    # OLDEST FIRST. A capped run must drain the standing backlog rather than skim tonight's
    # arrivals off the top, which at a cap above the producer rate would leave the 113 oldest
    # drafts held forever while the queue looked healthy.
    |> order_by([draft: a], asc: a.inserted_at)
    |> limit(^cap)
    |> select([draft: a], a.id)
    |> AdminRepo.all()
  end

  # The ONE definition of "a draft this step may touch", composed into both the candidate
  # query and the per-item live re-fetch. Two hand-copied predicate lists is how the offer
  # and the write come to disagree about the same row.
  defp draft_scope(tenant_id) do
    from(a in Article,
      as: :draft,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :draft,
      # TENANT scope only. A `:system` canonical is shared-corpus content that no per-tenant
      # nightly pass owns, and publishing one on a tenant's behalf is not this step's call.
      where: a.scope == :tenant,
      # SHARED visibility only, the same filter `Consolidation.shared_only/1` applies for the
      # same reason: this step ships the article's own bytes to an embedding provider, and an
      # agent's `private`/`owner` memory must not leave on a pass it never asked for. Such a
      # draft stays held, which for a row only its owner could ever read is not the loss the
      # moduledoc is about.
      where:
        fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", a.metadata),
      # The flip-flop guard, in its two independent records. See the moduledoc: the durable
      # column is authoritative and survives audit retention; the audit_log is still read
      # because the column only exists from migration 20260818055453 onward. `tenant_id` is
      # constrained inside the subquery so the correlated NOT EXISTS can use
      # `audit_log_tenant_entity_idx`, whose leading column it is.
      where: is_nil(a.consolidation_retracted_at),
      where:
        not exists(
          from(al in "audit_log",
            where: al.tenant_id == parent_as(:draft).tenant_id,
            where: al.entity_id == parent_as(:draft).id,
            where: al.entity_type == "article",
            where: al.action == "article.unpublished",
            where: al.actor_label == ^@consolidation_actor,
            select: 1
          )
        )
    )
  end

  # SEQUENTIAL, deliberately, where the conflict judge is concurrent. `Task.async_stream/3`
  # LINKS its tasks, so every failure mode of the work has to be made total INSIDE the task
  # or one raise takes the night's audit event with it — the defect the #766 review caught.
  # A capped handful of items at ~2 s each fits the 2-minute reserve with room to spare, so
  # concurrency buys nothing here and the hazard is simply not taken on.
  defp drain(tenant_id, ids, opts) do
    # Deadline taken before the first item and checked BEFORE each one, never after. A
    # post-item check is unconditionally committed to item #1, so a budget of exactly 0 — the
    # state a night whose prelude overran arrives in, and `draft_budget_remaining/1` floors at
    # 0 — would still buy a full provider call and a publish out of a reserve already spent.
    # Checking at the head also keeps the flag honest for free: a night that processed its
    # LAST candidate and only then crossed the deadline never reaches another check, so a
    # DRAINED night is never reported as truncated.
    budget_ms = Keyword.get(opts, :budget_ms, @default_budget_ms)
    deadline = System.monotonic_time(:millisecond) + budget_ms
    offered = length(ids)

    result =
      Enum.reduce_while(ids, %{tally(:open) | offered: offered}, fn id, acc ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, %{acc | budget_exhausted: true}}
        else
          {:cont, tally_draft(tenant_id, id, acc, opts)}
        end
      end)

    log_truncation(tenant_id, budget_ms, result)
    log_provider_unconfigured(tenant_id, result)
    result
  end

  # Per-item containment, exactly like `Consolidation.tally_retitle/4`: this reduce is not
  # transactional, so a raise escaping it would discard the tally of the drafts ALREADY
  # published and report zero writes that really happened.
  defp tally_draft(tenant_id, id, acc, opts) do
    case consume_draft(tenant_id, id, opts) do
      :published ->
        %{acc | published: acc.published + 1}

      :published_linked ->
        %{acc | published: acc.published + 1, linked: acc.linked + 1}

      :published_link_failed ->
        %{acc | published: acc.published + 1, link_failed: acc.link_failed + 1}

      :unassessed ->
        %{acc | unassessed: acc.unassessed + 1}

      :skip ->
        %{acc | skipped: acc.skipped + 1}

      {:failed, tag} ->
        draft_failed(tenant_id, id, tag, acc)
    end
  rescue
    e -> draft_failed(tenant_id, id, ExitTag.tag(e), acc)
  catch
    :exit, reason -> draft_failed(tenant_id, id, "exit:" <> ExitTag.tag(reason), acc)
  end

  defp draft_failed(tenant_id, id, tag, acc) do
    Logger.error(
      "DraftConsumer: tenant=#{tenant_id} draft #{id} could not be consumed (#{tag}); " <>
        "it stays held and is offered again next run."
    )

    %{acc | failed: acc.failed + 1}
  end

  defp consume_draft(tenant_id, id, opts) do
    case live_draft(tenant_id, id) do
      {:ok, draft} ->
        assess_and_publish(tenant_id, draft, opts)

      :gone ->
        Logger.info(
          "DraftConsumer: tenant=#{tenant_id} draft #{id} is no longer an eligible draft; skipped."
        )

        :skip
    end
  end

  # Re-derivation, not trust — the twin of `Consolidation.live_placeholder/2`. Between the
  # candidate query and the provider call a human may have published, archived or retitled
  # the draft, or consolidation may have stamped it; spending an embedding call and then a
  # publish on a row that has moved is the failure this re-read costs one indexed lookup to
  # avoid. The body comes back PRE-TRUNCATED from SQL at the same cap the gate's own
  # `TextBudget.initial/1` would apply, so this can never pull 30 x 100 KB bodies into memory
  # to hand the gate bytes it would immediately discard.
  defp live_draft(tenant_id, id) do
    tenant_id
    |> draft_scope()
    |> where([draft: a], a.id == ^id)
    |> select([draft: a], %{
      id: a.id,
      title: a.title,
      project_id: a.project_id,
      body: fragment("substring(? from 1 for ?)", a.body, ^TextBudget.initial_chars())
    })
    |> AdminRepo.one()
    |> case do
      nil -> :gone
      draft -> {:ok, draft}
    end
  end

  defp assess_and_publish(tenant_id, draft, opts) do
    attrs = %{"title" => draft.title, "body" => draft.body, "project_id" => draft.project_id}

    case assessor(opts).assess(tenant_id, attrs, []) do
      %{verdict: :novel} ->
        publish(tenant_id, draft, :novel, nil)

      %{verdict: verdict} = assessment when verdict in [:low_novelty, :duplicate] ->
        publish(tenant_id, draft, verdict, neighbour(assessment, draft.id))

      %{verdict: :unknown} ->
        unassessed(tenant_id, draft, "gate_unavailable")

      other ->
        # An implementation that answers outside the behaviour's four verdicts. Treated as
        # NOT ASSESSED rather than defaulted to novel: publishing on a verdict nobody
        # produced is exactly the unassessed publish the `:unknown` branch refuses.
        unassessed(tenant_id, draft, "unrecognised_verdict:#{ExitTag.tag(other)}")
    end
  end

  defp unassessed(tenant_id, draft, reason) do
    Logger.info(
      "DraftConsumer: tenant=#{tenant_id} draft #{draft.id} was not assessed (#{reason}); " <>
        "it stays held and is offered again next run."
    )

    :unassessed
  end

  # The nearest PUBLISHED neighbour the gate scored, or `nil`. A `:low_novelty`/`:duplicate`
  # verdict is DERIVED from the top neighbour's score, so an empty list here is an
  # implementation contradicting itself; the draft is still published (that is the default,
  # and withholding it over a malformed assessment would be the total loss), it simply
  # carries no annotation.
  defp neighbour(%{neighbors: [%{id: id, similarity_score: score} | _]}, draft_id)
       when is_binary(id) and id != draft_id,
       do: %{id: id, similarity_score: score}

  defp neighbour(_assessment, _draft_id), do: nil

  defp publish(tenant_id, draft, verdict, neighbour) do
    case Knowledge.publish_article(tenant_id, draft.id,
           actor_type: "system",
           actor_label: @actor_label
         ) do
      {:ok, _article} ->
        link(tenant_id, draft, verdict, neighbour)

      # The row moved between the live re-fetch and the write, or the transition is no longer
      # legal (someone else published or archived it). A SKIP, never a failure: nothing is
      # wrong and nothing is owed.
      {:error, :not_found} ->
        :skip

      {:error, :unprocessable_entity, _message} ->
        :skip

      other ->
        {:failed, publish_error_tag(other)}
    end
  end

  # ONE clause on purpose. The case above has already taken every non-changeset error
  # `Knowledge.publish_article/3` declares, so the residual is exactly a rejected changeset —
  # a catch-all here is unreachable and dialyzer says so. A shape outside that spec raises
  # into `tally_draft/4`'s per-item rescue, which counts it and names its class, rather than
  # being flattened to a uselessly generic tag. Keys only, never the changeset: an error
  # message can carry backend host, database and role.
  defp publish_error_tag({:error, %Ecto.Changeset{errors: errors}}),
    do: inspect(Keyword.keys(errors))

  defp link(_tenant_id, _draft, :novel, _neighbour), do: :published

  defp link(tenant_id, draft, _verdict, nil) do
    Logger.warning(
      "DraftConsumer: tenant=#{tenant_id} draft #{draft.id} assessed as a near-duplicate " <>
        "but the assessment carried no usable neighbour; published WITHOUT an annotation."
    )

    :published
  end

  # The annotation, and the only thing that separates this step from a bulk publish. It is
  # shaped as the auto-linker's own edge — `auto_generated: true` plus the cosine
  # `similarity_score` — because that is precisely what
  # `KnowledgeLintWorker.promote_conflicts/1` reads: a pair at or above the conflict
  # threshold is flagged `:potential_conflict` the SAME night and judged the same night, and
  # a confirmed duplicate is retracted later by the consolidation pass with `unpublish`.
  # Every step of that is reversible, which is the whole reason the redundancy is handed to
  # it rather than decided here.
  #
  # `on_conflict: :nothing` against the pair's unique index, so a re-run is a no-op — and the
  # asynchronous `ArticleLinkingWorker` that `publish_article/3` chains to will derive the
  # same edge from the stored vector once it lands. This write is what makes the annotation
  # true TONIGHT rather than whenever that queue drains.
  defp link(tenant_id, draft, verdict, %{id: neighbour_id, similarity_score: score}) do
    attrs = %{
      source_article_id: draft.id,
      target_article_id: neighbour_id,
      relationship_type: :relates_to,
      metadata: %{
        "auto_generated" => true,
        "similarity_score" => score,
        "linked_by" => @actor_label,
        "novelty_verdict" => to_string(verdict)
      }
    }

    %ArticleLink{tenant_id: tenant_id}
    |> ArticleLink.changeset(attrs)
    |> AdminRepo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :source_article_id, :target_article_id, :relationship_type]
    )
    |> case do
      {:ok, _link} ->
        :published_linked

      {:error, changeset} ->
        # The article IS published — recoverable, visible, and the auto-linker still gets its
        # chance. Counted separately all the same: a near-duplicate published with no
        # annotation is the one outcome this step is supposed to make impossible, and it must
        # not hide inside `published`.
        Logger.warning(
          "DraftConsumer: tenant=#{tenant_id} published draft #{draft.id} but could not link " <>
            "it to #{neighbour_id} (#{inspect(Keyword.keys(changeset.errors))}); the " <>
            "annotation is left to the auto-linker."
        )

        :published_link_failed
    end
  end

  defp processed(%{published: p, unassessed: u, skipped: s, failed: f}), do: p + u + s + f

  # NEVER silent (#761 acceptance). Without this line and the `offered` counter beside it, a
  # night the clock cut short and a night with nothing left to consume report the same
  # `published`, and the difference is the whole question when the backlog stops falling.
  defp log_truncation(tenant_id, budget_ms, %{budget_exhausted: true} = result) do
    Logger.warning(
      "DraftConsumer: tenant=#{tenant_id} hit its #{budget_ms}ms budget after " <>
        "#{processed(result)} of #{result.offered} draft(s); the remainder is retried next run."
    )
  end

  defp log_truncation(_tenant_id, _budget_ms, _result), do: :ok

  # ONCE PER RUN, and a WARNING rather than a per-item line — the
  # `Consolidation.log_provider_unconfigured/2` lesson, applied to a third step whose per-item
  # cost is an outbound call. `{:error, :no_api_key}` is the one `:unknown` cause that is
  # PERMANENT, self-inflicted and operator-fixable, and `ProposalGate` folds it into the same
  # fall-open every transient provider failure gets. Without this line a keyless tenant offers
  # the same drafts every night, leaves every one of them unassessed, and the audit event
  # reads exactly like a provider having a bad night — the #620 shape, one step over.
  #
  # Self-guarded for the same reason its sibling is: this runs AFTER the drain, so a repo blip
  # reading the tenant's LLM settings must not discard a completed run's tally.
  defp log_provider_unconfigured(tenant_id, %{unassessed: unassessed}) when unassessed > 0 do
    if Llm.has_api_key?(tenant_id) do
      :ok
    else
      Logger.warning(
        "DraftConsumer: tenant=#{tenant_id} has no embedding key (mandatory BYO), so its " <>
          "#{unassessed} unassessed draft(s) can never be assessed at all and are re-offered " <>
          "every night. This is a configuration state, not a provider that failed. Nothing " <>
          "is published while it stands."
      )
    end

    :ok
  rescue
    _e -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp log_provider_unconfigured(_tenant_id, _result), do: :ok
end
