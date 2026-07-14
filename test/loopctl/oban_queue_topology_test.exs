defmodule Loopctl.ObanQueueTopologyTest do
  @moduledoc """
  US-36.1: queue topology — a dedicated `:ingestion` queue for the long (~6-min) LLM
  `ContentIngestionWorker` so a burst of ingests can no longer head-of-line-block the
  six sub-second `:knowledge` workers (GH #351), plus registration of the previously
  dead `:verification` queue that `VerificationRunnerWorker` targets.

  Needs the DB (Oban.insert / drain_queue), so it uses DataCase. The suite's default
  Oban testing mode is `:inline`; enqueue assertions run under
  `Oban.Testing.with_testing_mode(:manual, ...)` (process-scoped, async-safe — no
  global mutation) so jobs are observable via `assert_enqueued` rather than executing
  synchronously on insert.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  alias Loopctl.ObanConfig
  alias Loopctl.Workers.ArticleLinkingWorker
  alias Loopctl.Workers.ContentIngestionWorker
  alias Loopctl.Workers.VerificationRunnerWorker

  describe "TC-36.1.1: queue widths / pool budget (rebalance, not new capacity)" do
    test "`:ingestion` and `:verification` are registered with env-driven default widths" do
      queues = ObanConfig.queues()

      assert Keyword.get(queues, :ingestion) == 2
      assert Keyword.get(queues, :verification) == 1
      # `:knowledge` was rebalanced 5 -> 2 to fund the two new queues (5 = 2+2+1).
      assert Keyword.get(queues, :knowledge) == 2
    end

    test "the total pool budget stays at 38 across 11 queues (no blind capacity add)" do
      queues = ObanConfig.queues()

      assert length(queues) == 11
      assert queues |> Keyword.values() |> Enum.sum() == 38
    end

    test "AC-36.1.5: the config.exs compile-time mirror matches the ObanConfig defaults" do
      # runtime.exs sources `queues:` from `ObanConfig.queues()`, so the running Oban
      # config must equal it exactly — the cardinality/consistency guard (TC-32.2.1 style)
      # that catches a config.exs mirror drifting from the ObanConfig source of truth.
      running = Application.get_env(:loopctl, Oban)[:queues]
      assert running == ObanConfig.queues()
    end
  end

  describe "TC-36.1.2: ContentIngestionWorker enqueues on :ingestion, never :knowledge" do
    test "a ContentIngestionWorker job lands on :ingestion" do
      tenant = fixture(:tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, _job} =
          %{
            "tenant_id" => tenant.id,
            "content" => "some content",
            "content_hash" => "topology_ingest_#{System.unique_integer([:positive])}",
            "source_type" => "newsletter"
          }
          |> ContentIngestionWorker.new()
          |> Oban.insert()

        assert_enqueued(worker: ContentIngestionWorker, queue: :ingestion)
        refute_enqueued(worker: ContentIngestionWorker, queue: :knowledge)
      end)
    end
  end

  describe "TC-36.1.3: head-of-line fix — :knowledge drains independently of :ingestion" do
    test "with :ingestion saturated by long jobs, a :knowledge linking job still executes" do
      tenant = fixture(:tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        # Saturate :ingestion with several long ContentIngestionWorker jobs. In the old
        # single-queue topology these would occupy the shared :knowledge slots and block
        # the fast linking job behind them.
        for _ <- 1..3 do
          {:ok, _} =
            %{
              "tenant_id" => tenant.id,
              "content" => "long llm content",
              "content_hash" => "saturate_#{System.unique_integer([:positive])}",
              "source_type" => "newsletter"
            }
            |> ContentIngestionWorker.new()
            |> Oban.insert()
        end

        # A fast :knowledge job (linking a now-missing article => cheap :ok no-op).
        {:ok, _} =
          %{"tenant_id" => tenant.id, "article_id" => Ecto.UUID.generate()}
          |> ArticleLinkingWorker.new()
          |> Oban.insert()

        assert_enqueued(worker: ArticleLinkingWorker, queue: :knowledge)

        # Draining ONLY :knowledge runs the linking job — it is not stuck behind the
        # saturated :ingestion queue, because they are now separate queues/consumers.
        assert %{success: 1} = Oban.drain_queue(queue: :knowledge)

        # The linking job ran (no longer enqueued)...
        refute_enqueued(worker: ArticleLinkingWorker)
        # ...while the long ingestion jobs are untouched by the :knowledge drain.
        assert_enqueued(worker: ContentIngestionWorker, queue: :ingestion)
      end)
    end
  end

  describe "TC-36.1.4: no worker targets an unregistered (phantom) queue" do
    test ":verification is registered so VerificationRunnerWorker jobs actually run" do
      # GROUNDED DECISION: REGISTER (do not remove). Verification is a LIVE feature —
      # `Loopctl.Verification.create_run_and_enqueue/3` enqueues VerificationRunnerWorker
      # inside an Ecto.Multi on `queue: :verification`. Leaving it unregistered meant those
      # jobs enqueued but never ran; registering it (env-driven width) makes them run.
      registered = ObanConfig.queues() |> Keyword.keys() |> MapSet.new()

      assert :verification in registered
      assert VerificationRunnerWorker.__opts__()[:queue] == :verification
    end

    test "the workers changed by this story target registered queues" do
      registered = ObanConfig.queues() |> Keyword.keys() |> MapSet.new()

      assert ContentIngestionWorker.__opts__()[:queue] == :ingestion
      assert MapSet.member?(registered, :ingestion)

      # The short jobs stay on :knowledge (AC-36.1.3).
      assert ArticleLinkingWorker.__opts__()[:queue] == :knowledge
      assert MapSet.member?(registered, :knowledge)
    end
  end
end
