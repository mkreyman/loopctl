defmodule Loopctl.Oban.FairShareTest do
  @moduledoc """
  US-36.2 — per-tenant in-flight fair-share gate.

  Covers the shared count helper (TC-36.2.1 / AC-36.2.1), tenant isolation
  (AC-36.2.6), the derived caps + bounded/jittered snooze (AC-36.2.4 / AC-36.2.5),
  and the `gate/2` snooze decision (AC-36.2.2).
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Oban.FairShare
  alias Loopctl.ObanConfig

  # Seed a raw oban_jobs row in a given state/queue for a tenant. oban_jobs is
  # Oban-owned and has no RLS, so we insert through AdminRepo (as FairShare reads).
  # Direct struct/changeset insert does NOT run the job (unlike Oban.insert under
  # :inline), which is exactly what we need to simulate occupied slots.
  # FairShare counts by (queue, state, tenant) regardless of worker, so the seeded
  # worker string is arbitrary. Use a synthetic placeholder (NOT a real worker
  # module) so these fixtures don't couple to any specific worker's lifecycle — e.g.
  # a future removal of the now-batch-superseded single-item ArticleEmbeddingWorker
  # (US-37.4 review LOW) can't silently break them.
  @seed_worker "Loopctl.Test.FairShareSeedWorker"

  defp seed_job(tenant_id, queue, state, opts \\ []) do
    worker = Keyword.get(opts, :worker, @seed_worker)

    %{"tenant_id" => tenant_id}
    |> Oban.Job.new(worker: worker, queue: to_string(queue))
    |> Ecto.Changeset.put_change(:state, state)
    |> AdminRepo.insert!()
  end

  describe "in_flight_count/2 + executing_count/2 (TC-36.2.1, AC-36.2.1)" do
    test "counts only the tenant's non-terminal jobs; excludes completed/discarded" do
      tenant_a = Ecto.UUID.generate()

      seed_job(tenant_a, :embeddings, "available")
      seed_job(tenant_a, :embeddings, "scheduled")
      seed_job(tenant_a, :embeddings, "executing")
      seed_job(tenant_a, :embeddings, "retryable")
      # Terminal states must NOT be counted.
      seed_job(tenant_a, :embeddings, "completed")
      seed_job(tenant_a, :embeddings, "discarded")
      seed_job(tenant_a, :embeddings, "cancelled")

      assert FairShare.in_flight_count(tenant_a, :embeddings) == 4
      assert FairShare.executing_count(tenant_a, :embeddings) == 1
    end

    test "is scoped to the given queue" do
      tenant_a = Ecto.UUID.generate()

      seed_job(tenant_a, :embeddings, "executing")
      seed_job(tenant_a, :knowledge, "executing")
      seed_job(tenant_a, :knowledge, "executing")

      assert FairShare.executing_count(tenant_a, :embeddings) == 1
      assert FairShare.executing_count(tenant_a, :knowledge) == 2
    end
  end

  describe "in_flight_ingestion_backlog/1 (US-36.3 — worker-scoped, index-backed)" do
    test "counts the tenant's non-terminal ContentIngestionWorker jobs; excludes terminal" do
      tenant = Ecto.UUID.generate()
      w = "Loopctl.Workers.ContentIngestionWorker"

      seed_job(tenant, :ingestion, "available", worker: w)
      seed_job(tenant, :ingestion, "scheduled", worker: w)
      seed_job(tenant, :ingestion, "executing", worker: w)
      seed_job(tenant, :ingestion, "retryable", worker: w)
      # Terminal states must NOT be counted.
      seed_job(tenant, :ingestion, "completed", worker: w)
      seed_job(tenant, :ingestion, "discarded", worker: w)

      assert FairShare.in_flight_ingestion_backlog(tenant) == 4
    end

    test "is scoped to the ingestion worker, not merely the queue — other workers excluded" do
      tenant = Ecto.UUID.generate()
      w = "Loopctl.Workers.ContentIngestionWorker"

      seed_job(tenant, :ingestion, "available", worker: w)
      # A different worker (even on the same queue string) must not be counted by the
      # worker-scoped backlog — the count keys on `worker`, so it rides the partial index.
      seed_job(tenant, :ingestion, "available", worker: "Loopctl.Workers.SomeOtherWorker")
      seed_job(tenant, :embeddings, "available", worker: @seed_worker)

      assert FairShare.in_flight_ingestion_backlog(tenant) == 1
    end

    test "is tenant-scoped — A's ingestion backlog never includes B's" do
      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()
      w = "Loopctl.Workers.ContentIngestionWorker"

      seed_job(tenant_a, :ingestion, "available", worker: w)
      for _ <- 1..3, do: seed_job(tenant_b, :ingestion, "available", worker: w)

      assert FairShare.in_flight_ingestion_backlog(tenant_a) == 1
      assert FairShare.in_flight_ingestion_backlog(tenant_b) == 3
    end
  end

  describe "tenant isolation (AC-36.2.6)" do
    test "tenant A's count never includes tenant B's jobs" do
      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()

      seed_job(tenant_a, :embeddings, "executing")
      # A pile of B's jobs on the same queue must be invisible to A's count.
      for _ <- 1..5, do: seed_job(tenant_b, :embeddings, "executing")

      assert FairShare.executing_count(tenant_a, :embeddings) == 1
      assert FairShare.executing_count(tenant_b, :embeddings) == 5
      # A's fair-share decision reads only A's count → A (1) is under cap (3).
      refute FairShare.over_fair_share?(tenant_a, :embeddings)
      # B (5) is over its cap (3) — decided purely on B's own count.
      assert FairShare.over_fair_share?(tenant_b, :embeddings)
    end
  end

  describe "tenant_fair_share_cap/1 (AC-36.2.4)" do
    test "derives ceil(width/2), floored at 1, from the queue width" do
      # Default widths (US-36.1): embeddings 5, knowledge 3, ingestion 2.
      assert ObanConfig.tenant_fair_share_cap(:embeddings) == 3
      assert ObanConfig.tenant_fair_share_cap(:knowledge) == 2
      assert ObanConfig.tenant_fair_share_cap(:ingestion) == 1
    end

    test "never returns a cap below 1 (the gate can never wedge a queue)" do
      for queue <- [:embeddings, :knowledge, :ingestion, :verification] do
        assert ObanConfig.tenant_fair_share_cap(queue) >= 1
      end
    end
  end

  describe "snooze_seconds/0 (AC-36.2.5)" do
    test "is bounded within [base, base + jitter] and jittered" do
      base = ObanConfig.fair_share_snooze_base_seconds()
      jitter = ObanConfig.fair_share_snooze_jitter_seconds()

      values = for _ <- 1..200, do: FairShare.snooze_seconds()

      assert Enum.all?(values, &(&1 >= base and &1 <= base + jitter))
      assert Enum.all?(values, &(&1 >= 1))
      # With the default 5s jitter the sample must show more than one distinct value.
      assert values |> Enum.uniq() |> length() > 1
    end

    test "defaults are sensible (5s base, 5s jitter → 5-10s)" do
      assert ObanConfig.fair_share_snooze_base_seconds() == 5
      assert ObanConfig.fair_share_snooze_jitter_seconds() == 5
    end
  end

  describe "gate/2 decision (AC-36.2.2)" do
    test "returns :ok when the tenant is under its fair share" do
      tenant_a = Ecto.UUID.generate()
      # cap for :embeddings is 3; seed 2 executing → under cap.
      seed_job(tenant_a, :embeddings, "executing")
      seed_job(tenant_a, :embeddings, "executing")

      assert FairShare.gate(tenant_a, :embeddings) == :ok
    end

    test "returns {:snooze, n} (bounded) when the tenant is at/above its fair share" do
      tenant_a = Ecto.UUID.generate()
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)
      for _ <- 1..cap, do: seed_job(tenant_a, :embeddings, "executing")

      assert {:snooze, n} = FairShare.gate(tenant_a, :embeddings)
      assert n >= ObanConfig.fair_share_snooze_base_seconds()

      assert n <=
               ObanConfig.fair_share_snooze_base_seconds() +
                 ObanConfig.fair_share_snooze_jitter_seconds()
    end

    test "an uncontended tenant (no in-flight jobs) is never gated" do
      assert FairShare.gate(Ecto.UUID.generate(), :embeddings) == :ok
    end
  end

  # Under Oban's Basic engine the fetched job is committed to state="executing" BEFORE
  # perform/1 runs, so a job reads its OWN row when it counts executing slots. The gate
  # decides by RANK: a job snoozes only if `cap` or more of the tenant's OTHER executing
  # jobs have a strictly LOWER id (`id < job_id`). That self-excludes the running job
  # for free (cap=1 :ingestion never wedges; a gated queue gives the full cap, not
  # cap-1) AND deterministically breaks the co-fetch symmetry (see the next describe).
  # These tests seed the job-under-test's own executing row — the real executing-state
  # semantics the bare-perform tests miss.
  describe "rank self-exclusion: the running job never counts itself (US-36.2 wedge fix)" do
    test "a lone executing :ingestion job (cap=1) is NOT gated once it excludes itself" do
      tenant = Ecto.UUID.generate()

      job =
        seed_job(tenant, :ingestion, "executing",
          worker: "Loopctl.Workers.ContentIngestionWorker"
        )

      # cap for :ingestion is 1. The UNSCOPED count includes the running job...
      assert FairShare.executing_count(tenant, :ingestion) == 1
      # ...so a naive `>= cap` (nil job_id, no rank) WEDGES: 1 >= 1 → over → snooze forever.
      assert FairShare.over_fair_share?(tenant, :ingestion, nil)
      # Rank of the lone job: 0 lower-id peers >= 1 → false → the lone job RUNS immediately.
      refute FairShare.over_fair_share?(tenant, :ingestion, job.id)
      assert FairShare.gate(tenant, :ingestion, job.id) == :ok
    end

    test "of two concurrent same-tenant jobs on cap=1, the LOWER-id runs and the HIGHER-id snoozes" do
      tenant = Ecto.UUID.generate()

      first =
        seed_job(tenant, :ingestion, "executing",
          worker: "Loopctl.Workers.ContentIngestionWorker"
        )

      second =
        seed_job(tenant, :ingestion, "executing",
          worker: "Loopctl.Workers.ContentIngestionWorker"
        )

      # `first` (lowest id) has 0 lower-id peers >= cap(1) → false → RUNS.
      assert FairShare.gate(tenant, :ingestion, first.id) == :ok
      # `second` has 1 lower-id peer (`first`) >= cap(1) → snoozes. Exactly ONE of the
      # two concurrent jobs is gated — contention detected, queue not wedged, and the
      # older job (not an arbitrary one) keeps its slot.
      assert {:snooze, _n} = FairShare.gate(tenant, :ingestion, second.id)
    end

    test "rank gives a tenant its FULL cap (embeddings 3), not cap-1; a NEWER job snoozes" do
      tenant = Ecto.UUID.generate()
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)

      # cap-1 OTHER executing jobs (lower ids) plus THIS running job = cap rows.
      for _ <- 1..(cap - 1), do: seed_job(tenant, :embeddings, "executing")
      running = seed_job(tenant, :embeddings, "executing")

      # Unscoped count = cap; a naive `cap >= cap` would snooze — the silent
      # under-utilization (effective cap-1) the medium finding describes.
      assert FairShare.executing_count(tenant, :embeddings) == cap
      # Rank of `running` = cap-1 lower-id peers < cap → the tenant's cap-th job RUNS:
      # it gets all `cap` concurrent slots, exactly as documented.
      refute FairShare.over_fair_share?(tenant, :embeddings, running.id)

      # One genuinely-additional, NEWER concurrent job (higher id). The rank decision
      # gates the NEWER arrival (rank cap >= cap → snooze), NOT the already-running
      # `running` (still rank cap-1 → runs): an executing job is never retroactively
      # pushed to snooze by a later arrival.
      newer = seed_job(tenant, :embeddings, "executing")
      assert FairShare.over_fair_share?(tenant, :embeddings, newer.id)
      refute FairShare.over_fair_share?(tenant, :embeddings, running.id)
    end
  end

  # The Basic engine commits a whole width-sized fetch to state="executing" in ONE txn
  # BEFORE dispatch, so under a one-tenant burst ALL co-fetched jobs are executing when
  # each runs its gate. A naive "count OTHER peers >= cap" would make every co-fetched
  # job see the others and snooze together — both slots idle. Under the default jitter
  # that desyncs and self-heals, but at the PERMITTED jitter=0 the jobs stay lockstep,
  # are co-fetched every cycle, and NEVER complete: a permanent livelock. The rank
  # decision admits exactly the lowest `cap` by id, DETERMINISTICALLY — independent of
  # read order AND of jitter — so "all snooze" is impossible and jitter=0 is safe.
  describe "co-fetch determinism: exactly the lowest-cap proceed, the rest snooze (US-36.2 livelock fix)" do
    test "cap=1 (:ingestion): of a co-fetched batch exactly ONE proceeds — never all-snooze" do
      tenant = Ecto.UUID.generate()

      jobs =
        for _ <- 1..4 do
          seed_job(tenant, :ingestion, "executing",
            worker: "Loopctl.Workers.ContentIngestionWorker"
          )
        end

      results = Enum.map(jobs, &FairShare.gate(tenant, :ingestion, &1.id))
      proceeded = Enum.count(results, &(&1 == :ok))
      snoozed = Enum.count(results, &match?({:snooze, _}, &1))

      # cap=1 → exactly one proceeds, three snooze. Crucially NOT zero proceeding (the
      # all-snooze livelock the medium finding describes).
      assert proceeded == 1
      assert snoozed == 3
      # And it is deterministically the LOWEST-id job that proceeds.
      lowest = Enum.min_by(jobs, & &1.id)
      assert FairShare.gate(tenant, :ingestion, lowest.id) == :ok
    end

    test "cap=3 (:embeddings): exactly the lowest 3 of a co-fetched batch of 5 proceed" do
      tenant = Ecto.UUID.generate()
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)
      assert cap == 3

      jobs = for _ <- 1..5, do: seed_job(tenant, :embeddings, "executing")
      {lowest_cap, rest} = jobs |> Enum.sort_by(& &1.id) |> Enum.split(cap)

      assert Enum.all?(lowest_cap, &(FairShare.gate(tenant, :embeddings, &1.id) == :ok))
      assert Enum.all?(rest, &match?({:snooze, _}, FairShare.gate(tenant, :embeddings, &1.id)))
    end
  end
end
