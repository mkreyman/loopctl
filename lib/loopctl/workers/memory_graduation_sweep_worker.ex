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

  1. **Candidates** — ONE cross-tenant (`Loopctl.AdminRepo`, BYPASSRLS) scan for LIVE
     (`superseded_by IS NULL`), NOT-yet-graduated (`graduated_at IS NULL`) memories at or
     above the recall threshold, hottest first, capped at
     `Loopctl.Memory.graduation_scan_limit/0`. Backed by the partial index
     `memories_graduation_sweep_idx` so already-graduated/cold rows never consume a scan
     slot.
  2. **Graduate + stamp** — each candidate goes through
     `Loopctl.Memory.graduate_memory_record/2`, which writes the article via the
     NOVELTY GATE (`Loopctl.Knowledge.propose_article/3`, so a semantically-duplicate
     memory does not bloat the corpus) and stamps `graduated_at` on ANY successful
     verdict — including `:duplicate`/`:deduplicated` (the memory's content is now
     durable either way) — so it is never re-processed.
  3. **Per-run execution budget** — at most `Loopctl.Memory.graduation_max_per_run/0`
     memories are processed per tick, bounding the novelty-gate embedding spend per run
     (the analogue of the promotion sweep's per-tick cap).

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
    candidates = candidate_memories(threshold, Memory.graduation_scan_limit())

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

  # Cross-tenant (BYPASSRLS) candidate scan: live, not-yet-graduated memories at/above
  # the recall threshold, HOTTEST first (deterministic tiebreak on id), capped. The
  # WHERE matches the partial index `memories_graduation_sweep_idx`.
  defp candidate_memories(threshold, limit) do
    from(m in MemorySchema,
      where:
        m.recall_count >= ^threshold and is_nil(m.graduated_at) and
          is_nil(m.superseded_by),
      order_by: [desc: m.recall_count, asc: m.id],
      limit: ^limit
    )
    |> AdminRepo.all()
  end
end
