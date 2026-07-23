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

  1. **Candidates (per-tenant fair, bounded fetch)** — LIVE (`superseded_by IS NULL`),
     NOT-yet-graduated (`graduated_at IS NULL`) memories at or above the recall threshold,
     gathered with PER-TENANT FAIRNESS so one hot tenant cannot monopolize the per-run
     budget and starve others. The sweep samples eligible tenants (a RANDOM per-tick
     subset, capped at `min(scan_limit, max_per_run)` — see "Fairness" below), pulls each
     sampled tenant's hottest eligible memories via a `tenant_id = ? ... ORDER BY
     recall_count DESC` query that the partial index
     `memories_graduation_sweep_idx (tenant_id, recall_count)` serves (equality +
     in-index descending scan, no sort — a bare cross-tenant global sort could NOT use
     this tenant-leading index), then ROUND-ROBIN interleaves the per-tenant lists so
     every sampled tenant is served each tick. The per-tenant slice is only
     `ceil(max_per_run / n_tenants)` rows, so the WORST-CASE candidate rows fetched per
     tick is ~`2 * max_per_run` — NOT `scan_limit * max_per_run`.
  2. **Graduate + stamp** — each candidate goes through
     `Loopctl.Memory.graduate_memory_record/2`, which writes the article via the
     NOVELTY GATE (`Loopctl.Knowledge.propose_article/3`, so a semantically-duplicate
     memory does not bloat the corpus) and stamps `graduated_at` on ANY DURABLE verdict
     so it is never re-processed. A `:created`/`:duplicate`/`:deduplicated` verdict means
     a PUBLISHED (searchable) article represents the content; `:gated_to_draft` means a
     review-queue draft does (not yet searchable). A structural changeset failure is ALSO
     stamped (it can never succeed) to prevent a per-slot livelock. A TRANSIENT
     `:gate_unavailable` (embedding backend down, gate could not assess) is NOT stamped
     and creates nothing, so the memory re-graduates and dedups once embeddings recover.
  3. **Per-run execution budget** — at most `Loopctl.Memory.graduation_max_per_run/0`
     memories are processed per tick, bounding the novelty-gate embedding spend per run.

  ## Fairness across ticks (no tenant starvation)

  Tenant selection is a RANDOM per-tick sample of the eligible tenants (`ORDER BY
  RANDOM() LIMIT n`), NOT an ascending `tenant_id` scan. A deterministic ascending scan
  would serve the same lowest-UUID tenants every tick and, with more sustained hot
  tenants than the per-run budget, PERMANENTLY starve higher-UUID tenants. Random
  sampling gives every eligible tenant a fair chance each tick, so a large cross-tenant
  backlog drains without a persistent ordering bias. Round-robin only fixes fairness
  AMONG the sampled tenants; the random sample is what fixes fairness ACROSS ticks.

  ## Scope is PRESERVED — the sweep never re-scopes

  A candidate graduates to the SAME scope as the memory (project memory → project
  article, global memory → global article). The sweep NEVER promotes a project memory to
  a tenant-wide article: over-generalizing a project fact is a mis-scoping the novelty
  gate cannot catch, so local→global re-scope is an EXPLICIT caller action only
  (`Loopctl.Memory.graduate_memory/3` with `re_scope: :global`).

  ## Concurrency / idempotency

  Overlap-safety does NOT rest on the `unique: [fields: [:worker], period: 60]` guard:
  on an HOURLY cron a 60s uniqueness window only dedups near-simultaneous ENQUEUES (it
  never fires between hourly ticks). What actually makes two overlapping runs safe is the
  IDEMPOTENCY of graduation: (a) the conditional `graduated_at` stamp (only if still
  NULL) and (b) the stable per-memory, per-scope `idempotency_key` + novelty gate in
  `graduate_memory_record/2` — so even a race that re-proposes a memory yields ONE
  article, not a duplicate.

  ## Observability

  The `[:loopctl, :memory_graduation, :swept]` telemetry breaks the outcome down
  per-verdict (`created`/`duplicate`/`deduplicated`/`gated_to_draft`/`gate_unavailable`/
  `structural_error`/`error`) so an operator can distinguish PUBLISHED (searchable)
  graduations from invisible review-queue DRAFTS, spot a transient embedding outage
  (`gate_unavailable`), and detect the silent stamped-without-article path
  (`structural_error`) rather than seeing one conflated `graduated` count.
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

  # Verdicts that leave a DURABLE article (published or draft) and stamp graduated_at.
  @durable_verdicts [:created, :duplicate, :deduplicated, :gated_to_draft]

  # Synthetic actor so sweep-created articles are attributable in the audit/curation log
  # (distinct from a manual api_key-created article).
  @actor_opts [actor_type: "system", actor_label: "memory_graduation_sweep"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    cap = resolve_cap(args)
    candidates = candidate_memories(cap)

    {processed, tally} =
      Enum.reduce_while(candidates, {0, %{}}, fn memory, {processed, tally} ->
        if processed >= cap do
          {:halt, {processed, tally}}
        else
          outcome = graduate(memory)
          {:cont, {processed + 1, Map.update(tally, outcome, 1, &(&1 + 1))}}
        end
      end)

    graduated = @durable_verdicts |> Enum.map(&count(tally, &1)) |> Enum.sum()

    :telemetry.execute(
      [:loopctl, :memory_graduation, :swept],
      %{
        candidates: length(candidates),
        processed: processed,
        graduated: graduated,
        created: count(tally, :created),
        duplicate: count(tally, :duplicate),
        deduplicated: count(tally, :deduplicated),
        gated_to_draft: count(tally, :gated_to_draft),
        gate_unavailable: count(tally, :gate_unavailable),
        structural_error: count(tally, :structural_error),
        error: count(tally, :error)
      },
      %{}
    )

    :ok
  end

  defp count(tally, key), do: Map.get(tally, key, 0)

  # Returns the per-memory OUTCOME atom for telemetry:
  #
  #   * a durable verdict (`:created`/`:duplicate`/`:deduplicated`/`:gated_to_draft`) —
  #     a durable article now represents the content (stamped);
  #   * `:gate_unavailable` — TRANSIENT (embedding backend down), NOT stamped, retried
  #     next tick — deliberately NOT a failure;
  #   * `:structural_error` — a deterministic changeset failure; the memory is stamped
  #     but NO durable article exists (a silent-drop signal worth its own counter);
  #   * `:error` — any other write error (left un-stamped so a later tick retries).
  #
  # A per-memory failure — INCLUDING a raise inside the novelty gate / stamp — never
  # aborts the run (the try/rescue matches the moduledoc's guarantee).
  defp graduate(memory) do
    case Memory.graduate_memory_record(memory, @actor_opts) do
      {:ok, verdict, _article} ->
        verdict

      {:error, :gate_unavailable} ->
        :gate_unavailable

      {:error, %Ecto.Changeset{}} ->
        # graduate_memory_record already logged the structural detail; the dedicated
        # telemetry counter is what surfaces the stamped-without-article drop.
        :structural_error

      {:error, reason} ->
        Logger.warning(
          "MemoryGraduationSweepWorker: graduation failed tenant=#{memory.tenant_id} " <>
            "memory=#{memory.id} reason=#{inspect(reason)}"
        )

        :error
    end
  rescue
    error ->
      # A pathological memory (embedding task crash, DB hiccup mid-stamp) must not abort
      # the whole tick and force an Oban retry of already-completed work. Isolate it.
      Logger.error(
        "MemoryGraduationSweepWorker: graduation crashed tenant=#{memory.tenant_id} " <>
          "memory=#{memory.id} error=#{Exception.message(error)}"
      )

      :error
  end

  # Candidate scan with PER-TENANT FAIRNESS (BYPASSRLS) and a BOUNDED fetch.
  #
  #   1. Sample the tenants owning at least one eligible (hot, live, ungraduated) memory —
  #      a RANDOM per-tick subset capped at `min(scan_limit, max_per_run)`. Random (not
  #      ascending tenant_id) so no set of tenants is permanently served first.
  #   2. For EACH sampled tenant pull its hottest eligible memories, capped at
  #      `ceil(max_per_run / n_tenants)` — enough to fill the per-run budget without a
  #      50x over-fetch. This per-tenant query (`tenant_id = ? ... ORDER BY recall_count
  #      DESC`) is exactly what the partial index serves (equality + in-index descending
  #      scan, no sort).
  #   3. ROUND-ROBIN interleave the per-tenant lists so the global per-run budget is
  #      spread fairly: a tenant with few hot memories is fully served early instead of
  #      waiting behind a hotter tenant's long tail. With one active tenant the interleave
  #      is a no-op, so budget is still fully utilized.
  # The per-run execution budget. Defaults to the configured `graduation_max_per_run/0`,
  # but an explicit `"max_per_run"` in the Oban job args overrides it for THIS invocation.
  # Job args are per-job and travel with the job row, so a caller (or a test) can bound a
  # single tick WITHOUT mutating VM-global config — the async-safe alternative to
  # `Application.put_env`, which would leak the cap into every other test/job in the VM.
  defp resolve_cap(args) do
    case args do
      %{"max_per_run" => n} when is_integer(n) and n > 0 -> n
      _ -> Memory.graduation_max_per_run()
    end
  end

  defp candidate_memories(cap) do
    threshold = Memory.graduation_recall_threshold()

    # Round-robin serves >=1 memory per tenant and perform/1 processes at most `cap`
    # memories, so at most `cap` tenants can contribute in one tick — never fetch more.
    tenant_limit = min(Memory.graduation_scan_limit(), cap)

    case eligible_tenant_ids(threshold, tenant_limit) do
      [] ->
        []

      tenant_ids ->
        per_tenant_limit = ceil_div(cap, length(tenant_ids))

        tenant_ids
        |> Enum.map(&hot_memories_for_tenant(&1, threshold, per_tenant_limit))
        |> round_robin()
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  # A RANDOM sample of distinct tenants owning at least one eligible memory, capped so the
  # sweep cannot fan out over unbounded tenants in one tick. `ORDER BY RANDOM()` (over the
  # DISTINCT-tenant subquery) gives every eligible tenant a fair per-tick chance rather
  # than permanently serving the lowest tenant_ids first.
  defp eligible_tenant_ids(threshold, tenant_limit) do
    distinct_q =
      from(m in MemorySchema,
        where:
          m.recall_count >= ^threshold and is_nil(m.graduated_at) and
            is_nil(m.superseded_by),
        distinct: true,
        select: %{tenant_id: m.tenant_id}
      )

    from(t in subquery(distinct_q),
      order_by: fragment("RANDOM()"),
      limit: ^tenant_limit,
      select: t.tenant_id
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
