defmodule Loopctl.Fixtures do
  @moduledoc """
  Test fixture helpers for building and inserting test data.

  - `build/2` — returns a map or struct without touching the database.
  - `fixture/2` — inserts into the database, auto-creating dependencies.

  All fixtures use binary UUIDs. Tenant isolation tests should create
  separate tenants via `fixture(:tenant)`.
  """

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.Artifacts.ArtifactReport
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Auth
  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionWriteStats
  alias Loopctl.Knowledge.RetrievalEval.GoldenSet, as: RetrievalGoldenSet
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

    # US-26.7.1: trust_tier is excluded from create_changeset's cast (never
    # settable from a public changeset) — set it programmatically here,
    # mirroring the audit_signing_public_key post-insert pattern above.
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

    data = build(:audit_log, attrs)

    changeset =
      data
      |> AuditLog.create_changeset()
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)

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

  # --- Private helpers ---

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
end
