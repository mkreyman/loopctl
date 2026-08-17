defmodule Loopctl.Workers.DraftDuplicateSweepWorker do
  @moduledoc """
  Weekly sweep that retires DRAFT articles which duplicate an already-published one.

  ## Why this exists

  The draft queue is a holding area, not a destination: `hooks/knowledge-capture.sh`
  holds every machine-extracted `finding`/`pattern`/`playbook` as a draft
  (claude-config#203) so a confidently-wrong extraction cannot reach the recall hook
  unreviewed. That hold is only half a design — without a drain, held drafts are not
  a safety mechanism, they are a landfill.

  The 2026-08-17 manual drain measured what the queue is actually made of: of 530
  drafts, **453 were duplicates** — 418 re-extractions of already-published articles
  and 35 near-identical siblings of each other (one lesson had been extracted FOUR
  times from a single session). Only 77 carried anything a reader could not already
  get from the published corpus.

  That ratio is the whole argument for this worker. The duplicate majority needs no
  judgement — it is a similarity comparison against the published corpus, which is
  exactly what the vector index already answers. The judgement half (does this claim
  survive contact with the source it describes?) needs an agent that can open a repo
  and run a command, and is deliberately NOT attempted here.

  ## Why the queue accumulated duplicates in the first place

  The novelty gate dedups a proposal against the **published** corpus only, so drafts
  are invisible to it: the same lesson could be re-extracted indefinitely without
  anything noticing. Retiring the duplicates is therefore only half the fix — the
  other half happened when the 77 survivors were PUBLISHED, which makes future
  re-extractions of those lessons visible to the gate and dedupable at write time.

  ## What it does

  Per tenant, for each draft carrying an embedding at the tenant's active dimension:
  ask the vector index for the nearest PUBLISHED article
  (`Loopctl.Knowledge.VectorSearch.nearest/4` already applies `status = :published`
  as an index-safe residual filter) and retire the draft when that neighbour clears
  `similarity_threshold/0`.

  ## Retirement is ARCHIVE, and archive is a one-way door

  `:archived` is terminal — `Article`'s `@valid_transitions` has no `{:archived, _}`
  entry, so nothing this system can call restores an archived row; only a `user`-role
  PATCH carrying an explicit status brings one back. That is a deliberately stronger
  action than the nightly consolidation pass takes on PUBLISHED articles, which
  retracts with `unpublish` (`{:published, :draft}`, undone by `publish`) precisely
  so an unattended writer keeps an undo (#605/#606/#608).

  There is no equivalent reversible step for a draft: a draft is already unpublished,
  so archive is the only move down. The row survives and every archive is audited via
  `Knowledge.bulk_archive/3`, so nothing is destroyed — but "non-destructive" and
  "reversible" are different properties, and this worker only has the first. Treat the
  threshold as the safety mechanism it is, and do not lower it without re-measuring.

  ## What it must NOT sweep: another worker's reversible retraction

  `Loopctl.Knowledge.Consolidation` retracts a confirmed duplicate with `unpublish`
  and never `archive`, deliberately, so an unattended pass keeps an undo
  (#605/#606/#608). Its output is a DRAFT whose published winner is by construction at
  or above this worker's similarity threshold — that similarity is *why* it was
  retracted. So a naive sweep archives exactly the set another worker took care to
  leave reversible, one week later, unattended, converting a considered
  `{:published, :draft}` into a terminal `:archived`.

  That is not a hypothetical: on 2026-08-17 a manual drain archived 418 drafts, and all
  418 turned out to be consolidation retractions from 2026-08-06/07. Zero of the 420
  consolidation had ever retracted remained reversible afterwards.

  Sparing them costs nothing. A draft is already withheld from every read path, so the
  queue-hygiene argument for archiving it is weak, while the undo it preserves is the
  entire reason consolidation chose `unpublish`. Consolidation owns its own output; this
  worker drains what the CAPTURE path holds.

  ## Scope discipline

  * Only drafts that HAVE an embedding are considered. An unembedded draft is not
    evidence of novelty — it is absence of evidence — so it is left alone and counted
    in `skipped_unembedded`, never swept.
  * `:heavy_read_overloaded` snoozes the whole tenant rather than banking a partial
    verdict: a shed read is an unknown, and an unknown must not read as "not a
    duplicate" on a path whose action is terminal.
  * Bounded per run by `max_archives/0`; a larger backlog drains over later runs.
  """

  use Oban.Worker, queue: :knowledge, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.KbCuration
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Oban.FairShare
  alias Loopctl.Tenants.Tenant

  @actor_label "worker:draft_duplicate_sweep"

  # The nightly consolidation pass's actor label. Its retractions are SPARED — see
  # `load_embedded_drafts/2`.
  @consolidation_actor "worker:consolidation"

  # Chosen from the 2026-08-17 drain: every one of the 271 drafts at >= 0.95 that was
  # inspected was a true duplicate, and the ONE inspected article that scored below
  # 0.92 while still deserving retirement failed for an unrelated reason (it was
  # trivial, not duplicate) — i.e. 0.95 was not observed to produce a false positive,
  # and the band below it was where genuine judgement started being required.
  @default_similarity_threshold 0.95

  # Bounds the terminal action, not the scan: a runaway similarity regression can only
  # ever cost one run's worth of archives before someone sees the curation event.
  @default_max_archives 500
  @default_scan_limit 2000

  @doc "Minimum published-neighbour similarity at which a draft is retired."
  @spec similarity_threshold() :: float()
  def similarity_threshold do
    Application.get_env(
      :loopctl,
      :draft_sweep_similarity_threshold,
      @default_similarity_threshold
    )
  end

  @doc "Maximum drafts one run may archive for a single tenant."
  @spec max_archives() :: pos_integer()
  def max_archives do
    Application.get_env(:loopctl, :draft_sweep_max_archives, @default_max_archives)
  end

  @doc "Maximum drafts one run may examine for a single tenant."
  @spec scan_limit() :: pos_integer()
  def scan_limit do
    Application.get_env(:loopctl, :draft_sweep_scan_limit, @default_scan_limit)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    tenant_ids =
      from(t in Tenant, where: t.status == :active, select: t.id)
      |> AdminRepo.all()

    for tenant_id <- tenant_ids do
      %{"tenant_id" => tenant_id}
      |> __MODULE__.new()
      |> Oban.insert()
    end

    :ok
  end

  def perform(%Oban.Job{id: id, args: %{"tenant_id" => tenant_id}}) do
    # Do NOT gate the all_tenants dispatcher above — it carries no tenant_id.
    # `id` excludes THIS already-executing job from its own count (US-36.2).
    case FairShare.gate(tenant_id, :knowledge, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> sweep_tenant(tenant_id)
    end
  end

  defp sweep_tenant(tenant_id) do
    dimension = Embeddings.active_dimension(tenant_id)
    candidates = load_embedded_drafts(tenant_id, dimension)

    case classify(tenant_id, candidates) do
      {:error, :heavy_read_overloaded} ->
        # Snooze the WHOLE tenant. A partial verdict is worse than none here: the
        # drafts whose reads were shed would be indistinguishable from drafts with no
        # published neighbour, and the action taken on that reading cannot be undone.
        Logger.info(
          "draft_duplicate_sweep shed: tenant=#{tenant_id} reason=heavy_read_overloaded"
        )

        {:snooze, 300}

      {:ok, duplicates} ->
        apply_verdicts(tenant_id, duplicates, unembedded_count(tenant_id, dimension))
    end
  end

  # Only drafts WITH an embedding at the active dimension are swept. The join is the
  # filter: an unembedded draft never reaches `classify/2`, so it can never be archived
  # for want of a neighbour it was never able to have.
  defp load_embedded_drafts(tenant_id, dimension) do
    from(a in Knowledge.Article,
      as: :draft,
      join: e in ArticleEmbedding,
      on: e.article_id == a.id and e.tenant_id == a.tenant_id,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :draft,
      where: e.dim == ^dimension and e.live_denorm == true,
      # Spare consolidation's retractions — the exclusion is applied HERE rather than
      # before the archive so the sweep does not even spend an ANN read on a draft it
      # must not touch. There is no marker on the article itself; the audit_log is the
      # only record that consolidation was the actor.
      where:
        not exists(
          from(al in "audit_log",
            where: al.entity_id == parent_as(:draft).id,
            where: al.entity_type == "article",
            where: al.action == "article.unpublished",
            where: al.actor_label == ^@consolidation_actor,
            select: 1
          )
        ),
      order_by: [asc: a.inserted_at],
      limit: ^scan_limit(),
      select: %{id: a.id, title: a.title, embedding: e.embedding}
    )
    |> AdminRepo.all()
  end

  defp unembedded_count(tenant_id, dimension) do
    from(a in Knowledge.Article,
      left_join: e in ArticleEmbedding,
      on:
        e.article_id == a.id and e.tenant_id == a.tenant_id and
          e.dim == ^dimension and e.live_denorm == true,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :draft,
      where: is_nil(e.id),
      select: count(a.id)
    )
    |> AdminRepo.one()
    |> Kernel.||(0)
  end

  # Reduces to the first shed rather than continuing: see the snooze rationale above.
  defp classify(tenant_id, candidates) do
    threshold = similarity_threshold()

    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      opts = [threshold: threshold, exclude_id: candidate.id, on_overload: :shed]

      case VectorSearch.nearest(tenant_id, candidate.embedding, 1, opts) do
        {:error, :heavy_read_overloaded} = shed ->
          {:halt, shed}

        [] ->
          {:cont, {:ok, acc}}

        [%{similarity_score: score} = neighbour | _] ->
          {:cont, {:ok, [{candidate, neighbour, score} | acc]}}
      end
    end)
  end

  defp apply_verdicts(tenant_id, [], unembedded) do
    Logger.info(
      "draft_duplicate_sweep: tenant=#{tenant_id} duplicates=0 archived=0 " <>
        "skipped_unembedded=#{unembedded}"
    )

    :ok
  end

  defp apply_verdicts(tenant_id, duplicates, unembedded) do
    # Highest similarity first, so a capped run retires the most certain duplicates
    # rather than whichever the scan happened to reach first.
    to_archive =
      duplicates
      |> Enum.sort_by(fn {_c, _n, score} -> score end, :desc)
      |> Enum.take(max_archives())

    ids = Enum.map(to_archive, fn {candidate, _n, _s} -> candidate.id end)

    archived = archive_all(tenant_id, ids)

    KbCuration.record(
      tenant_id,
      "draft_duplicate_sweep",
      "retired #{archived} draft(s) duplicating a published article " <>
        "(threshold #{similarity_threshold()})",
      refs: ids,
      actor: @actor_label,
      metadata: %{
        "candidates" => length(duplicates),
        "archived" => archived,
        "capped" => length(duplicates) > max_archives(),
        "skipped_unembedded" => unembedded,
        "threshold" => similarity_threshold()
      }
    )

    Logger.info(
      "draft_duplicate_sweep: tenant=#{tenant_id} duplicates=#{length(duplicates)} " <>
        "archived=#{archived} skipped_unembedded=#{unembedded}"
    )

    :ok
  end

  # `bulk_archive/3` answers `{:error, :bad_request, _}` for an empty/oversized id
  # list. Neither is reachable here (the empty case returns via the [] clause of
  # apply_verdicts/3 and the list is capped at max_archives/0), but a silently
  # swallowed error on a path that reports how many rows it retired would make a
  # zero-archive run indistinguishable from a healthy one — so log and count 0.
  defp archive_all(tenant_id, ids) do
    case Knowledge.bulk_archive(tenant_id, ids, actor_label: @actor_label) do
      {:ok, %{counts: %{archived: archived}}} ->
        archived

      {:error, :bad_request, message} ->
        Logger.error(
          "draft_duplicate_sweep archive rejected: tenant=#{tenant_id} " <>
            "ids=#{length(ids)} reason=#{message}"
        )

        0
    end
  end
end
