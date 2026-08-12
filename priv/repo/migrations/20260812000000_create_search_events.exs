defmodule Loopctl.Repo.Migrations.CreateSearchEvents do
  @moduledoc """
  One row per SEARCH ATTEMPT (#658) — the counterpart to `article_access_events`, which
  records one row per SURFACED RESULT.

  That granularity difference is the whole point. `maybe_record_search_access/5` skips
  recording entirely when `results in [nil, []]`, so a search that finds NOTHING leaves no
  trace anywhere in the database. The two failure modes that matter most are therefore the
  two the system cannot see:

    * a search that returned nothing, and
    * a search that was rejected before it ran (a 400/422 never reaches the recorder).

  Both had to be recovered by hand-mining 6,457 session transcripts across two machines.
  That investigation found 86 rejected `knowledge_search` calls — 8% of every search made —
  and a silent degradation path where an embedding timeout returns HTTP 200 with an empty
  result array, indistinguishable from "nothing matched". None of it was visible from the
  database, and none of it would have been found without the transcripts.

  This table makes the attempt itself the unit of record, so the misses become queryable.
  """
  use Ecto.Migration

  def up do
    create table(:search_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # Correlates to article_access_events.metadata->>'search_id', so a row here joins to
      # the per-RESULT rows (rank, article_id) recorded for the same search.
      add :search_id, :binary_id

      add :api_key_id, :binary_id
      add :agent_id, :binary_id
      add :project_id, :binary_id
      add :story_id, :binary_id

      # NULL for enumeration/list mode, which legitimately carries no query.
      add :query, :text
      # Pre-computed so the query-shape analysis (single tokens, machine-generated noise)
      # is a GROUP BY rather than a re-parse of every row.
      add :query_terms, :integer

      add :tool, :string
      add :mode_requested, :string
      add :mode_used, :string

      # WHAT was being searched, not just what came back. A tenant may hold several kb
      # scopes, so tenant_id alone does not identify the corpus a query actually ran
      # against — the filters do, and without them a zero-result row cannot be told apart
      # from a zero-result row that was scoped to an empty category.
      add :filters, :map, default: %{}
      add :limit_requested, :integer
      add :offset_requested, :integer

      # The candidate pool the ranker chose FROM, which is not the number returned. A page
      # of 5 out of 100 candidates and a page of 5 out of 5 are different retrieval events.
      add :total_count, :integer
      # Enough to judge relevance later WITHOUT replaying the query — replay measures
      # today's ranker against today's corpus and can no longer see what the agent saw.
      add :top_result_id, :binary_id
      add :top_result_score, :float

      # 0 IS THE INTERESTING VALUE. Nothing else in the schema can express it.
      add :result_count, :integer, null: false, default: 0

      add :degraded, :boolean, null: false, default: false
      add :fallback_reason, :string
      add :ann_iterative_scan, :string
      add :duration_ms, :integer

      # --- WHO searched, and from where (client-supplied context) --------------------
      #
      # None of this is derivable server-side: an api_key identifies a KEY, and under the
      # v2 dispatch pattern a key is minted per dispatch, so it cannot tell you which agent,
      # which model, which repo, or whether the caller was a main session or a subagent.
      # The MCP client observes these from its own environment and sends them.
      #
      # UNTRUSTED BY CONSTRUCTION. A client can lie about every one of these, so they are
      # ANALYTICS ONLY and must never gate access or authorize anything — the api_key stays
      # the sole authority. They are prefixed `client_` so no future reader mistakes them
      # for server-derived facts.
      add :client_session_id, :string
      add :client_effort, :string
      # NOT available in the client environment (verified 2026-08-12: CLAUDE_EFFORT is set,
      # nothing model-shaped is). Kept because the session transcript DOES record the model,
      # so client_session_id is the join key that enriches this offline — and because the
      # day the runtime exposes it, the column is already here.
      add :client_model, :string
      add :client_host, :string
      # The repo the agent was working IN, which is not the project the KB search was
      # scoped to. "Which repos lean on the KB, and which never do" is unanswerable
      # without it.
      add :client_repo, :string
      add :client_entrypoint, :string
      # Main session vs dispatched child (subagent OR workflow agent). This matters: an
      # audit measured materially different failure RATES across those populations
      # (main 8.2%, workflow 6.0%, subagent 3.7% on one failure class), and averaging them
      # hides all three. Children also never see the recall-pack injection, so they search
      # differently by construction.
      #
      # A STRING, not a boolean, and deliberately only two values. Workflow agents cannot
      # be told apart from ordinary subagents in the client environment — CLAUDE_CODE_WORKFLOWS
      # is a feature flag present in main sessions too, and no marker distinguishes them —
      # so the honest field records what is observable. The three-way split is recoverable
      # OFFLINE by joining client_session_id to the transcript path (wf_* vs subagents/),
      # the same enrichment path client_model uses. A boolean would have foreclosed even
      # naming the third value.
      add :client_kind, :string
      add :client_version, :string

      # ok | zero_results | degraded | rejected
      add :outcome, :string, null: false
      add :rejection_reason, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:search_events, [:tenant_id, :inserted_at])
    # The analysis queries all filter by outcome (how many found nothing? were rejected?),
    # so it leads the composite rather than trailing it.
    create index(:search_events, [:tenant_id, :outcome, :inserted_at])
    create index(:search_events, [:tenant_id, :search_id])

    execute "ALTER TABLE search_events ENABLE ROW LEVEL SECURITY"

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'search_events' AND policyname = 'tenant_isolation'
      ) THEN
        EXECUTE 'CREATE POLICY tenant_isolation ON search_events USING (tenant_id = current_tenant_id())';
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loopctl_app') THEN
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON search_events TO loopctl_app';
      END IF;
    END $$;
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation ON search_events"
    execute "ALTER TABLE search_events DISABLE ROW LEVEL SECURITY"
    drop table(:search_events)
  end
end
