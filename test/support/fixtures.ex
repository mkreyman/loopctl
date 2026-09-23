defmodule Loopctl.Fixtures do
  @moduledoc """
  Test fixture helpers for building and inserting test data.

  - `build/2` — returns a map or struct without touching the database.
  - `fixture/2` — inserts into the database, auto-creating dependencies.

  All fixtures use binary UUIDs. Tenant isolation tests should create
  separate tenants via `fixture(:tenant)`.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.Artifacts.ArtifactReport
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.Intake.Delivery, as: IntakeDelivery
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Intake.Record, as: IntakeRecord
  alias Loopctl.Intake.Source, as: IntakeSource
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionWriteStats
  alias Loopctl.Knowledge.RetrievalEval.GoldenSet, as: RetrievalGoldenSet
  alias Loopctl.Knowledge.SearchEvent
  alias Loopctl.Llm.SettingsCache
  alias Loopctl.Llm.TenantLlmSettings
  alias Loopctl.Llm.UsageEvent, as: LlmUsageEvent
  alias Loopctl.Memory.Memory
  alias Loopctl.Memory.PromotionEval.Dataset, as: PromotionEvalDataset
  alias Loopctl.Memory.SessionMemory
  alias Loopctl.Memory.SessionPromotion
  alias Loopctl.Orchestrator.OrchestratorState
  alias Loopctl.Projects.Project
  alias Loopctl.QualityAssurance.UiTestRun
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.TraceEvent
  alias Loopctl.Skills.Skill
  alias Loopctl.Skills.SkillResult
  alias Loopctl.Skills.SkillVersion
  alias Loopctl.SystemConfig.Setting
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.Tenant
  alias Loopctl.TokenUsage.Budget, as: TokenBudget
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.TokenUsage.Report, as: TokenUsageReport
  alias Loopctl.Webhooks.Webhook
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.EpicDependency
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkBreakdown.StoryDependency

  # Persistent-term key holding the VM-global :atomics counter that backs
  # `next_story_number/0`. The counter is initialized once, single-threaded, in
  # `test/test_helper.exs` before any (async) test runs — see that file.
  @story_number_counter {__MODULE__, :story_number_counter}

  @doc """
  Returns a VM-globally-unique story `number` of the form `"MAJOR.MINOR"` where
  both parts are non-negative integers `< 10000` (satisfying `Story`'s
  number-format validation).

  Every call returns a distinct `(MAJOR, MINOR)` pair, so fixture-generated
  story numbers can never collide with one another *within any
  `(tenant_id, project_id)`* — structurally eliminating the intermittent
  `stories_tenant_id_project_id_number_index` fixture flake.

  The old scheme (`number: "1.\#{rem(seq, 9999) + 1}"`) was non-injective: it
  truncated an unbounded `System.unique_integer/1` into only 9999 minor buckets
  under a fixed major of `1`. Two stories in the same project collided whenever
  their seqs were congruent mod 9999 (or once a project exceeded 9999 stories),
  and a default minor of `1` collided with any test that inserted an explicit
  `"1.1"` in the same project.

  `MAJOR` starts at `1000` and only advances every 9000 numbers, so generated
  numbers never collide with the small, explicitly hard-coded numbers (`"1.1"`,
  `"2.3"`, `"72.3"`, …) that individual tests insert directly. The pair space
  covers 9000 × 9000 ≈ 81M distinct numbers — far beyond any suite.
  """
  @spec next_story_number() :: String.t()
  def next_story_number do
    n = :atomics.add_get(:persistent_term.get(@story_number_counter), 1, 1)
    major = 1000 + div(n - 1, 9000)
    minor = rem(n - 1, 9000) + 1
    "#{major}.#{minor}"
  end

  @doc """
  Builds a data map for the given type without database insertion.
  Useful for changeset tests and unit tests that don't need persistence.
  """
  # Slug prefix of every tenant `fixture(:committed_tenant)` commits; see the sweep below.
  @committed_runner_marker "committed-runner-"

  def build(type, attrs \\ %{})

  def build(:tenant, attrs) do
    Map.merge(
      %{
        name: "Test Tenant #{System.unique_integer([:positive])}",
        slug: "test-tenant-#{System.unique_integer([:positive])}",
        email: "test-#{System.unique_integer([:positive])}@example.com",
        settings: %{},
        status: :active,
        # US-26.7.1: default fixtures to the trusted, human-anchored tier so the
        # large existing custody-test surface is unaffected. Pass
        # `trust_tier: :agent_rooted` explicitly to get a KB-tier tenant.
        trust_tier: :human_anchored
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:system_config, attrs) do
    Map.merge(
      %{
        # Unique key per call so DB-backed system-config tests never collide on the
        # `system_configs_key_index` unique index, and so their :persistent_term
        # writes (VM-global) can't clobber another async test's cache entry.
        key: "test_config_#{System.unique_integer([:positive])}",
        value: System.unique_integer([:positive]),
        description: nil
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:root_authenticator, attrs) do
    attrs = Enum.into(attrs, %{})

    Map.merge(
      %{
        credential_id: :crypto.strong_rand_bytes(16),
        # COSE public key persisted the same way the Wax adapter does —
        # `:erlang.term_to_binary/1` of a COSE key map — so the reauth path
        # can round-trip it. The mock WebAuthn adapter ignores it in tests.
        public_key: :erlang.term_to_binary(%{1 => 2, 3 => -7}),
        attestation_format: "none",
        sign_count: 0,
        friendly_name: "Test Authenticator #{System.unique_integer([:positive])}"
      },
      attrs
    )
  end

  def build(:audit_log, attrs) do
    Map.merge(
      %{
        entity_type: "project",
        entity_id: Ecto.UUID.generate(),
        action: "created",
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "user:test",
        old_state: nil,
        new_state: %{"name" => "Test"},
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  # The `new_state` of ONE nightly `knowledge.lint_completed` audit event — healthy and
  # QUIET: every consumer was offered nothing, every gate is open, nothing failed.
  #
  # This is the corpus shape the consumer-stall dead-man's-switch
  # (`Loopctl.Knowledge.IngestionHealth.detect_consumer_stalled_scan/1`) must never alarm
  # on, so it is the base every stall test perturbs one key of. Top-level keys merge from
  # `attrs`; nest a `"consolidation"` map to override inside that object.
  def build(:knowledge_lint_state, attrs) do
    attrs = Enum.into(attrs, %{})
    {consolidation, attrs} = Map.pop(attrs, "consolidation", %{})

    base = %{
      # The lint findings block, which the detector's read strips (`new_state -
      # 'summary'`) because no consumer reading uses it and it is the largest thing here.
      "summary" => %{"total_issues" => 0, "total_per_category" => %{"orphan_articles" => 0}},
      "orphans_relinked" => 0,
      "orphans_embedding_enqueued" => 0,
      "drafts_published" => 0,
      "drafts_offered" => 0,
      "drafts_budget_exhausted" => false,
      "drafts_gate" => "open",
      "conflicts_promoted" => 0,
      "conflicts_judged_redundant" => 0,
      "conflicts_judge_candidates" => 0,
      "conflicts_judge_budget_exhausted" => false,
      "conflicts_judge_count_capped" => false,
      "links_pruned" => 0,
      "links_prunable_remaining" => 0,
      "resolutions_applied" => 0,
      "consolidation" =>
        Map.merge(
          %{
            "status" => "ok",
            "by_class" => %{"duplicate_capture" => 0, "generic_title" => 0},
            "duplicates_unpublished" => 0,
            "duplicate_groups_skipped" => 0,
            "duplicates_unpublish_failed" => 0,
            "duplicate_groups_uncorroborated" => 0,
            "duplicate_apply_gate" => "open",
            "generic_titles_retitled" => 0,
            "generic_titles_offered" => 0,
            "generic_titles_skipped" => 0,
            "generic_titles_abstained" => 0,
            "generic_titles_failed" => 0,
            "generic_title_budget_exhausted" => false,
            "generic_title_apply_gate" => "open"
          },
          consolidation
        )
    }

    Map.merge(base, attrs)
  end

  def build(:agent, attrs) do
    Map.merge(
      %{
        name: "agent-#{System.unique_integer([:positive])}",
        agent_type: :implementer,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:article, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        title: "Article #{seq}",
        body: "Test article body content for article #{seq}.",
        category: :pattern,
        status: :draft,
        tags: [],
        source_type: nil,
        source_id: nil,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  # --- Retrieval eval (#469) in-memory golden-set builders -------------------
  # Shaped exactly like `Loopctl.Knowledge.RetrievalEval.GoldenSet` normalizes the
  # committed JSONL, so a test can drive the eval with a 2-3 question set instead of
  # seeding the whole committed corpus.

  def build(:retrieval_golden_doc, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        doc_id: "doc-#{seq}",
        title: "Golden doc #{seq}",
        body: "Golden doc body #{seq}.",
        category: :pattern,
        tags: []
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:retrieval_golden_question, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        id: "q-#{seq}",
        question: "golden question #{seq}",
        source: "fixture",
        corpus: [],
        relevant: [],
        graded: %{},
        links: []
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:retrieval_golden_set, attrs) do
    Map.merge(
      %{version: "test_golden_v1", description: "fixture golden set", questions: []},
      Enum.into(attrs, %{})
    )
  end

  def build(:article_link, attrs) do
    Map.merge(
      %{
        relationship_type: :relates_to,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:search_event, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        query: "coverage query #{seq}",
        tool: "knowledge_search",
        mode_requested: "combined",
        mode_used: "combined",
        result_count: 3,
        duration_ms: 42,
        outcome: "ok"
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:article_access_event, attrs) do
    Map.merge(
      %{
        access_type: "get",
        metadata: %{},
        accessed_at: DateTime.utc_now()
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:entity, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        name: "entity_#{seq}",
        backing_source: :stories,
        fields: [%{name: "title", type: :string, filterable: true, searchable: true}]
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:memory, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        text: "Memory fact #{seq}",
        confidence: 1.0,
        source: :explicit,
        tags: []
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:session_memory, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        session_id: "session-#{seq}",
        role: :user,
        content: "Session turn #{seq}",
        metadata: %{},
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:project, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        name: "Test Project #{seq}",
        slug: "test-project-#{seq}",
        repo_url: "https://github.com/example/project-#{seq}",
        description: "A test project",
        tech_stack: "elixir/phoenix",
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:epic, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        number: seq,
        title: "Epic #{seq}",
        description: "Test epic description",
        phase: "p0_foundation",
        position: 0,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:story, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        number: next_story_number(),
        title: "Story #{seq}",
        description: "Test story description",
        acceptance_criteria: [],
        estimated_hours: nil,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:epic_dependency, attrs) do
    Enum.into(attrs, %{})
  end

  def build(:story_dependency, attrs) do
    Enum.into(attrs, %{})
  end

  def build(:orchestrator_state, attrs) do
    Map.merge(
      %{
        state_key: "main",
        state_data: %{"current_epic" => 1, "completed_stories" => []},
        version: 1
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:artifact_report, attrs) do
    Map.merge(
      %{
        artifact_type: "schema",
        path: "lib/loopctl/test.ex",
        exists: true,
        details: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:verification_result, attrs) do
    Map.merge(
      %{
        result: :pass,
        summary: "All checks passed",
        findings: %{},
        review_type: "enhanced_review",
        iteration: 1
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:webhook, attrs) do
    Map.merge(
      %{
        url: "https://example.com/hooks/#{System.unique_integer([:positive])}",
        events: ["story.status_changed"],
        active: true
      },
      Enum.into(attrs, %{})
    )
  end

  # Per-tenant BYO LLM config + usage (Epic 28 residual, #179).
  def build(:tenant_llm_settings, attrs) do
    Enum.into(attrs, %{
      api_key: "test-anthropic-test-#{System.unique_integer([:positive])}",
      # US-43.2: the EMBEDDING credential is a separate encrypted column from the
      # Anthropic one, and `Llm.resolve/2` reads only this column for `:embedding`.
      # Default nil so every existing fixture caller keeps its keyless-embedding
      # posture; pass it explicitly to exercise a BYO-embedding path.
      embedding_api_key: nil,
      extraction_model: nil,
      classification_model: nil,
      merge_model: nil,
      # US-41.3: NULL chat_provider means the unchanged Anthropic default.
      chat_provider: nil,
      chat_base_url: nil,
      chat_api_key: nil
    })
  end

  def build(:llm_usage_event, attrs) do
    Enum.into(attrs, %{
      operation: :extraction,
      model: "claude-haiku-4-5-20251001",
      input_tokens: 100,
      output_tokens: 50,
      source_type: "newsletter",
      article_id: nil,
      occurred_at: DateTime.utc_now()
    })
  end

  def build(:webhook_event, attrs) do
    Map.merge(
      %{
        event_type: "story.status_changed",
        payload: %{"event" => "story.status_changed", "data" => %{}},
        status: :pending,
        attempts: 0
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:api_key, attrs) do
    Map.merge(
      %{
        name: "test-key-#{System.unique_integer([:positive])}",
        role: :user
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:skill, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        name: "test-skill-#{seq}",
        description: "A test skill",
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:skill_version, attrs) do
    Map.merge(
      %{
        prompt_text: "Test prompt text for skill version",
        changelog: "Initial version",
        created_by: "test"
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:skill_result, attrs) do
    Map.merge(
      %{
        metrics: %{
          "findings_count" => 5,
          "false_positive_count" => 1,
          "true_positive_count" => 4
        }
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:ui_test_run, attrs) do
    Map.merge(
      %{
        guide_reference: "docs/user_guides/test_guide_#{System.unique_integer([:positive])}.md",
        started_at: DateTime.utc_now()
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:token_usage_report, attrs) do
    Map.merge(
      %{
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500,
        phase: "implementing",
        session_id: nil,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:token_budget, attrs) do
    Map.merge(
      %{
        scope_type: :story,
        budget_millicents: 500_000,
        budget_input_tokens: nil,
        budget_output_tokens: nil,
        alert_threshold_pct: 80,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:cost_summary, attrs) do
    Map.merge(
      %{
        scope_type: :project,
        period_start: Date.add(Date.utc_today(), -1),
        period_end: Date.add(Date.utc_today(), -1),
        total_input_tokens: 10_000,
        total_output_tokens: 5_000,
        total_cost_millicents: 25_000,
        report_count: 10,
        model_breakdown: %{},
        avg_cost_per_story_millicents: 2_500
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:cost_anomaly, attrs) do
    Map.merge(
      %{
        anomaly_type: :high_cost,
        story_cost_millicents: 75_000,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("3.0"),
        resolved: false,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:ingestion_anomaly, attrs) do
    Map.merge(
      %{
        source_type: "session_log",
        anomaly_type: :capture_silence,
        last_event_at: DateTime.add(DateTime.utc_now(), -96, :hour),
        hours_stale: 96,
        sample_count: 5,
        resolved: false,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:ingestion_write_stats, attrs) do
    Map.merge(
      %{
        source_type: "session_log",
        day: Date.utc_today(),
        created_count: 0,
        deduplicated_count: 0,
        drafted_count: 0,
        skipped_count: 0,
        title_conflict_count: 0,
        validation_error_count: 0
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:review_record, attrs) do
    Map.merge(
      %{
        review_type: "enhanced",
        findings_count: 0,
        fixes_count: 0,
        summary: "Review completed.",
        completed_at: DateTime.utc_now()
      },
      Enum.into(attrs, %{})
    )
  end

  # Delivery gates (#802). SYNTHETIC trigger data only: loopctl is public and the real
  # target repositories' trigger lists are configuration, never source.

  # The decoded trigger configuration document, string keys, one repository.
  # `Jason.encode!/1` it and pin its SHA-256 to feed `Triggers.parse/2`.
  def build(:delivery_gates_config, attrs) do
    Map.merge(
      %{
        "version" => 1,
        "repos" => %{
          "acme/claims-app" => %{
            "effect_paths" => ["priv/rates/**", "lib/app/payments/**", "config/runtime.exs"],
            "human_paths" => ["lib/app_web/router.ex", "lib/**/data_migrations/**"],
            "limits" => %{"max_files" => 12, "max_changed_lines" => 1000}
          }
        }
      },
      Enum.into(attrs, %{})
    )
  end

  # A `dispatch` payload that satisfies the runner contract's RunnerDispatch, string-keyed
  # as a caller building it from JSON would hand it over.
  def build(:runner_dispatch, attrs) do
    Map.merge(
      %{
        "dispatch_id" => Ecto.UUID.generate(),
        "story_id" => Ecto.UUID.generate(),
        "kind" => "implement",
        "repo" => "acme/widgets",
        "base_branch" => "master",
        "branch" => "feature/widget-rounding",
        "claim_epoch" => 0,
        "wall_clock_seconds" => 3_600,
        "max_turns" => 50
      },
      Enum.into(attrs, %{})
    )
  end

  # A `story` object satisfying the runner contract's RunnerStory (1.5.0), string-keyed as
  # `Loopctl.Delivery.ImplementerInput.story_object/2` emits it. Pass "id" to match a
  # dispatch's "story_id" — `cast_dispatch/1` refuses a story naming a different one.
  def build(:runner_story, attrs) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "title" => "Round a visit's billable minutes up to the nearest unit",
        "description" => "The monthly total must equal the sum of its visits.",
        "acceptance_criteria" => ["[AC-1] The monthly total equals the sum of its visits."],
        "test_cases" => ["A visit of 7 minutes bills one unit."],
        "touches" => ["lib/home_care_billing/billing/visit.ex"],
        "domain_reference" => "docs/architecture/timesheets-and-work-orders.md"
      },
      Enum.into(attrs, %{})
    )
  end

  # One event of a run's trace satisfying RunnerTraceEvent, string-keyed as the runner ships
  # it. Pass "run_id" and "seq"; the rest defaults.
  def build(:runner_trace_event, attrs) do
    attrs = Enum.into(attrs, %{})
    seq = Map.get(attrs, "seq", 0)

    Map.merge(
      %{
        "run_id" => Ecto.UUID.generate(),
        "seq" => seq,
        "event_id" => "evt-#{seq}",
        "parent" => if(seq == 0, do: nil, else: "evt-0"),
        "ts" => "2026-09-12T20:36:46.485Z",
        "type" => "claude.tool_use",
        "data" => %{"tool" => "Read"}
      },
      attrs
    )
  end

  # A `trace` batch for `run_id` carrying one event per seq in `seqs`.
  def build(:runner_trace_batch, attrs) do
    attrs = Enum.into(attrs, %{})
    run_id = Map.get(attrs, "run_id", Ecto.UUID.generate())
    seqs = Map.get(attrs, :seqs, [0])

    Map.merge(
      %{
        "run_id" => run_id,
        "dispatch_id" => Ecto.UUID.generate(),
        "claim_epoch" => 0,
        "events" =>
          Enum.map(seqs, &build(:runner_trace_event, %{"run_id" => run_id, "seq" => &1}))
      },
      Map.delete(attrs, :seqs)
    )
  end

  # A Gate B input for the repository above that touches nothing guarded.
  def build(:gate_b_input, attrs) do
    Map.merge(
      %{
        repo: "acme/claims-app",
        files: ["lib/app/accounts/user.ex"],
        renames: [],
        repo_files: [
          "README.md",
          "config/runtime.exs",
          "lib/app/accounts/user.ex",
          "lib/app/data_migrations/backfill_rates.ex",
          "lib/app/payments/submit.ex",
          "lib/app_web/router.ex",
          "priv/rates/2026.csv"
        ],
        diffstat: %{files: 1, changed_lines: 10}
      },
      Enum.into(attrs, %{})
    )
  end

  # The `git ls-files`-shaped tree the `:gate_b_input` repository above has, reused by the
  # measurement fixtures so a replayed change is judged against the same synthetic repository.
  @measurement_repo_files [
    "README.md",
    "config/runtime.exs",
    "lib/app/accounts/user.ex",
    "lib/app/data_migrations/backfill_rates.ex",
    "lib/app/payments/submit.ex",
    "lib/app_web/router.ex",
    "priv/rates/2026.csv"
  ]

  # One merged change for the Gate B measurement harness (#828). SYNTHETIC, like every other
  # delivery-gates fixture, for the same reason: the real target repository is private and its
  # trigger list is configuration.
  #
  # Pass `files:` as a list of paths (all modified) to get the `-z` name-status bytes built for
  # you, or `diff:` to supply the raw bytes yourself — a malformed diff is exactly what the
  # refuse-rather-than-guess tests need.
  def build(:measurement_change, attrs) do
    attrs = Enum.into(attrs, %{})
    files = Map.get(attrs, :files, ["lib/app/accounts/user.ex"])

    defaults = %{
      sha: String.duplicate("a", 40),
      parent_sha: String.duplicate("b", 40),
      pr_number: 42,
      subject: "A synthetic change (#42)",
      committed_at: ~U[2026-09-01 12:00:00Z],
      diff: name_status_z(files),
      diffstat: %{files: length(files), changed_lines: 10},
      content: "",
      head_files: @measurement_repo_files,
      base_files: @measurement_repo_files
    }

    struct!(
      Loopctl.DeliveryGates.Measurement.Change,
      Map.merge(defaults, Map.delete(attrs, :files))
    )
  end

  # One past ticket, as `gh issue list --json` emits it (string keys), for the Gate A
  # measurement harness (#828).
  def build(:measurement_ticket, attrs) do
    attrs = Enum.into(attrs, %{})
    labels = Map.get(attrs, :labels, [])

    Map.merge(
      %{
        "number" => 1234,
        "title" => "[Bug] Acme Homecare: the monthly total is wrong",
        "body" => "The total on the billing page does not match the invoice.",
        "labels" => Enum.map(labels, &%{"name" => &1}),
        "state" => "CLOSED",
        "stateReason" => "COMPLETED",
        "createdAt" => "2026-09-01T12:00:00Z"
      },
      Map.drop(attrs, [:labels])
    )
  end

  # One triage agent's output, as the trio contract emits it: an uncontested story.
  def build(:trio_output, attrs) do
    Map.merge(
      %{
        "verdict" => "story",
        "story" => %{"title" => "Fix the monthly total rounding"},
        "escalation_reasons" => [],
        "contradicts" => [],
        "confidence" => 0.8
      },
      Enum.into(attrs, %{})
    )
  end

  # A GitHub `issues` webhook payload (issue #803), as GitHub sends it, trimmed to the keys
  # intake reads plus the repository and sender objects. Pass `:repo`, `:action`, `:number`,
  # `:title`, `:body`, `:labels`, `:login`, `:updated_at` to override.
  def build(:github_issues_payload, attrs) do
    attrs = Enum.into(attrs, %{})
    repo = Map.get(attrs, :repo, "mkreyman/home_care_billing")
    number = Map.get(attrs, :number, 42)
    login = Map.get(attrs, :login, "hcb-support-bot")

    %{
      "action" => Map.get(attrs, :action, "opened"),
      "issue" => %{
        "id" => 3_000_000_000 + number,
        "number" => number,
        "html_url" => "https://github.com/#{repo}/issues/#{number}",
        "state" => Map.get(attrs, :state, "open"),
        "title" => Map.get(attrs, :title, "[Bug] AVA Home Care: Monthly total is wrong"),
        "body" => Map.get(attrs, :body, build(:intake_benign_ticket_body)),
        "labels" => Enum.map(Map.get(attrs, :labels, ["bug"]), &%{"name" => &1}),
        "user" => %{"login" => login, "type" => "Bot"},
        "updated_at" => Map.get(attrs, :updated_at, "2026-09-12T10:00:00Z")
      },
      "repository" => %{"id" => 7, "full_name" => repo, "private" => true},
      "sender" => %{"login" => login}
    }
  end

  # The recorded hostile inputs of issue #804: `%{"text" => %{signal => [sample]},
  # "user_agent" => %{"user_agent_prose" => [...], "benign" => [...]}}`.
  def build(:intake_hostile_samples, _attrs) do
    "test/support/intake_fixtures/hostile_samples.json" |> File.read!() |> Jason.decode!()
  end

  # Recorded real user agents (#804): `"browsers"`, which must fire nothing and carry at most
  # one instruction word, and `"non_browser_clients"`, which are out of the tripwire's domain
  # and only asserted not to crash (asserted in injection_detector_test.exs).
  def build(:intake_real_user_agents, _attrs) do
    "test/support/intake_fixtures/real_user_agents.json" |> File.read!() |> Jason.decode!()
  end

  # The Google Play supported devices list (#804), as `[retail_branding, marketing_name, device,
  # model]` rows. Derived from Google's published supported_devices.csv (UTF-16), fetched
  # 2026-09-13: converted to UTF-8, duplicate rows dropped, written tab-separated with its header
  # and gzipped. No field carries a tab or a newline. Read at test time, not compile time.
  def build(:intake_play_supported_devices, _attrs) do
    "test/support/intake_fixtures/play_supported_devices.tsv.gz"
    |> File.read!()
    |> :zlib.gunzip()
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(&String.split(&1, "\t"))
  end

  # A benign HomeCareBilling support ticket, in the issue format its worker files.
  def build(:intake_benign_ticket_body, _attrs) do
    File.read!("test/support/intake_fixtures/benign_ticket_body.md")
  end

  @doc """
  Inserts a record into the database, auto-creating any required dependencies.
  Returns the inserted struct.

  For `:api_key`, returns `{raw_key, %ApiKey{}}` since the raw key
  is needed for authentication in tests.
  """
  def fixture(type, attrs \\ %{})

  def fixture(:tenant, attrs) do
    data = build(:tenant, attrs)
    status = Map.get(data, :status, :active)
    audit_pub_key = Map.get(data, :audit_signing_public_key)
    trust_tier = Map.get(data, :trust_tier, :human_anchored)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(data)
      |> AdminRepo.insert!()

    # Apply non-active status after creation (create always defaults to :active)
    tenant =
      if status != :active do
        tenant
        |> Tenant.status_changeset(status)
        |> AdminRepo.update!()
      else
        tenant
      end

    # Set audit_signing_public_key if provided (not in create_changeset cast)
    tenant =
      if audit_pub_key do
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: audit_pub_key)
        |> AdminRepo.update!()
      else
        tenant
      end

    # `:settings` needs nothing here — `Tenant.create_changeset/2` casts it, so
    # `fixture(:tenant, %{settings: %{...}})` already persists. (`signup_changeset/2` and
    # `self_signup_changeset/2` are the ones that PUT an empty map; they are a different
    # surface and not what this fixture calls.)
    tenant
    |> Ecto.Changeset.change(trust_tier: trust_tier)
    |> AdminRepo.update!()
  end

  def fixture(:root_authenticator, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.delete(attrs, :tenant_id)}

        tid ->
          {tid, Map.delete(attrs, :tenant_id)}
      end

    %RootAuthenticator{tenant_id: tenant_id}
    |> RootAuthenticator.create_changeset(build(:root_authenticator, attrs))
    |> AdminRepo.insert!()
  end

  def fixture(:agent, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:agent, attrs)

    changeset =
      %Agent{tenant_id: tenant_id}
      |> Agent.register_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:article, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    project_id = Map.get(attrs, :project_id)
    data = build(:article, attrs)

    changeset =
      %Article{tenant_id: tenant_id, project_id: project_id}
      |> Article.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:entity, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:entity, attrs)

    changeset =
      %Entity{tenant_id: tenant_id}
      |> Entity.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:memory, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    subject_id = Map.get(attrs, :subject_id) || "subject-#{System.unique_integer([:positive])}"
    # project_id is set programmatically (not cast) — the write path derives it
    # from authorized caller context, so the fixture mirrors that.
    project_id = Map.get(attrs, :project_id)
    data = build(:memory, attrs)

    changeset =
      %Memory{tenant_id: tenant_id, subject_id: subject_id, project_id: project_id}
      |> Memory.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:session_memory, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    subject_id = Map.get(attrs, :subject_id) || "subject-#{System.unique_integer([:positive])}"
    # project_id is set programmatically (not cast) — the write path derives it
    # from authorized caller context, so the fixture mirrors that.
    project_id = Map.get(attrs, :project_id)
    data = build(:session_memory, attrs)

    changeset =
      %SessionMemory{tenant_id: tenant_id, subject_id: subject_id, project_id: project_id}
      |> SessionMemory.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  # A `Loopctl.Memory.Scope` for the US-28.2 context API. Creates a tenant when one
  # isn't supplied and derives a unique `subject_id` — mirroring how the write path
  # sets `(tenant_id, subject_id, project_id)` programmatically. This is a plain
  # struct (no DB row), so it is `build`-like but lives under `fixture/2` per the
  # story's naming.
  def fixture(:memory_scope, attrs) do
    attrs = Enum.into(attrs, %{})

    tenant_id = Map.get(attrs, :tenant_id) || fixture(:tenant).id
    subject_id = Map.get(attrs, :subject_id) || "subject-#{System.unique_integer([:positive])}"
    project_id = Map.get(attrs, :project_id)

    %Loopctl.Memory.Scope{
      tenant_id: tenant_id,
      subject_id: subject_id,
      project_id: project_id
    }
  end

  # The COMMITTED labeled promotion-eval dataset (US-29.5). Returns the stable, versioned
  # ground-truth dataset (`priv/promotion_eval/dataset_v1.json`) — >= 3 labeled sessions
  # with known expected durable-fact counts plus an injection case whose expected label is
  # "nothing durable". Not a DB row; it is the committed data the eval scores against.
  def fixture(:promotion_eval_dataset, _attrs) do
    PromotionEvalDataset.default()
  end

  # The COMMITTED retrieval-eval golden set (#469). `build(:retrieval_golden_set, ...)`
  # builds a small in-memory one instead, for tests that must not seed 100 articles.
  def fixture(:retrieval_golden_set, _attrs) do
    RetrievalGoldenSet.default()
  end

  # A US-29.2 promotion WATERMARK row. Auto-creates a tenant when one isn't supplied;
  # `promoted_at` defaults to now (so it counts against the compiles/hour budget).
  def fixture(:session_promotion, attrs) do
    attrs = Enum.into(attrs, %{})

    tenant_id = Map.get(attrs, :tenant_id) || fixture(:tenant).id
    subject_id = Map.get(attrs, :subject_id) || "subject-#{System.unique_integer([:positive])}"
    seq = System.unique_integer([:positive])

    data = %{
      session_id: Map.get(attrs, :session_id) || "session-#{seq}",
      session_content_hash: Map.get(attrs, :session_content_hash) || "hash-#{seq}",
      last_turn_inserted_at: Map.get(attrs, :last_turn_inserted_at),
      promoted_at: Map.get(attrs, :promoted_at) || DateTime.utc_now()
    }

    %SessionPromotion{tenant_id: tenant_id, subject_id: subject_id}
    |> SessionPromotion.upsert_changeset(data)
    |> AdminRepo.insert!()
  end

  def fixture(:article_link, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # Auto-create source article if not provided
    {source_article_id, attrs} =
      case Map.get(attrs, :source_article_id) do
        nil ->
          article = fixture(:article, %{tenant_id: tenant_id})
          {article.id, Map.put(attrs, :source_article_id, article.id)}

        id ->
          {id, attrs}
      end

    # Auto-create target article if not provided
    {target_article_id, attrs} =
      case Map.get(attrs, :target_article_id) do
        nil ->
          article = fixture(:article, %{tenant_id: tenant_id})
          {article.id, Map.put(attrs, :target_article_id, article.id)}

        id ->
          {id, attrs}
      end

    data = build(:article_link, attrs)

    changeset =
      %ArticleLink{tenant_id: tenant_id}
      |> ArticleLink.changeset(%{
        source_article_id: source_article_id,
        target_article_id: target_article_id,
        relationship_type: data.relationship_type,
        metadata: data.metadata
      })

    AdminRepo.insert!(changeset)
  end

  def fixture(:article_access_event, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # Auto-create the article if not provided
    {article_id, attrs} =
      case Map.get(attrs, :article_id) do
        nil ->
          article = fixture(:article, %{tenant_id: tenant_id})
          {article.id, Map.put(attrs, :article_id, article.id)}

        id ->
          {id, attrs}
      end

    # Auto-create the api_key if not provided
    {api_key_id, attrs} =
      case Map.get(attrs, :api_key_id) do
        nil ->
          {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent})
          {api_key.id, Map.put(attrs, :api_key_id, api_key.id)}

        id ->
          {id, attrs}
      end

    project_id = Map.get(attrs, :project_id)
    story_id = Map.get(attrs, :story_id)
    data = build(:article_access_event, attrs)

    changeset =
      %ArticleAccessEvent{tenant_id: tenant_id}
      |> ArticleAccessEvent.create_changeset(%{
        article_id: article_id,
        api_key_id: api_key_id,
        project_id: project_id,
        story_id: story_id,
        access_type: data.access_type,
        metadata: data.metadata,
        accessed_at: data.accessed_at
      })

    # Origin is writer-resolved and therefore NOT castable (see
    # `ArticleAccessEvent.create_changeset/2`). A metrics test still needs rows in a known
    # attribution class without replaying a whole search, so seed them past the changeset
    # here — deliberately the only place that does, so production code has no such path.
    changeset
    |> Ecto.Changeset.change(Map.take(attrs, [:origin_search_id, :origin_attribution]))
    |> AdminRepo.insert!()
  end

  def fixture(:search_event, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {api_key_id, attrs} =
      case Map.fetch(attrs, :api_key_id) do
        # `:api_key_id` is a DECLARED-required column of every coverage profile, so a
        # fixture that always auto-created one could never seed the miss. An explicit nil
        # is honoured; only an ABSENT key auto-creates.
        {:ok, id} ->
          {id, attrs}

        :error ->
          {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent})
          {api_key.id, Map.put(attrs, :api_key_id, api_key.id)}
      end

    data = build(:search_event, Map.delete(attrs, :tenant_id))

    changeset =
      %SearchEvent{tenant_id: tenant_id}
      |> SearchEvent.changeset(Map.put(data, :api_key_id, api_key_id))

    # `inserted_at` is set by `timestamps/1` and is therefore not castable, but a coverage
    # report is a WINDOW over it — a test that cannot place a row in time cannot test the
    # window at all. Seeded past the changeset here, deliberately the only place that does.
    changeset
    |> Ecto.Changeset.change(Map.take(attrs, [:inserted_at]))
    |> AdminRepo.insert!()
  end

  def fixture(:project, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # `kind` is set on the struct, never cast (mirrors Projects.create_project/3) —
    # so a `kind: :kb` attr produces a real KB scope for coordination/tier tests.
    {kind, data} = Map.pop(build(:project, attrs), :kind, :work)

    changeset =
      %Project{tenant_id: tenant_id, kind: kind}
      |> Project.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:epic, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # Auto-create project if not provided
    {project_id, attrs} =
      case Map.get(attrs, :project_id) do
        nil ->
          project = fixture(:project, %{tenant_id: tenant_id})
          {project.id, Map.put(attrs, :project_id, project.id)}

        pid ->
          {pid, attrs}
      end

    data = build(:epic, attrs)

    changeset =
      %Epic{tenant_id: tenant_id, project_id: project_id}
      |> Epic.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:story, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # Auto-create epic if not provided
    {epic, attrs} =
      case Map.get(attrs, :epic_id) do
        nil ->
          project_id = Map.get(attrs, :project_id)

          epic =
            if project_id do
              fixture(:epic, %{tenant_id: tenant_id, project_id: project_id})
            else
              fixture(:epic, %{tenant_id: tenant_id})
            end

          attrs = Map.put(attrs, :epic_id, epic.id)
          attrs = Map.put(attrs, :project_id, epic.project_id)
          {epic, attrs}

        eid ->
          epic = AdminRepo.get!(Epic, eid)
          attrs = Map.put(attrs, :project_id, epic.project_id)
          {epic, attrs}
      end

    project_id = Map.get(attrs, :project_id, epic.project_id)

    # Handle optional status overrides
    agent_status = Map.get(attrs, :agent_status, :pending)
    verified_status = Map.get(attrs, :verified_status, :unverified)
    assigned_agent_id = Map.get(attrs, :assigned_agent_id)

    data = build(:story, attrs)

    changeset =
      %Story{tenant_id: tenant_id, project_id: project_id, epic_id: epic.id}
      |> Story.create_changeset(data)

    story = AdminRepo.insert!(changeset)

    apply_story_overrides(story, agent_status, verified_status, assigned_agent_id)
  end

  # US-40.B1: a coordination handoff claim, inserted DIRECTLY on AdminRepo
  # (bypassing the membership gate) so lifecycle/sweeper/isolation tests can seed
  # claims with arbitrary `done_at`/`lease_expires_at`. Auto-creates tenant/project/
  # agent when not supplied. Override any of `:ref`, `:claimant_agent_id`,
  # `:claimed_at`, `:lease_expires_at`, `:done_at`.
  def fixture(:channel_claim, attrs) do
    attrs = Enum.into(attrs, %{})

    tenant_id = Map.get(attrs, :tenant_id) || fixture(:tenant).id
    project_id = Map.get(attrs, :project_id) || fixture(:project, %{tenant_id: tenant_id}).id

    claimant_agent_id =
      Map.get(attrs, :claimant_agent_id) || fixture(:agent, %{tenant_id: tenant_id}).id

    now = DateTime.utc_now()
    claimed_at = Map.get(attrs, :claimed_at, now)
    lease_expires_at = Map.get(attrs, :lease_expires_at, DateTime.add(now, 3600, :second))

    AdminRepo.insert!(%ChannelClaim{
      tenant_id: tenant_id,
      project_id: project_id,
      claimant_agent_id: claimant_agent_id,
      ref: Map.get(attrs, :ref, "handoff:repo##{System.unique_integer([:positive])}"),
      claimed_at: claimed_at,
      lease_expires_at: lease_expires_at,
      done_at: Map.get(attrs, :done_at)
    })
  end

  def fixture(:epic_dependency, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)
    epic_id = Map.fetch!(attrs, :epic_id)
    depends_on_epic_id = Map.fetch!(attrs, :depends_on_epic_id)

    changeset =
      %EpicDependency{
        tenant_id: tenant_id,
        epic_id: epic_id,
        depends_on_epic_id: depends_on_epic_id
      }
      |> EpicDependency.create_changeset()

    AdminRepo.insert!(changeset)
  end

  def fixture(:story_dependency, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)
    story_id = Map.fetch!(attrs, :story_id)
    depends_on_story_id = Map.fetch!(attrs, :depends_on_story_id)

    changeset =
      %StoryDependency{
        tenant_id: tenant_id,
        story_id: story_id,
        depends_on_story_id: depends_on_story_id
      }
      |> StoryDependency.create_changeset()

    AdminRepo.insert!(changeset)
  end

  def fixture(:artifact_report, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {story_id, attrs} =
      case Map.get(attrs, :story_id) do
        nil ->
          story = fixture(:story, %{tenant_id: tenant_id})
          {story.id, Map.put(attrs, :story_id, story.id)}

        sid ->
          {sid, attrs}
      end

    agent_id = Map.get(attrs, :reporter_agent_id)
    reported_by = Map.get(attrs, :reported_by, :agent)

    data = build(:artifact_report, attrs)

    changeset =
      %ArtifactReport{
        tenant_id: tenant_id,
        story_id: story_id,
        reported_by: reported_by,
        reporter_agent_id: agent_id
      }
      |> ArtifactReport.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:verification_result, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {story_id, attrs} =
      case Map.get(attrs, :story_id) do
        nil ->
          story = fixture(:story, %{tenant_id: tenant_id})
          {story.id, Map.put(attrs, :story_id, story.id)}

        sid ->
          {sid, attrs}
      end

    orchestrator_agent_id = Map.get(attrs, :orchestrator_agent_id)

    data = build(:verification_result, attrs)

    changeset =
      %VerificationResult{
        tenant_id: tenant_id,
        story_id: story_id,
        orchestrator_agent_id: orchestrator_agent_id
      }
      |> VerificationResult.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:token_usage_report, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {story, attrs} =
      case Map.get(attrs, :story_id) do
        nil ->
          story = fixture(:story, %{tenant_id: tenant_id})
          attrs = Map.put(attrs, :story_id, story.id)
          attrs = Map.put_new(attrs, :project_id, story.project_id)
          {story, attrs}

        sid ->
          story = AdminRepo.get!(Story, sid)
          attrs = Map.put_new(attrs, :project_id, story.project_id)
          {story, attrs}
      end

    {agent_id, attrs} =
      case Map.get(attrs, :agent_id) do
        nil ->
          agent = fixture(:agent, %{tenant_id: tenant_id})
          {agent.id, Map.put(attrs, :agent_id, agent.id)}

        aid ->
          {aid, attrs}
      end

    project_id = Map.get(attrs, :project_id, story.project_id)

    data = build(:token_usage_report, attrs)

    changeset =
      %TokenUsageReport{
        tenant_id: tenant_id,
        story_id: story.id,
        agent_id: agent_id,
        project_id: project_id
      }
      |> TokenUsageReport.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:token_budget, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # Auto-create the scope entity if scope_id is not provided
    scope_type = Map.get(attrs, :scope_type, :story)

    {scope_id, attrs} =
      case Map.get(attrs, :scope_id) do
        nil ->
          case scope_type do
            :project ->
              project = fixture(:project, %{tenant_id: tenant_id})
              {project.id, Map.put(attrs, :scope_id, project.id)}

            :epic ->
              epic = fixture(:epic, %{tenant_id: tenant_id})
              {epic.id, Map.put(attrs, :scope_id, epic.id)}

            :story ->
              story = fixture(:story, %{tenant_id: tenant_id})
              {story.id, Map.put(attrs, :scope_id, story.id)}

            _ ->
              {Ecto.UUID.generate(), attrs}
          end

        sid ->
          {sid, attrs}
      end

    data = build(:token_budget, attrs)

    changeset =
      %TokenBudget{tenant_id: tenant_id}
      |> TokenBudget.create_changeset(Map.put(data, :scope_id, scope_id))

    AdminRepo.insert!(changeset)
  end

  def fixture(:cost_summary, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} = ensure_tenant(attrs)
    scope_type = Map.get(attrs, :scope_type, :project)
    {scope_id, attrs} = ensure_scope_entity(attrs, scope_type, tenant_id)

    data = build(:cost_summary, attrs)

    changeset =
      %CostSummary{tenant_id: tenant_id}
      |> CostSummary.changeset(Map.put(data, :scope_id, scope_id))

    AdminRepo.insert!(changeset)
  end

  def fixture(:cost_anomaly, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {story_id, attrs} =
      case Map.get(attrs, :story_id) do
        nil ->
          story = fixture(:story, %{tenant_id: tenant_id})
          {story.id, Map.put(attrs, :story_id, story.id)}

        sid ->
          {sid, attrs}
      end

    data = build(:cost_anomaly, attrs)

    changeset =
      %CostAnomaly{tenant_id: tenant_id, story_id: story_id}
      |> CostAnomaly.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:ingestion_anomaly, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:ingestion_anomaly, attrs)

    # `archived` is not cast by create_changeset (mirrors CostAnomaly — it's set by
    # the archival path, not the create surface), so put it on the changeset directly
    # when a test needs an archived row.
    changeset =
      %IngestionAnomaly{tenant_id: tenant_id}
      |> IngestionAnomaly.create_changeset(data)
      |> Ecto.Changeset.put_change(:archived, Map.get(data, :archived, false))

    AdminRepo.insert!(changeset)
  end

  def fixture(:ingestion_write_stats, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:ingestion_write_stats, Map.delete(attrs, :tenant_id))

    %IngestionWriteStats{tenant_id: tenant_id}
    |> IngestionWriteStats.changeset(data)
    |> AdminRepo.insert!()
  end

  def fixture(:review_record, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {story_id, attrs} =
      case Map.get(attrs, :story_id) do
        nil ->
          story =
            fixture(:story, %{
              tenant_id: tenant_id,
              agent_status: :reported_done,
              reported_done_at: DateTime.utc_now()
            })

          {story.id, Map.put(attrs, :story_id, story.id)}

        sid ->
          {sid, attrs}
      end

    reviewer_agent_id = Map.get(attrs, :reviewer_agent_id)

    data = build(:review_record, attrs)

    changeset =
      %ReviewRecord{
        tenant_id: tenant_id,
        story_id: story_id,
        reviewer_agent_id: reviewer_agent_id
      }
      |> ReviewRecord.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  # --- Per-tenant BYO LLM config + usage (Epic 28 residual, #179) ---

  # Inserts a tenant_llm_settings row (auto-creating a tenant if needed). The
  # `api_key` defaults to a plausible test key so `Loopctl.Llm.has_api_key?/1`
  # returns true and the mandatory-BYO gate passes.
  def fixture(:system_config, attrs) do
    data = build(:system_config, attrs)

    %Setting{}
    |> Setting.changeset(data)
    |> AdminRepo.insert!()
  end

  def fixture(:tenant_llm_settings, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, attrs}

        tid ->
          {tid, attrs}
      end

    data = build(:tenant_llm_settings, Map.delete(attrs, :tenant_id))
    api_key = Map.get(data, :api_key)
    # US-41.3: the OpenAI-compatible chat credential is a SEPARATE encrypted column
    # and, like `api_key`, is never cast.
    chat_api_key = Map.get(data, :chat_api_key)

    settings =
      %TenantLlmSettings{tenant_id: tenant_id}
      |> TenantLlmSettings.models_changeset(data)
      |> TenantLlmSettings.put_api_key(api_key)
      |> TenantLlmSettings.put_chat_api_key(chat_api_key)
      |> TenantLlmSettings.put_embedding_api_key(Map.get(data, :embedding_api_key))
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
      |> AdminRepo.insert!()

    # This fixture inserts DIRECTLY (not via `Llm.upsert_settings/2`), so it bypasses
    # the cache-busting write path. `Llm.get_settings/1` negative-caches `nil`, so a
    # test that read this tenant's settings BEFORE inserting here would otherwise keep
    # serving the stale cached `nil`. Bust the node-local entry so the next read
    # reflects the freshly-inserted row.
    SettingsCache.invalidate(tenant_id)

    settings
  end

  # Inserts an llm_usage_events row (auto-creating a tenant if needed).
  def fixture(:llm_usage_event, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, attrs}

        tid ->
          {tid, attrs}
      end

    data = build(:llm_usage_event, Map.delete(attrs, :tenant_id))

    %LlmUsageEvent{tenant_id: tenant_id}
    |> LlmUsageEvent.create_changeset(data)
    |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
    |> AdminRepo.insert!()
  end

  def fixture(:webhook, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:webhook, attrs)
    raw_secret = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    changeset =
      %Webhook{
        tenant_id: tenant_id,
        signing_secret_encrypted: raw_secret
      }
      |> Webhook.create_changeset(data)

    webhook = AdminRepo.insert!(changeset)

    # Apply overrides for active and consecutive_failures
    active = Map.get(attrs, :active, true)
    consecutive_failures = Map.get(attrs, :consecutive_failures, 0)

    if active != true or consecutive_failures != 0 do
      webhook
      |> Ecto.Changeset.change(%{active: active, consecutive_failures: consecutive_failures})
      |> AdminRepo.update!()
    else
      webhook
    end
  end

  def fixture(:webhook_event, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {webhook_id, attrs} =
      case Map.get(attrs, :webhook_id) do
        nil ->
          webhook = fixture(:webhook, %{tenant_id: tenant_id})
          {webhook.id, Map.put(attrs, :webhook_id, webhook.id)}

        wid ->
          {wid, attrs}
      end

    data = build(:webhook_event, attrs)
    status = Map.get(data, :status, :pending)
    attempts = Map.get(data, :attempts, 0)

    changeset =
      %WebhookEvent{
        tenant_id: tenant_id,
        webhook_id: webhook_id
      }
      |> WebhookEvent.create_changeset(data)

    event = AdminRepo.insert!(changeset)

    # Apply status/attempts overrides
    if status != :pending or attempts != 0 do
      event
      |> Ecto.Changeset.change(%{status: status, attempts: attempts})
      |> AdminRepo.update!()
    else
      event
    end
  end

  # An enrolled runner (issue #801). Returns `{raw_token, runner}` so a test can connect
  # the runner socket with the token. Auto-creates the tenant when none is given.
  def fixture(:runner, attrs) do
    attrs = Enum.into(attrs, %{})

    tenant_id =
      case Map.get(attrs, :tenant_id) do
        nil -> fixture(:tenant).id
        tid -> tid
      end

    name = Map.get(attrs, :name, "runner-#{System.unique_integer([:positive])}")

    {:ok, %{runner: runner, raw_key: raw_key}} =
      Loopctl.Runners.enroll_runner(
        tenant_id,
        Map.merge(%{name: name}, Map.take(attrs, [:max_sessions]))
      )

    {raw_key, runner}
  end

  # A tenant, runner key and runner row COMMITTED outside the sandbox, for tests of the
  # runner dispatch ledger (#803). The ledger lives on the RLS `Loopctl.Repo`, while the
  # runner socket authenticates through `Loopctl.AdminRepo`; the two are separate sandbox
  # connections, so both the runner row and its tenant must be visible to both. Only a
  # `async: false` module may use these (a committed row is visible to every running
  # test), and it must call `sweep_committed_runner_tenants/0` in `setup_all` and on exit.
  # No audit-chain entry is written: those rows cannot be deleted, so the sweep could not
  # remove the tenant.
  def fixture(:committed_runner, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.get_lazy(attrs, :tenant_id, fn -> fixture(:committed_tenant, %{}).id end)
    name = Map.get(attrs, :name, "runner-#{System.unique_integer([:positive])}")

    Sandbox.unboxed_run(AdminRepo, fn ->
      {:ok, {raw_key, api_key}} =
        Auth.generate_api_key(%{tenant_id: tenant_id, name: "runner:" <> name, role: :agent})

      # The agent a runner's sessions work as (#803). `enroll_runner/3` gets or creates it;
      # this fixture inserts the runner row directly, so it has to make the same binding —
      # `runners.agent_id` is NOT NULL.
      agent =
        %Agent{tenant_id: tenant_id}
        |> Agent.register_changeset(%{
          name: Loopctl.Runners.agent_name(name),
          agent_type: :implementer
        })
        |> AdminRepo.insert!()

      runner =
        %Runner{tenant_id: tenant_id}
        |> Runner.create_changeset(Map.merge(%{name: name}, Map.take(attrs, [:max_sessions])))
        |> Ecto.Changeset.put_change(:api_key_id, api_key.id)
        |> Ecto.Changeset.put_change(:agent_id, agent.id)
        |> AdminRepo.insert!()

      {raw_key, runner}
    end)
  end

  # An agent and its `:agent`-role key, COMMITTED outside the sandbox, for a CONTROLLER test
  # of a path whose context runs on the RLS `Loopctl.Repo` (#803's escalate endpoint). The
  # auth pipeline resolves the key on `AdminRepo` while `Loopctl.Delivery.Stages` reads the
  # story on `Repo`, and those are separate sandbox connections that cannot see each other's
  # uncommitted rows — so the TENANT and the KEY must be committed (both connections see
  # them) while the story stays inside the `Repo` sandbox (`fixture(:ledger_story)`). Only an
  # `async: false` module may use it, and it must call `sweep_committed_runner_tenants/0` in
  # `setup_all` and on exit; the tenant it makes carries the sweep's slug marker.
  #
  # Returns `{raw_key, api_key, agent}`.
  def fixture(:committed_agent_key, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)

    Sandbox.unboxed_run(AdminRepo, fn ->
      agent =
        %Agent{tenant_id: tenant_id}
        |> Agent.register_changeset(build(:agent, Map.take(attrs, [:name, :agent_type])))
        |> AdminRepo.insert!()

      {:ok, {raw_key, api_key}} =
        Auth.generate_api_key(%{
          tenant_id: tenant_id,
          name: "agent:#{agent.id}",
          role: :agent,
          agent_id: agent.id
        })

      {raw_key, api_key, agent}
    end)
  end

  # A committed `:user`-role key, for a CONTROLLER test of an operator-facing read whose data
  # is written on the RLS `Loopctl.Repo` — the runner registry's `unsupported_kinds`, which is
  # derived from `runner_dispatches`. Same two-repo constraint as `:committed_agent_key`
  # above: only an `async: false` module may use it, and it must sweep at the boundary.
  #
  # Returns `{raw_key, api_key}`. A controller test wants the raw token; a CONTEXT test wants
  # the `%ApiKey{}` struct, because `Loopctl.Delivery.Placement.place/4` resolves the caller's
  # lineage and role from the key itself rather than taking them as options. It is also the
  # tenant's OPERATOR principal — `role: :user`, minted by no dispatch, so its lineage resolves
  # to `[]` — which is the one principal allowed to root a lineage tree.
  def fixture(:committed_operator_key, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)

    Sandbox.unboxed_run(AdminRepo, fn ->
      {:ok, {raw_key, api_key}} =
        Auth.generate_api_key(%{
          tenant_id: tenant_id,
          name: "operator-#{System.unique_integer([:positive])}",
          role: :user
        })

      {raw_key, api_key}
    end)
  end

  # A story (with its project and epic) on the RLS `Loopctl.Repo` connection, at a given
  # `claim_epoch`, for the dispatch ledger's claim fence (#803). The ledger reads
  # `stories.claim_epoch` on `Repo` inside its own transaction, and `Repo` and `AdminRepo`
  # hold separate sandbox transactions, so a story made by `fixture(:story)` (AdminRepo) is
  # invisible to it. `tenant_id` must be visible to `Repo` (a committed tenant).
  def fixture(:ledger_story, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)

    {:ok, story} =
      Loopctl.Repo.with_tenant(tenant_id, fn ->
        project =
          %Project{tenant_id: tenant_id, kind: :work}
          |> Project.create_changeset(build(:project, %{}))
          |> Loopctl.Repo.insert!()

        epic =
          %Epic{tenant_id: tenant_id, project_id: project.id}
          |> Epic.create_changeset(build(:epic, %{}))
          |> Loopctl.Repo.insert!()

        %Story{tenant_id: tenant_id, project_id: project.id, epic_id: epic.id}
        |> Story.create_changeset(build(:story, %{}))
        |> Ecto.Changeset.change(claim_epoch: Map.get(attrs, :claim_epoch, 0))
        |> Loopctl.Repo.insert!()
      end)

    story
  end

  # A story (with its project and epic) COMMITTED outside the sandbox, for a path that writes
  # it through BOTH repos (#803's `Loopctl.Delivery.Placement`: the claim runs on `AdminRepo`
  # and the stage transition on the RLS `Loopctl.Repo`, which are separate sandbox connections
  # that cannot see each other's uncommitted rows). `fixture(:ledger_story)` is the sandboxed
  # sibling and is enough whenever only `Repo` reads the story.
  #
  # Same rules as `fixture(:committed_runner)`: only an `async: false` module may use it, and
  # it must call `sweep_committed_runner_tenants/0` in `setup_all` and on exit — the sweep
  # deletes the tenant and the story cascades with it.
  def fixture(:committed_story, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)

    Sandbox.unboxed_run(Loopctl.Repo, fn ->
      {:ok, story} =
        Loopctl.Repo.with_tenant(tenant_id, fn ->
          project =
            %Project{tenant_id: tenant_id, kind: :work}
            |> Project.create_changeset(build(:project, %{}))
            |> Loopctl.Repo.insert!()

          epic =
            %Epic{tenant_id: tenant_id, project_id: project.id}
            |> Epic.create_changeset(build(:epic, %{}))
            |> Loopctl.Repo.insert!()

          %Story{tenant_id: tenant_id, project_id: project.id, epic_id: epic.id}
          |> Story.create_changeset(build(:story, %{}))
          |> Ecto.Changeset.change(claim_epoch: Map.get(attrs, :claim_epoch, 0))
          |> Loopctl.Repo.insert!()
        end)

      story
    end)
  end

  # A story for the delivery stage machine (#803), made ENTIRELY on the RLS `Loopctl.Repo`
  # sandbox connection — its tenant included — so `Loopctl.Delivery.Stages`, which runs on
  # `Repo`, sees it inside an async test's sandbox without committing anything. Pass
  # `:tenant_id` to add a story to a tenant made by an earlier call. Accepts `:claim_epoch`
  # and `:agent_status`.
  def fixture(:stage_story, attrs) do
    attrs = Enum.into(attrs, %{})

    tenant_id =
      Map.get_lazy(attrs, :tenant_id, fn ->
        %Tenant{} |> Tenant.create_changeset(build(:tenant, %{})) |> Loopctl.Repo.insert!()
      end)
      |> case do
        %Tenant{id: id} -> id
        id -> id
      end

    story =
      fixture(:ledger_story, %{tenant_id: tenant_id, claim_epoch: Map.get(attrs, :claim_epoch, 0)})

    case Map.get(attrs, :agent_status) do
      nil ->
        story

      status ->
        {:ok, story} =
          Loopctl.Repo.with_tenant(tenant_id, fn ->
            story |> Ecto.Changeset.change(agent_status: status) |> Loopctl.Repo.update!()
          end)

        story
    end
  end

  # An agent on the RLS `Loopctl.Repo` sandbox connection, for a `stories.assigned_agent_id`
  # a `Repo`-side test needs to satisfy `stories_assigned_agent_id_fkey` (#803's escalation
  # path, whose claimant check runs on `Repo`). The default `fixture(:agent)` writes through
  # `AdminRepo`, whose uncommitted rows a `Repo` FK check cannot see.
  def fixture(:stage_agent, attrs) do
    tenant_id = attrs |> Enum.into(%{}) |> Map.fetch!(:tenant_id)

    {:ok, agent} =
      Loopctl.Repo.with_tenant(tenant_id, fn ->
        %Agent{tenant_id: tenant_id}
        |> Agent.register_changeset(build(:agent, %{}))
        |> Loopctl.Repo.insert!()
      end)

    agent
  end

  # A runner (and its key) on the RLS `Loopctl.Repo` sandbox connection, for a
  # `story_stages.runner_id` written by `Loopctl.Delivery.Stages` in an async test (#803).
  def fixture(:stage_runner, attrs) do
    tenant_id = attrs |> Enum.into(%{}) |> Map.fetch!(:tenant_id)

    {:ok, runner} =
      Loopctl.Repo.with_tenant(tenant_id, fn ->
        api_key =
          %ApiKey{tenant_id: tenant_id}
          |> ApiKey.create_changeset(%{name: "runner:stage", role: :agent})
          |> Ecto.Changeset.put_change(:key_hash, Auth.hash_key(Ecto.UUID.generate()))
          |> Ecto.Changeset.put_change(:key_prefix, "lc_stage")
          |> Loopctl.Repo.insert!()

        name = "runner-#{System.unique_integer([:positive])}"

        # `runners.agent_id` is NOT NULL (#803): a runner names the agent its sessions work
        # as. `enroll_runner/3` gets or creates it; a direct insert has to make the binding.
        agent =
          %Agent{tenant_id: tenant_id}
          |> Agent.register_changeset(%{
            name: Loopctl.Runners.agent_name(name),
            agent_type: :implementer
          })
          |> Loopctl.Repo.insert!()

        %Runner{tenant_id: tenant_id}
        |> Runner.create_changeset(%{name: name})
        |> Ecto.Changeset.put_change(:api_key_id, api_key.id)
        |> Ecto.Changeset.put_change(:agent_id, agent.id)
        |> Loopctl.Repo.insert!()
      end)

    runner
  end

  # A delivery stage row inserted DIRECTLY at any stage (#803), bypassing
  # `Loopctl.Delivery.Stages` so a test can start from `ci` or `implementing` without
  # walking the machine there. `:repo` picks the sandbox connection the story lives on:
  # `Loopctl.Repo` (default, with `fixture(:stage_story)`) or `Loopctl.AdminRepo` (with
  # `fixture(:story)`, for the claim reclaimer, which runs on AdminRepo).
  #
  # `:merged_at` (a DateTime) additionally writes the `transitioned -> merged` stage EVENT
  # the machine would have written on the way. Post-deploy verification reads it to learn
  # when the merge was recorded — a deployment created before that cannot carry it — so a
  # row placed at `deployed` by hand needs the event too, or the verifier correctly fails
  # closed on a story whose history does not say when it merged.
  def fixture(:story_stage, attrs) do
    attrs = Enum.into(attrs, %{})
    repo = Map.get(attrs, :repo, Loopctl.Repo)
    tenant_id = Map.fetch!(attrs, :tenant_id)
    merged_at = Map.get(attrs, :merged_at)

    row =
      struct!(
        StoryStage,
        attrs
        |> Map.drop([:repo, :merged_at])
        |> Map.put_new(:stage, :detected)
        |> Map.put_new(:claim_epoch, 0)
      )

    insert = fn ->
      inserted = repo.insert!(row)
      if merged_at, do: insert_merged_event(repo, inserted, merged_at)
      inserted
    end

    if repo == Loopctl.Repo do
      {:ok, row} = Loopctl.Repo.with_tenant(tenant_id, insert)
      row
    else
      insert.()
    end
  end

  # A RECORDED triage verdict (`triage_verdicts`), as `Loopctl.Delivery.TriageVerdict` writes
  # one after a runner's verdict message, for the readers that judge it (US-44.1). Defaults
  # to a unanimous `story` verdict with all three lens verdicts; pass `lens_verdicts: nil` for
  # a verdict recorded without them (a runner on contract 1.14.0). `:repo` as for
  # `fixture(:story_stage)`.
  def fixture(:triage_verdict, attrs) do
    attrs = Enum.into(attrs, %{})
    repo = Map.get(attrs, :repo, Loopctl.Repo)
    tenant_id = Map.fetch!(attrs, :tenant_id)

    lens = %{
      "outcome" => "story",
      "confidence" => "high",
      "escalation_reasons" => [],
      "contradicts" => []
    }

    # `incomplete_reason:` builds the other shape the table allows: a run that produced no
    # verdict carries no outcome, confidence, payload or lens verdicts.
    result =
      case Map.get(attrs, :incomplete_reason) do
        nil ->
          outcome = Map.get(attrs, :outcome, "story")

          %{
            outcome: outcome,
            confidence: "high",
            payload: %{"outcome" => outcome, "confidence" => "high"},
            lens_verdicts:
              Map.get(attrs, :lens_verdicts, %{
                "analyst" => lens,
                "architect" => lens,
                "engineer" => lens
              })
          }

        reason ->
          %{incomplete_reason: reason}
      end

    record =
      struct!(
        TriageVerdictRecord,
        Map.merge(
          %{
            tenant_id: tenant_id,
            story_id: Map.fetch!(attrs, :story_id),
            dispatch_id: Map.get(attrs, :dispatch_id, Ecto.UUID.generate()),
            payload_digest: Map.get_lazy(attrs, :payload_digest, &Ecto.UUID.generate/0),
            claim_epoch: Map.get(attrs, :claim_epoch, 0),
            inserted_at: Map.get(attrs, :inserted_at)
          },
          result
        )
      )

    # THE BINDING Gate A reads: the story's stage row naming this verdict's dispatch as its
    # `triage_dispatch_id`, as `Loopctl.Delivery.TriageVerdict` records it before storing any
    # verdict — incomplete ones included. Only when the story has a stage row; `bind: false`
    # for a row that decided nothing (a refused second dispatch's, written around the path).
    insert = fn ->
      row = repo.insert!(record)
      if Map.get(attrs, :bind, true), do: bind_triage_dispatch(repo, row)
      row
    end

    if repo == Loopctl.Repo do
      {:ok, row} = Loopctl.Repo.with_tenant(tenant_id, insert)
      row
    else
      insert.()
    end
  end

  # An ACCEPTED dispatch ledger row holding one slot, on the RLS `Loopctl.Repo` connection,
  # for the runner `stage` path (#803). Everything the stage path touches — the story, the
  # stage row, the ledger row and the `runners` row it decrements — lives on `Repo`, so a
  # module using this stays `async: true` and needs no committed rows.
  #
  # It reserves through `Loopctl.Runners.Capacity` rather than writing `in_flight` by hand,
  # so a test asserting a release actually observes the counter the production path moves.
  def fixture(:accepted_dispatch, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)
    runner = Map.fetch!(attrs, :runner)

    {:ok, record} =
      Loopctl.Repo.with_tenant(tenant_id, fn ->
        now = DateTime.utc_now()

        record =
          Loopctl.Repo.insert!(%DispatchRecord{
            tenant_id: tenant_id,
            runner_id: runner.id,
            dispatch_id: Map.get(attrs, :dispatch_id, Ecto.UUID.generate()),
            story_id: Map.fetch!(attrs, :story_id),
            claim_epoch: Map.get(attrs, :claim_epoch, 0),
            kind: Map.get(attrs, :kind, "implement"),
            status: Map.get(attrs, :status, "accepted"),
            trace_acked_seq: -1,
            wall_clock_seconds: 3_600,
            delivery: "pushed",
            pushed_at: now,
            replied_at: now,
            released_at: now,
            slot_generation: 0
          })

        {:ok, reserved} = Capacity.admit_and_reserve(Loopctl.Repo, record, now)
        reserved
      end)

    record
  end

  # `:trust_tier` defaults to the column's own default (`:agent_rooted`, what a signup with no
  # WebAuthn ceremony gets). Pass `trust_tier: :human_anchored` for a test of a surface behind
  # `LoopctlWeb.Plugs.RequireHumanAnchor` — every work-breakdown and chain-of-custody route.
  def fixture(:committed_tenant, attrs) do
    attrs = Enum.into(attrs, %{})
    seq = System.unique_integer([:positive])

    Sandbox.unboxed_run(AdminRepo, fn ->
      tenant =
        %Tenant{}
        |> Tenant.create_changeset(%{
          name: "Committed runner tenant #{seq}",
          slug: "#{@committed_runner_marker}#{seq}",
          email: "#{@committed_runner_marker}#{seq}@example.com"
        })
        |> AdminRepo.insert!()

      case Map.get(attrs, :trust_tier) do
        nil ->
          tenant

        tier ->
          tenant |> Ecto.Changeset.change(trust_tier: tier) |> AdminRepo.update!()
      end
    end)
  end

  # One stored trace event of a run, on the RLS `Loopctl.Repo` connection, inserted DIRECTLY
  # so a test can place it at an arbitrary AGE (#803 retention). The production writer
  # (`DispatchLedger.record_trace/3`) always stamps `inserted_at` as now, and age is exactly
  # what `Loopctl.Workers.DeliveryLoopPruneWorker` selects on. Pass the `:dispatch` record it
  # belongs to; `:seq` and `:inserted_at` default to a fresh sequence and now.
  def fixture(:trace_event, attrs) do
    attrs = Enum.into(attrs, %{})
    dispatch = Map.fetch!(attrs, :dispatch)
    at = Map.get(attrs, :inserted_at, DateTime.utc_now())
    seq = Map.get(attrs, :seq, System.unique_integer([:positive]))

    {:ok, event} =
      Loopctl.Repo.with_tenant(dispatch.tenant_id, fn ->
        Loopctl.Repo.insert!(%TraceEvent{
          tenant_id: dispatch.tenant_id,
          runner_dispatch_id: dispatch.id,
          run_id: dispatch.run_id || dispatch.dispatch_id,
          seq: seq,
          event_id: "evt-#{seq}",
          ts: at,
          type: "tool_use",
          data: %{},
          inserted_at: at
        })
      end)

    event
  end

  # One accepted GitHub webhook delivery row (#803), inserted DIRECTLY so a test can place it
  # at an arbitrary AGE — the same reason as `:trace_event` above. On `AdminRepo`, which is
  # where `Loopctl.Intake` reads and writes. Pass the `:source`; `:github_delivery_id` defaults
  # to a fresh one, so two calls are two distinct deliveries rather than a replay.
  def fixture(:intake_delivery, attrs) do
    attrs = Enum.into(attrs, %{})
    source = Map.fetch!(attrs, :source)
    at = Map.get(attrs, :inserted_at, DateTime.utc_now())
    delivery_id = Map.get(attrs, :github_delivery_id, "dl-#{System.unique_integer([:positive])}")

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: source.tenant_id,
      source_id: source.id,
      github_delivery_id: delivery_id,
      event: Map.get(attrs, :event, "issues"),
      action: Map.get(attrs, :action, "opened"),
      outcome: Map.get(attrs, :outcome, "recorded"),
      issue_number: Map.get(attrs, :issue_number, 1),
      payload_sha256: :sha256 |> :crypto.hash(delivery_id) |> Base.encode16(case: :lower),
      inserted_at: at,
      updated_at: at
    }

    {1, [delivery]} = AdminRepo.insert_all(IntakeDelivery, [row], returning: true)
    delivery
  end

  # `count` delivery rows of one source in ONE insert, all at the same age. For the retention
  # tests that have to cross a production BUDGET (2,000): one at a time is 2,000 round trips,
  # and the budget is exactly what those tests are about.
  def fixture(:intake_deliveries, attrs) do
    attrs = Enum.into(attrs, %{})
    source = Map.fetch!(attrs, :source)
    count = Map.fetch!(attrs, :count)
    at = Map.get(attrs, :inserted_at, DateTime.utc_now())
    prefix = Map.get(attrs, :prefix, "bulk")

    rows =
      for n <- 1..count do
        delivery_id = "#{prefix}-#{n}-#{System.unique_integer([:positive])}"

        %{
          id: Ecto.UUID.generate(),
          tenant_id: source.tenant_id,
          source_id: source.id,
          github_delivery_id: delivery_id,
          event: "issues",
          action: "opened",
          outcome: "recorded",
          issue_number: n,
          payload_sha256: :sha256 |> :crypto.hash(delivery_id) |> Base.encode16(case: :lower),
          inserted_at: at,
          updated_at: at
        }
      end

    {^count, _} = AdminRepo.insert_all(IntakeDelivery, rows)
    count
  end

  # A GitHub intake source (issue #803). Returns `{webhook_secret, source}` so a test can
  # sign deliveries. Auto-creates the tenant and an active work project when not given.
  #
  # `:target_epic_id` is passed through as given, nil included, because nil is the ENROLLED
  # ANSWER "not answered" rather than an absent option — a source with one is what makes
  # `epics.target_epic_id`'s ON DELETE RESTRICT reachable from a test.
  def fixture(:intake_source, attrs) do
    attrs = Enum.into(attrs, %{})

    tenant_id =
      case Map.get(attrs, :tenant_id) do
        nil -> fixture(:tenant).id
        tid -> tid
      end

    project_id =
      case Map.get(attrs, :project_id) do
        nil -> fixture(:project, %{tenant_id: tenant_id}).id
        pid -> pid
      end

    {:ok, %{source: source, webhook_secret: secret}} =
      Loopctl.Intake.create_source(tenant_id, %{
        repo_full_name: Map.get(attrs, :repo_full_name, "mkreyman/home_care_billing"),
        project_id: project_id,
        target_epic_id: Map.get(attrs, :target_epic_id)
      })

    {secret, source}
  end

  # An intake SOURCE + RECORD pair inserted DIRECTLY (#805), bypassing
  # `Loopctl.Intake.receive_github_delivery/2` so a test does not have to sign a webhook
  # delivery to get a record to link a story to. Returns the record.
  #
  # `:repo` picks the sandbox connection, exactly as `fixture(:story_stage)` does and for the
  # same reason: `Loopctl.Repo` (default) when the story under test lives there — which is
  # where `Loopctl.Delivery.Stages` writes the closure row from — or `Loopctl.AdminRepo` when
  # the test drives `Loopctl.Intake.IssueClosures` directly. `Loopctl.Intake.create_source/3`
  # is AdminRepo-only, so it cannot serve the first case.
  def fixture(:intake_record, attrs) do
    attrs = Enum.into(attrs, %{})
    repo = Map.get(attrs, :repo, Loopctl.Repo)
    tenant_id = Map.fetch!(attrs, :tenant_id)
    now = DateTime.utc_now()

    insert = fn ->
      project_id =
        Map.get_lazy(attrs, :project_id, fn ->
          unique = System.unique_integer([:positive])

          repo.insert!(%Project{
            tenant_id: tenant_id,
            name: "intake-#{unique}",
            slug: "intake-#{unique}",
            kind: :work,
            status: :active
          }).id
        end)

      repo_full_name = Map.get(attrs, :repo_full_name, "mkreyman/home_care_billing")

      # REUSED when the tenant already has one for this repository, because that is what
      # production has — one source, many issues — and because a second row would violate
      # `intake_sources_active_repo_uidx` and fail the test for a reason nothing under test
      # is about.
      source =
        repo.one(
          from s in IntakeSource,
            where: s.tenant_id == ^tenant_id and s.repo_full_name == ^repo_full_name
        ) ||
          repo.insert!(%IntakeSource{
            tenant_id: tenant_id,
            project_id: project_id,
            repo_full_name: repo_full_name,
            webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
            inserted_at: now,
            updated_at: now
          })

      repo.insert!(%IntakeRecord{
        tenant_id: tenant_id,
        source_id: source.id,
        project_id: project_id,
        issue_number: Map.get(attrs, :issue_number, System.unique_integer([:positive])),
        untrusted_title: Map.get(attrs, :untrusted_title, "a reported problem"),
        inserted_at: now,
        updated_at: now
      })
    end

    if repo == Loopctl.Repo do
      {:ok, record} = Loopctl.Repo.with_tenant(tenant_id, insert)
      record
    else
      insert.()
    end
  end

  # An intake SOURCE and RECORD, with the project and epic they need, COMMITTED outside the
  # sandbox (#803's `Loopctl.Delivery.TriageTrigger`). Promotion straddles both repos — the
  # story is created in an `AdminRepo` transaction and `Loopctl.Delivery.Stages.open/3` then
  # reads that story on the RLS `Loopctl.Repo` — and those are separate sandbox connections
  # which cannot see each other's uncommitted rows, the same constraint
  # `fixture(:committed_story)` carries.
  #
  # Same rules as `fixture(:committed_runner)`: only an `async: false` module may use it, and
  # it must call `sweep_committed_runner_tenants/0` in `setup_all` and on exit.
  #
  # Pass `target_epic_id: nil` for the source that names no epic, which is the ESCALATION
  # case rather than a degenerate one; omitting the key commits an epic and points the source
  # at it. `:project_id` puts a second source in an existing project, which is what makes two
  # repositories able to report the same issue number into one `stories.number` space.
  #
  # Returns `{source, record}`.
  def fixture(:committed_intake, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)
    now = DateTime.utc_now()

    Sandbox.unboxed_run(AdminRepo, fn ->
      project_id =
        Map.get_lazy(attrs, :project_id, fn ->
          unique = System.unique_integer([:positive])

          AdminRepo.insert!(%Project{
            tenant_id: tenant_id,
            name: "intake-#{unique}",
            slug: "intake-#{unique}",
            kind: :work,
            status: :active
          }).id
        end)

      # `Map.fetch/2`, not `Map.get/3`: an EXPLICIT nil is the case under test, so it must be
      # distinguishable from the key being absent.
      target_epic_id =
        case Map.fetch(attrs, :target_epic_id) do
          {:ok, id} ->
            id

          :error ->
            # A BOUNDED epic number, deliberately, and not what `build(:epic)` gives.
            # That builder uses a raw `System.unique_integer/1`, which is small when a file
            # runs alone and six or seven digits in a full suite — and a story number's
            # parts must be under 10_000, so an epic numbered above that makes every story
            # in it unnumberable. `Loopctl.Delivery.TriageTrigger` refuses such an epic
            # rather than emitting an illegal number (`:epic_number_unnumberable`), which is
            # correct and is not what these tests are about; they need an epic a story can
            # actually be numbered under. The refusal has its own test.
            %Epic{tenant_id: tenant_id, project_id: project_id}
            |> Epic.create_changeset(
              build(:epic, %{
                number:
                  Map.get_lazy(attrs, :epic_number, fn ->
                    rem(System.unique_integer([:positive]), 9_000) + 1
                  end)
              })
            )
            |> AdminRepo.insert!()
            |> Map.fetch!(:id)
        end

      source =
        AdminRepo.insert!(%IntakeSource{
          tenant_id: tenant_id,
          project_id: project_id,
          target_epic_id: target_epic_id,
          repo_full_name: Map.get(attrs, :repo_full_name, "mkreyman/home_care_billing"),
          webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
          revoked_at: Map.get(attrs, :revoked_at),
          inserted_at: now,
          updated_at: now
        })

      record =
        AdminRepo.insert!(%IntakeRecord{
          tenant_id: tenant_id,
          source_id: source.id,
          project_id: project_id,
          issue_number: Map.get(attrs, :issue_number, System.unique_integer([:positive])),
          untrusted_title: Map.get(attrs, :untrusted_title, "a reported problem"),
          # Overridable so a test can build a record the triage payload cannot fit: the bound
          # is on the RENDERED object, so the only way to reach it is real reporter text.
          untrusted_body: Map.get(attrs, :untrusted_body, ""),
          inserted_at: now,
          updated_at: now
        })

      {source, record}
    end)
  end

  # A PENDING issue-closure row (#805), inserted directly so a closer/worker test can start
  # from a verdict without walking a story through the stage machine to reach one.
  #
  # Defaults to `Loopctl.AdminRepo`, which is the connection
  # `Loopctl.Intake.IssueClosures.due/1` and every marker write use — the opposite default
  # from `fixture(:intake_record)`, because the closer is driven from there and the outbox is
  # written from `Loopctl.Repo`.
  def fixture(:issue_closure, attrs) do
    attrs = Enum.into(attrs, %{})
    repo = Map.get(attrs, :repo, AdminRepo)
    tenant_id = Map.fetch!(attrs, :tenant_id)
    now = DateTime.utc_now()

    record =
      Map.get_lazy(attrs, :intake_record, fn ->
        fixture(:intake_record, %{tenant_id: tenant_id, repo: repo})
      end)

    story_id = Map.fetch!(attrs, :story_id)

    insert = fn ->
      repo.insert!(
        struct!(
          IssueClosure,
          attrs
          |> Map.drop([:repo, :intake_record])
          |> Map.merge(%{
            tenant_id: tenant_id,
            story_id: story_id,
            intake_record_id: record.id,
            inserted_at: now,
            updated_at: now
          })
          |> Map.put_new(:repo_full_name, "mkreyman/home_care_billing")
          |> Map.put_new(:issue_number, record.issue_number)
          |> Map.put_new(:verdict, :shipped)
          |> Map.put_new(:status, :pending)
          |> Map.put_new(:attempts, 0)
        )
      )
    end

    if repo == Loopctl.Repo do
      {:ok, row} = Loopctl.Repo.with_tenant(tenant_id, insert)
      row
    else
      insert.()
    end
  end

  def fixture(:api_key, attrs) do
    attrs = Enum.into(attrs, %{})
    role = Map.get(attrs, :role, :user)

    # Auto-create a tenant if not provided (unless superadmin)
    {tenant_id, attrs} =
      case {Map.get(attrs, :tenant_id), role} do
        {nil, :superadmin} ->
          {nil, attrs}

        {nil, _role} ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        {tid, _role} ->
          {tid, attrs}
      end

    data = build(:api_key, attrs)
    data = Map.put(data, :tenant_id, tenant_id)

    {:ok, {raw_key, api_key}} = Auth.generate_api_key(data)
    {raw_key, api_key}
  end

  def fixture(:audit_log, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {inserted_at, attrs} = Map.pop(attrs, :inserted_at)
    data = build(:audit_log, attrs)

    changeset =
      data
      |> AuditLog.create_changeset()
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
      |> put_inserted_at(inserted_at)

    AdminRepo.insert!(changeset)
  end

  def fixture(:orchestrator_state, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # Auto-create project if not provided
    {project_id, attrs} =
      case Map.get(attrs, :project_id) do
        nil ->
          project = fixture(:project, %{tenant_id: tenant_id})
          {project.id, Map.put(attrs, :project_id, project.id)}

        pid ->
          {pid, attrs}
      end

    data = build(:orchestrator_state, attrs)

    changeset =
      %OrchestratorState{tenant_id: tenant_id, project_id: project_id}
      |> OrchestratorState.create_changeset(data)

    # Allow overriding version after creation
    version = Map.get(data, :version, 1)

    state = AdminRepo.insert!(changeset)

    if version != 1 do
      state
      |> Ecto.Changeset.change(%{version: version})
      |> AdminRepo.update!()
    else
      state
    end
  end

  def fixture(:skill, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    project_id = Map.get(attrs, :project_id)
    prompt_text = Map.get(attrs, :prompt_text, "Default skill prompt text")
    data = build(:skill, attrs)

    changeset =
      %Skill{tenant_id: tenant_id, project_id: project_id}
      |> Skill.create_changeset(data)

    skill = AdminRepo.insert!(changeset)

    # Create v1 version
    version_changeset =
      %SkillVersion{
        tenant_id: tenant_id,
        skill_id: skill.id,
        version: 1
      }
      |> SkillVersion.create_changeset(%{
        prompt_text: prompt_text,
        created_by: "fixture",
        changelog: "Initial version"
      })

    AdminRepo.insert!(version_changeset)

    skill
  end

  def fixture(:skill_version, attrs) do
    attrs = Enum.into(attrs, %{})
    skill_id = Map.fetch!(attrs, :skill_id)
    tenant_id = Map.fetch!(attrs, :tenant_id)
    version = Map.fetch!(attrs, :version)

    data = build(:skill_version, attrs)

    changeset =
      %SkillVersion{
        tenant_id: tenant_id,
        skill_id: skill_id,
        version: version
      }
      |> SkillVersion.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:skill_result, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)
    skill_version_id = Map.fetch!(attrs, :skill_version_id)
    verification_result_id = Map.fetch!(attrs, :verification_result_id)
    story_id = Map.fetch!(attrs, :story_id)

    data = build(:skill_result, attrs)

    changeset =
      %SkillResult{
        tenant_id: tenant_id,
        skill_version_id: skill_version_id,
        verification_result_id: verification_result_id,
        story_id: story_id
      }
      |> SkillResult.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:ui_test_run, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {project_id, attrs} =
      case Map.get(attrs, :project_id) do
        nil ->
          project = fixture(:project, %{tenant_id: tenant_id})
          {project.id, Map.put(attrs, :project_id, project.id)}

        pid ->
          {pid, attrs}
      end

    agent_id = Map.get(attrs, :started_by_agent_id)
    status = Map.get(attrs, :status, :in_progress)

    data = build(:ui_test_run, attrs)

    changeset =
      %UiTestRun{
        tenant_id: tenant_id,
        project_id: project_id,
        started_by_agent_id: agent_id
      }
      |> UiTestRun.create_changeset(data)

    run = AdminRepo.insert!(changeset)

    # Apply non-default status overrides after creation
    if status != :in_progress do
      run
      |> Ecto.Changeset.change(%{status: status, completed_at: DateTime.utc_now()})
      |> AdminRepo.update!()
    else
      run
    end
  end

  @doc """
  Generates a fresh binary UUID for use in tests.
  """
  def uuid, do: Ecto.UUID.generate()

  @doc """
  The bytes of `git diff --name-status -M -z` for a list of MODIFIED paths.

  Every field is NUL-TERMINATED, including the last, which is what
  `Loopctl.DeliveryGates.Measurement.RepoHistory` and `DiffNames` both require: output with
  anything after the final NUL is a record git was cut off mid-way through.
  """
  def name_status_z(files) do
    Enum.map_join(files, "", fn file -> "M" <> <<0>> <> file <> <<0>> end)
  end

  @doc """
  Inserts a knowledge `Article` with a controlled `inserted_at` and `source_type`.

  The normal `fixture(:article, ...)` path auto-sets `inserted_at` to now via
  timestamps; the ingestion capture-silence detector reasons over `inserted_at`, so
  tests need to backdate captured articles. Pass `:inserted_at` (a DateTime) and
  `:source_type`; auto-creates a tenant when `:tenant_id` is absent.
  """
  def captured_article(attrs) do
    attrs = Enum.into(attrs, %{})
    {inserted_at, attrs} = Map.pop(attrs, :inserted_at)
    article = fixture(:article, attrs)

    if inserted_at do
      import Ecto.Query

      {1, [updated]} =
        from(a in Article, where: a.id == ^article.id, select: a)
        |> AdminRepo.update_all(set: [inserted_at: inserted_at])

      updated
    else
      article
    end
  end

  @doc """
  Inserts ONE nightly `knowledge.lint_completed` audit event, `hours_ago` old.

  A dedicated helper rather than a bare `fixture(:audit_log, ...)` call because the
  consumer-stall detector matches on the exact `entity_type`/`action` pair the nightly
  pass writes, and a test that spells those inline is one typo away from asserting
  against an empty scan.
  """
  def knowledge_lint_run(tenant_id, hours_ago, state) do
    fixture(:audit_log, %{
      tenant_id: tenant_id,
      entity_type: "knowledge_lint",
      entity_id: tenant_id,
      action: "knowledge.lint_completed",
      actor_type: "system",
      actor_label: "worker:knowledge_lint",
      new_state: state,
      inserted_at: DateTime.add(DateTime.utc_now(), -hours_ago, :hour)
    })
  end

  @doc """
  `count` consecutive nightly `knowledge.lint_completed` events carrying the same
  `state` — most recent 2h ago, one per 24h back.
  """
  def knowledge_lint_runs(tenant_id, count, state) do
    for n <- 0..(count - 1), do: knowledge_lint_run(tenant_id, 2 + n * 24, state)
  end

  # --- Private helpers ---
  # `audit_log` carries a BEFORE UPDATE trigger (`audit_log_no_update`), so the
  # backdate-after-insert trick `captured_article/1` uses is not available here: a
  # controlled `inserted_at` has to be set on the INSERT. `create_changeset/1` does not
  # cast it (the log is append-only and stamps its own time), and Ecto's autogenerated
  # timestamp defers to an explicit change — so `put_change/3` is the seam. Used by tests
  # that reason over the AGE of audit events, e.g. the nightly consumer-stall detector.
  defp put_inserted_at(changeset, nil), do: changeset

  defp put_inserted_at(changeset, %DateTime{} = at),
    do: Ecto.Changeset.put_change(changeset, :inserted_at, at)

  defp apply_story_overrides(story, :pending, :unverified, nil), do: story

  defp apply_story_overrides(story, agent_status, verified_status, assigned_agent_id) do
    # DB CHECK stories_reported_done_requires_agent (chain-of-custody INVARIANT 1):
    # a reported_done story must carry provenance for who did the work — an
    # assigned agent (unless backfilled). Keep fixtures realistic AND valid by
    # auto-assigning a fresh agent when a test asks for reported_done without
    # specifying one. Tests that need the illegitimate reported_done + NULL-agent
    # state (e.g. asserting the CHECK/guard rejects it) build it directly, not via
    # this fixture.
    assigned_agent_id =
      if agent_status == :reported_done and is_nil(assigned_agent_id) do
        fixture(:agent, %{tenant_id: story.tenant_id}).id
      else
        assigned_agent_id
      end

    overrides =
      %{agent_status: agent_status, verified_status: verified_status}
      |> maybe_put(:assigned_agent_id, assigned_agent_id)

    story
    |> Ecto.Changeset.change(overrides)
    |> AdminRepo.update!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_tenant(attrs) do
    case Map.get(attrs, :tenant_id) do
      nil ->
        tenant = fixture(:tenant)
        {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

      tid ->
        {tid, attrs}
    end
  end

  defp ensure_scope_entity(%{scope_id: sid} = attrs, _scope_type, _tenant_id) do
    {sid, attrs}
  end

  defp ensure_scope_entity(attrs, :project, tenant_id) do
    entity = fixture(:project, %{tenant_id: tenant_id})
    {entity.id, Map.put(attrs, :scope_id, entity.id)}
  end

  defp ensure_scope_entity(attrs, :epic, tenant_id) do
    entity = fixture(:epic, %{tenant_id: tenant_id})
    {entity.id, Map.put(attrs, :scope_id, entity.id)}
  end

  defp ensure_scope_entity(attrs, :agent, tenant_id) do
    entity = fixture(:agent, %{tenant_id: tenant_id})
    {entity.id, Map.put(attrs, :scope_id, entity.id)}
  end

  defp ensure_scope_entity(attrs, :story, tenant_id) do
    entity = fixture(:story, %{tenant_id: tenant_id})
    {entity.id, Map.put(attrs, :scope_id, entity.id)}
  end

  defp ensure_scope_entity(attrs, _unknown, _tenant_id) do
    {Ecto.UUID.generate(), attrs}
  end

  defp bind_triage_dispatch(repo, %TriageVerdictRecord{} = verdict) do
    repo.update_all(
      from(r in StoryStage,
        where: r.tenant_id == ^verdict.tenant_id and r.story_id == ^verdict.story_id,
        # First writer wins, as in production: the transition that bound the story is the one
        # that took it out of `detected`, and nothing overwrites it.
        where: is_nil(r.triage_dispatch_id)
      ),
      set: [triage_dispatch_id: verdict.dispatch_id]
    )
  end

  defp insert_merged_event(repo, %StoryStage{} = row, merged_at) do
    repo.insert_all(Loopctl.Delivery.StageEvent, [
      %{
        id: Ecto.UUID.generate(),
        tenant_id: row.tenant_id,
        story_stage_id: row.id,
        story_id: row.story_id,
        event: "transitioned",
        from_stage: "ci",
        to_stage: "merged",
        edge: "forward",
        claim_epoch: row.claim_epoch,
        lock_version: row.lock_version,
        actor_label: "fixture",
        data: %{},
        inserted_at: merged_at
      }
    ])
  end

  @doc """
  Deletes every tenant `fixture(:committed_runner | :committed_tenant)` committed.

  A committed test that reaches a CHAINED transition (`Loopctl.Delivery.Placement` claims a
  story, which appends `story_stage_claimed`) leaves `audit_chain` rows, and
  `audit_chain_prevent_delete_trigger` raises on any DELETE — including the one a tenant
  cascade would issue. Those rows are therefore removed first with user triggers suppressed.

  **`SET LOCAL`, inside an explicit transaction, and never a bare `SET`.** A bare `SET
  session_replication_role` is CONNECTION state on a POOLED connection: any path out of this
  function that is not the happy one — a `DBConnection.ConnectionError`, an `Ecto.UUID.dump!/1`
  raise on a malformed id, anything the `rescue` below does not match — checks the connection
  back in with user triggers AND FK enforcement still disabled, for whatever test picks it up
  next. That is silent, non-local corruption of the rest of the suite, and it would disable
  `audit_chain_prevent_delete_trigger` for a test that has no idea it is running unprotected.
  `SET LOCAL` reverts when the transaction ends, on commit and on rollback alike, so there is
  no path that leaks it.

  The suppression covers the `audit_chain` delete ALONE. It also suppresses FK triggers, so the
  tenant delete — which needs its cascades to fire — runs outside that transaction.

  Best effort: `session_replication_role` needs a superuser, and a test database whose role
  is not one keeps its marker tenants rather than failing an `on_exit`.
  """
  def sweep_committed_runner_tenants do
    import Ecto.Query, only: [from: 2]

    Sandbox.unboxed_run(AdminRepo, fn ->
      ids =
        AdminRepo.all(
          from(t in Tenant, where: like(t.slug, ^"#{@committed_runner_marker}%"), select: t.id)
        )

      if ids != [], do: sweep_tenant_ids(ids)
    end)

    :ok
  end

  @doc """
  Deletes the `audit_chain` rows of the given tenants (raw 16-byte uuids), with user triggers
  suppressed for that ONE statement.

  Public so its two properties can be asserted directly — `sweep_committed_runner_tenants/0`
  swallows its own failure by design (it runs in an `on_exit`), so nothing would notice this
  silently stopping to work except a test database that slowly fills with tenants nobody can
  delete.

  1. It actually deletes. `audit_chain_prevent_delete_trigger` raises on ANY delete, a tenant
     cascade included, so without the suppression a tenant that ever appended an entry is
     undeletable.
  2. It does NOT leak. `SET LOCAL` reverts when the transaction ends, on commit and on
     rollback alike. A bare `SET` here is CONNECTION state on a POOLED connection: any path
     out that is not the happy one returns it with user triggers AND FK enforcement disabled,
     for whatever test checks it out next — silent, non-local corruption of the rest of the
     suite, and the disabled trigger would be the very one protecting the audit chain.
  """
  def delete_audit_chain_rows!(raw_ids) do
    {:ok, _} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!("SET LOCAL session_replication_role = replica")
        AdminRepo.query!("DELETE FROM audit_chain WHERE tenant_id = ANY($1)", [raw_ids])
      end)

    :ok
  end

  defp sweep_tenant_ids(ids) do
    import Ecto.Query, only: [from: 2]

    raw_ids = Enum.map(ids, &Ecto.UUID.dump!/1)

    delete_audit_chain_rows!(raw_ids)

    # `dispatches_tenant_id_fkey` does NOT cascade, so a tenant that minted one — every
    # placement does — cannot be deleted until its dispatches are, and a claimed story
    # REFERENCES its implementer dispatch, so those two columns go first. Outside the
    # transaction above on purpose: these need the FK triggers the suppression turns off.
    AdminRepo.query!(
      "UPDATE stories SET implementer_dispatch_id = NULL, verifier_dispatch_id = NULL " <>
        "WHERE tenant_id = ANY($1)",
      [raw_ids]
    )

    AdminRepo.query!("DELETE FROM dispatches WHERE tenant_id = ANY($1)", [raw_ids])
    AdminRepo.delete_all(from(t in Tenant, where: t.id in ^ids))
  rescue
    error ->
      IO.warn(
        "committed-runner tenants left behind: #{Exception.message(error)}. " <>
          "Removing an audit_chain row needs a superuser connection."
      )

      :ok
  end
end
