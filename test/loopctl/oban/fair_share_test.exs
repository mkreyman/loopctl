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
  defp seed_job(tenant_id, queue, state, opts \\ []) do
    worker = Keyword.get(opts, :worker, "Loopctl.Workers.ArticleEmbeddingWorker")

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
  # perform/1 runs, so a job reads its OWN row when it counts executing slots. Without
  # self-exclusion the running job counts itself: cap=1 (:ingestion) wedges forever and
  # every gated queue silently loses one slot (effective cap-1). gate/3 threads the
  # job_id so the running job is excluded. These tests seed the job-under-test's own
  # executing row — the real executing-state semantics the bare-perform tests miss.
  describe "self-exclusion: the running job never counts itself (US-36.2 wedge fix)" do
    test "a lone executing :ingestion job (cap=1) is NOT gated once it excludes itself" do
      tenant = Ecto.UUID.generate()

      job =
        seed_job(tenant, :ingestion, "executing",
          worker: "Loopctl.Workers.ContentIngestionWorker"
        )

      # cap for :ingestion is 1. The UNSCOPED count includes the running job...
      assert FairShare.executing_count(tenant, :ingestion) == 1
      # ...so a naive `>= cap` (no exclusion) WEDGES: 1 >= 1 → over → snooze forever.
      assert FairShare.over_fair_share?(tenant, :ingestion, nil)
      # Excluding the job itself: 0 >= 1 → false → the lone job RUNS immediately.
      refute FairShare.over_fair_share?(tenant, :ingestion, job.id)
      assert FairShare.gate(tenant, :ingestion, job.id) == :ok
    end

    test "a SECOND concurrent executing job for the same tenant on cap=1 IS still gated" do
      tenant = Ecto.UUID.generate()

      running =
        seed_job(tenant, :ingestion, "executing",
          worker: "Loopctl.Workers.ContentIngestionWorker"
        )

      # Another of the tenant's jobs is genuinely executing concurrently.
      seed_job(tenant, :ingestion, "executing", worker: "Loopctl.Workers.ContentIngestionWorker")

      # Excluding self still leaves 1 real peer >= cap(1) → snooze. Contention detected,
      # queue not wedged: the self-exclusion narrows the count, it doesn't disable it.
      assert {:snooze, _n} = FairShare.gate(tenant, :ingestion, running.id)
    end

    test "self-exclusion gives a tenant its FULL cap (embeddings 3), not cap-1" do
      tenant = Ecto.UUID.generate()
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)

      # cap-1 OTHER executing jobs plus THIS running job = cap rows in the table.
      for _ <- 1..(cap - 1), do: seed_job(tenant, :embeddings, "executing")
      running = seed_job(tenant, :embeddings, "executing")

      # Unscoped count = cap; a naive `cap >= cap` would snooze — the silent
      # under-utilization (effective cap-1) the medium finding describes.
      assert FairShare.executing_count(tenant, :embeddings) == cap
      # Excluding self = cap-1 < cap → the tenant's cap-th job RUNS: it gets all `cap`
      # concurrent slots, exactly as documented.
      refute FairShare.over_fair_share?(tenant, :embeddings, running.id)

      # One genuinely-additional concurrent job (cap peers + self) → cap >= cap → snooze.
      seed_job(tenant, :embeddings, "executing")
      assert FairShare.over_fair_share?(tenant, :embeddings, running.id)
    end
  end
end
