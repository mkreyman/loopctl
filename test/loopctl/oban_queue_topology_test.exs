defmodule Loopctl.ObanQueueTopologyTest do
  @moduledoc """
  US-36.1: queue topology — a dedicated `:ingestion` queue for the long (~6-min) LLM
  `ContentIngestionWorker` so a burst of ingests can no longer head-of-line-block the
  sub-second `:knowledge` workers (GH #351), plus registration of the previously dead
  `:verification` queue that `VerificationRunnerWorker` targets.

  (`:knowledge` hosts SEVEN workers: six sub-second — linking/lint/MOC/metrics/
  reclassify/review — plus the daily `PromotionEvalWorker` LLM eval, which is a
  once-daily cron rather than part of the sub-second hot lane the split protects.)

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
  alias Loopctl.Workers.KnowledgeLintWorker
  alias Loopctl.Workers.KnowledgeMocWorker
  alias Loopctl.Workers.KnowledgeReclassifyWorker
  alias Loopctl.Workers.PromotionEvalWorker
  alias Loopctl.Workers.RetrievalMetricsWorker
  alias Loopctl.Workers.ReviewKnowledgeWorker
  alias Loopctl.Workers.VerificationRunnerWorker

  # The six workers AC-36.1.3 requires to REMAIN on :knowledge, plus PromotionEvalWorker
  # (the daily LLM eval that also targets :knowledge). Locking the full set means an
  # accidental future queue change on ANY of them fails this suite — not just on
  # ArticleLinkingWorker.
  @knowledge_workers [
    ArticleLinkingWorker,
    KnowledgeLintWorker,
    KnowledgeMocWorker,
    RetrievalMetricsWorker,
    KnowledgeReclassifyWorker,
    ReviewKnowledgeWorker,
    PromotionEvalWorker
  ]

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
      # The genuine mirror-drift guard. Comparing the RUNNING Oban config to
      # `ObanConfig.queues()` would be tautological: `config/runtime.exs` sets
      # `queues: ObanConfig.queues()` in every env and `Config` deep-merges the
      # keyword list, so the running value equals `ObanConfig.queues()` by
      # construction regardless of what config.exs contains — a config.exs edit that
      # drifts from ObanConfig could never fail it.
      #
      # Instead, read config.exs in ISOLATION (via `Config.Reader.read!/2`, WITHOUT
      # runtime.exs's override applied) to recover the raw compile-time literal, then
      # assert it equals the ObanConfig default (`ObanConfig.queues()` with no
      # OBAN_QUEUE_* env override, which the CI env guarantees). Now an edit to either
      # list that isn't mirrored in the other fails this test.
      config_exs_literal =
        "config/config.exs"
        |> Path.expand(File.cwd!())
        |> Config.Reader.read!(env: :test)
        |> get_in([:loopctl, Oban, :queues])

      assert config_exs_literal == ObanConfig.queues()
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
    # SCOPE OF THIS TEST: it proves queue SEPARATION structurally, not real under-load
    # blocking. Running in :manual mode, the ingestion jobs are enqueued but never
    # execute, so :ingestion is not actually saturated with running work and no
    # scheduler contention exists. What it asserts is that draining ONLY :knowledge
    # runs the linking job while leaving the ingestion jobs enqueued — which would FAIL
    # under the old single-:knowledge topology (the :knowledge drain would also pick up
    # the ingestion jobs). That structural separation is the mechanism behind the
    # head-of-line fix: because they are distinct queues/consumers, a saturated
    # :ingestion cannot occupy :knowledge slots. Truly saturating a queue with running
    # work requires live concurrency that Oban's testing modes don't model; for a
    # config-only topology change the separation guarantee is the load-bearing property.
    test "draining :knowledge runs the linking job while enqueued :ingestion jobs are left untouched (queue separation)" do
      tenant = fixture(:tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        # Enqueue several long ContentIngestionWorker jobs on :ingestion. In the old
        # single-queue topology these shared the :knowledge slots, so draining
        # :knowledge would also consume them; here they must stay put.
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
        # enqueued :ingestion jobs, because they are now separate queues/consumers.
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

    test "AC-36.1.3: EVERY knowledge worker stays on :knowledge, and ContentIngestionWorker is the only one that moved" do
      registered = ObanConfig.queues() |> Keyword.keys() |> MapSet.new()
      assert MapSet.member?(registered, :knowledge)

      # All six AC-enumerated workers (plus the daily PromotionEvalWorker) must remain
      # on :knowledge — locks the topology so an accidental queue change on any of them
      # (not just ArticleLinkingWorker) fails here.
      for worker <- @knowledge_workers do
        assert worker.__opts__()[:queue] == :knowledge,
               "#{inspect(worker)} must stay on :knowledge (AC-36.1.3)"
      end

      # ContentIngestionWorker is the ONLY worker this story moved off :knowledge.
      assert ContentIngestionWorker.__opts__()[:queue] == :ingestion
      refute ContentIngestionWorker in @knowledge_workers
    end
  end
end
