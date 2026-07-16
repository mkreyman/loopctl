defmodule Loopctl.Workers.MemoryGraduationSweepWorker do
  @moduledoc """
  Scheduled cadence that graduates HOT long-term memories into durable knowledge
  articles (#411 Gap 3).

  The counterpart, one tier UP, of `Loopctl.Workers.MemoryPromotionSweepWorker`:

    * The promotion sweep compiles short-term SESSION turns into long-term `memories`
      (every 10 min — it is latency-sensitive because session turns are pruned).
    * THIS sweep graduates long-term `memories` that have been RECALLED often enough
      (`recall_count >= Loopctl.Memory.graduation_recall_threshold/0`) into curated
      Knowledge Wiki articles (HOURLY — graduation is NOT latency-sensitive, and a
      slower cadence keeps the novelty-gate embedding spend low).

  Do NOT conflate the two: this worker never touches sessions, and the promotion sweep
  never writes articles.

  ## Flow (mirrors the promotion sweep's cross-tenant + per-run-budget shape)

  1. **Candidates (per-tenant fair)** — LIVE (`superseded_by IS NULL`), NOT-yet-graduated
     (`graduated_at IS NULL`) memories at or above the recall threshold, gathered with
     PER-TENANT FAIRNESS so one hot tenant cannot monopolize the per-run budget and starve
     others. The sweep enumerates eligible tenants (bounded by
     `Loopctl.Memory.graduation_scan_limit/0`), pulls each tenant's hottest eligible
     memories via a `tenant_id = ? ... ORDER BY recall_count DESC` query that the partial
     index `memories_graduation_sweep_idx (tenant_id, recall_count)` actually serves
     (equality + in-index descending scan, no sort — a bare cross-tenant global sort could
     NOT use this tenant-leading index), then ROUND-ROBIN interleaves the per-tenant lists
     so every active tenant is served each tick.
  2. **Graduate + stamp** — each candidate goes through
     `Loopctl.Memory.graduate_memory_record/2`, which writes the article via the
     NOVELTY GATE (`Loopctl.Knowledge.propose_article/3`, so a semantically-duplicate
     memory does not bloat the corpus) and stamps `graduated_at` on ANY successful
     verdict so it is never re-processed. A `:created`/`:duplicate`/`:deduplicated`
     verdict means a PUBLISHED (searchable) article represents the content;
     `:gated_to_draft` means a review-queue draft does (not yet searchable). A structural
     changeset failure is ALSO stamped (it can never succeed) to prevent a per-slot livelock.
  3. **Per-run execution budget** — at most `Loopctl.Memory.graduation_max_per_run/0`
     memories are processed per tick, bounding the novelty-gate embedding spend per run
     (the analogue of the promotion sweep's per-tick cap). The same value bounds each
     tenant's candidate slice, so no single tenant contributes more than one run could
     process.

  ## Scope is PRESERVED — the sweep never re-scopes

  A candidate graduates to the SAME scope as the memory (project memory → project
  article, global memory → global article). The sweep NEVER promotes a project memory to
  a tenant-wide article: over-generalizing a project fact is a mis-scoping the novelty
  gate cannot catch, so local→global re-scope is an EXPLICIT caller action only
  (`Loopctl.Memory.graduate_memory/3` with `re_scope: :global`).

  ## Concurrency / idempotency

  `unique: [fields: [:worker], period: 60]` prevents overlapping ticks. Across ticks,
  double-graduation is prevented by (a) the conditional `graduated_at` stamp and (b) the
  stable per-memory `idempotency_key` + novelty gate in `graduate_memory_record/2` — so
  even a race that re-proposes a memory yields ONE article, not a duplicate.
  """

  use Oban.Worker,
    queue: :memory,
    max_attempts: 3,
    unique: [fields: [:worker], period: 60]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    threshold = Memory.graduation_recall_threshold()
    cap = Memory.graduation_max_per_run()
    candidates = candidate_memories(threshold)

    {processed, graduated} =
      Enum.reduce_while(candidates, {0, 0}, fn memory, {processed, graduated} ->
        if processed >= cap do
          {:halt, {processed, graduated}}
        else
          {:cont, {processed + 1, graduated + graduate(memory)}}
        end
      end)

    :telemetry.execute(
      [:loopctl, :memory_graduation, :swept],
      %{candidates: length(candidates), processed: processed, graduated: graduated},
      %{}
    )

    :ok
  end

  # Returns 1 on a successful graduation (any novelty-gate verdict), 0 on a write error
  # (left un-stamped so a later tick retries). A per-memory failure never aborts the run.
  defp graduate(memory) do
    case Memory.graduate_memory_record(memory, []) do
      {:ok, _verdict, _article} ->
        1

      {:error, reason} ->
        # `tenant_id`/`id` are server-derived UUIDs (safe to interpolate); `reason` is
        # inspected so a changeset/term can't forge log lines.
        Logger.warning(
          "MemoryGraduationSweepWorker: graduation failed tenant=#{memory.tenant_id} " <>
            "memory=#{memory.id} reason=#{inspect(reason)}"
        )

        0
    end
  end

  # Candidate scan with PER-TENANT FAIRNESS (BYPASSRLS). A single global
  # `ORDER BY recall_count DESC` scan let one hot tenant monopolize the whole per-run
  # budget (starving every other tenant), AND the tenant-leading partial index
  # `memories_graduation_sweep_idx (tenant_id, recall_count)` cannot even serve a
  # cross-tenant global sort (no tenant equality → Postgres must add a sort). So instead:
  #
  #   1. Enumerate the tenants with at least one eligible (hot, live, ungraduated) memory
  #      (bounded by `graduation_scan_limit/0` tenants per tick).
  #   2. For EACH tenant pull its hottest eligible memories, capped at
  #      `graduation_max_per_run/0` — this per-tenant query (`tenant_id = ? ...
  #      ORDER BY recall_count DESC`) is exactly what the partial index serves (equality +
  #      in-index descending scan, no sort).
  #   3. ROUND-ROBIN interleave the per-tenant lists so the global per-run budget (applied
  #      in `perform/1`) is spread fairly: a tenant with few hot memories is fully served
  #      early instead of waiting behind a hotter tenant's long tail. With one active
  #      tenant the interleave is a no-op, so budget is still fully utilized.
  defp candidate_memories(threshold) do
    per_tenant_limit = Memory.graduation_max_per_run()

    threshold
    |> eligible_tenant_ids(Memory.graduation_scan_limit())
    |> Enum.map(&hot_memories_for_tenant(&1, threshold, per_tenant_limit))
    |> round_robin()
  end

  # Distinct tenants owning at least one eligible memory, bounded so the sweep cannot fan
  # out over unbounded tenants in one tick. Ordered for determinism.
  defp eligible_tenant_ids(threshold, tenant_limit) do
    from(m in MemorySchema,
      where:
        m.recall_count >= ^threshold and is_nil(m.graduated_at) and
          is_nil(m.superseded_by),
      distinct: true,
      select: m.tenant_id,
      order_by: [asc: m.tenant_id],
      limit: ^tenant_limit
    )
    |> AdminRepo.all()
  end

  # Hottest eligible memories for ONE tenant (deterministic tiebreak on id), capped. The
  # WHERE + ORDER match `memories_graduation_sweep_idx (tenant_id, recall_count)`.
  defp hot_memories_for_tenant(tenant_id, threshold, limit) do
    from(m in MemorySchema,
      where:
        m.tenant_id == ^tenant_id and m.recall_count >= ^threshold and
          is_nil(m.graduated_at) and is_nil(m.superseded_by),
      order_by: [desc: m.recall_count, asc: m.id],
      limit: ^limit
    )
    |> AdminRepo.all()
  end

  # Round-robin flatten: [[a1,a2],[b1],[c1,c2,c3]] -> [a1,b1,c1,a2,c2,c3]. Takes one head
  # from each non-empty list per pass, so the global budget is spread across tenants.
  defp round_robin(lists) do
    case Enum.reject(lists, &(&1 == [])) do
      [] ->
        []

      nonempty ->
        Enum.map(nonempty, &hd/1) ++ round_robin(Enum.map(nonempty, &tl/1))
    end
  end
end
