defmodule Loopctl.Knowledge.SearchEventCoverage do
  @moduledoc """
  Declared per-tool COVERAGE PROFILES for `search_events`, and a report naming which
  declared columns are missing.

  ## Why a declaration, and not another query

  `search_events` went live on 2026-08-12 with the machinery built correctly and nearly
  blind: **2 of its first 133 rows carried any `client_*` context at all**. Every MCP
  process caches its dependencies at boot, so a published client update does not reach a
  running session — the fleet kept emitting rows from code that had no context header, and
  nothing said so. The wiki finding is
  "search_events telemetry: MCP process caching prevents code updates without restart"
  (`94ebf749-5b78-46a0-978a-bb9d2a53b69b`); the read-side consequences are in
  "search_events interpretation: UserPromptSubmit and smoke tests bypass MCP"
  (`80d5c9b0-7deb-4726-b337-3cb7e5efcfdb`).

  What made that expensive was not the gap. It was that the gap was DISCOVERABLE ONLY BY
  AUDIT. Read completeness never implies end-to-end instrumentation: the table answered
  every question asked of it, in the sense that the query returned rows, while the columns
  the question actually turned on were null. That failure mode has a name in prior art —
  MemoRizz v0.8.0 declares the evidence stages a task type is expected to emit and its
  diagnostics report which stage is ABSENT rather than leaving an audit to find it
  (`RichmondAlake/memorizz`, `src/memorizz/observability/coverage.py`; assessment article
  `80a063e9-22b4-4469-9f1e-3be499a3fc2c`, item 5). This module is that idea applied to the
  one table where loopctl has already paid for its absence.

  The registry is therefore a DECLARATION, not a measurement. A surface that emitted no
  rows at all still appears, with `rows: 0` — a profile that never fires is the exact
  finding an audit-only approach cannot produce, because there is nothing to audit.

  ## What this report can and cannot prove

  **It can prove a column is ABSENT.** A null is a null; the count is exact for the window.

  **It cannot prove a present column is CORRECT**, and on this table that distinction is
  load-bearing rather than pedantic. `client_kind` is the worked example: one MCP server
  process serves a session and every agent it dispatches, with an environment frozen at
  spawn, so it labels EVERY search `main` — including searches a subagent made. A row with
  a non-null `client_kind` is 100% covered here and may still be wrong about the only thing
  that column exists to say. `Loopctl.Knowledge.SearchEventEnrichment` is what refines it,
  offline, from the session transcripts.

  It also cannot prove a MISSING ROW. This counts rows that were written; a search path
  that records nothing at all contributes to no profile and to no denominator. The
  `unprofiled` bucket is the nearest thing to a guard against that — a `tool` value with
  rows and no profile is reported, never silently dropped — but a surface that writes
  nothing is invisible to any query over this table.

  ## Populations: `:all`, `:ran`, `:agent`

  A coverage number is only meaningful against the rows that COULD have carried the column,
  so every declared column names its population. Reporting one denominator for all of them
  is how a structural absence reads as a defect:

    * `:all` — every row for the tool.
    * `:ran` — `outcome != "rejected"`. A rejected call never ran, so it has no `mode_used`
      and no `duration_ms` by construction (`LoopctlWeb.KnowledgeSearchController`'s
      rejection recorder sets neither). Scoring those against `:all` would report a
      permanent miss for the rows this table exists to make visible.
    * `:agent` — the row carries a `client_kind` or a `client_session_id`, i.e. it really
      came through the MCP client. The recall hook and `scripts/smoke.sh` call the API
      directly and can never supply `client_*` context, so measuring the client columns
      over `:all` measures the share of loopctl's own automation, not client coverage.

  ## Required vs enrichable

  `required` columns a correctly-instrumented CLIENT (or the server) can fill at record
  time. `enrichable` columns are reported SEPARATELY because no client can fill them, so a
  miss there is not a client defect:

    * `client_model` and `client_effort` — neither variable exists in the environment the
      MCP server is spawned with. Only the offline transcript join fills them.
    * `agent_id` — server-derived from the authenticating key, and a key that no agent owns
      (a user or orchestrator key) has none to derive. Grouped with the enrichable set
      because, like them, it is not something a client can send.

  Enrichable coverage is CENSORED ON THE RIGHT for a different reason than the required
  set: `mix loopctl.enrich_search_events` is run on a schedule (see
  `docs/runbooks/search-events-analysis.md`), so a window ending close to now measures the
  enrichment's lag as if it were a gap. Read a recent enrichable share as a floor.

  `client_kind` sits in BOTH senses and is deliberately declared `required`: a client does
  send it, so its absence is a client defect worth reporting, even though only the
  enrichment makes the value caller-level truth.

  ## Reading it

      Loopctl.Knowledge.SearchEventCoverage.report(tenant_id, from, to)

  One query, tenant-scoped, over `Loopctl.HeavyRead` — never `AdminRepo`, whose
  3-connection pool (`config/runtime.exs:277`) is shared with every custody write.
  """

  import Ecto.Query

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.SearchEvent

  # The migration that created the table. A window starting before it is not a smaller
  # sample, it is a window in which the instrument did not exist — the same distinction
  # `LiveRetrievalMetrics.pairs/3` draws at its own `@history_starts`.
  @history_starts ~U[2026-08-12 00:00:00.000000Z]

  # A ceiling on ONE report, so a caller cannot ask for an unbounded scan of the
  # `(tenant_id, inserted_at)` index. Generous on purpose: the query is a grouped count with
  # no join, and the honest limit on this surface is the table's own life.
  @max_window_days 366

  @baseline_required ~w(query tool mode_used result_count duration_ms api_key_id)a
  @agent_required ~w(client_host client_repo client_entrypoint client_version client_kind)a
  @enrichable ~w(client_model client_effort agent_id)a

  # Every column this report can speak about: its POPULATION (above) and how "missing" is
  # tested. Text columns treat blank as missing — a `client_repo` of "" is not coverage,
  # and `query` is written as "" by the enumeration lanes. Validated against
  # `SearchEvent.__schema__(:fields)` by `search_event_coverage_test.exs`, so renaming a
  # column breaks the BUILD rather than silently emptying a line of the report.
  @columns %{
    query: {:all, :text},
    tool: {:all, :text},
    mode_used: {:ran, :text},
    result_count: {:all, :value},
    duration_ms: {:ran, :value},
    api_key_id: {:all, :value},
    client_host: {:agent, :text},
    client_repo: {:agent, :text},
    client_entrypoint: {:agent, :text},
    client_version: {:agent, :text},
    client_kind: {:agent, :text},
    client_model: {:agent, :text},
    client_effort: {:agent, :text},
    agent_id: {:all, :value}
  }

  # The registry. Keyed by the `tool` column, and every value here is WRITTEN by a named
  # site — enumerated from the code, because a profile for a label nothing emits reports a
  # permanent 0 that reads as a broken surface:
  #
  #   knowledge_search           `Knowledge.tool_for_mode/1` default (keyword/semantic/
  #                              combined lanes) + KnowledgeSearchController's rejection
  #                              and embedding-failure recorders
  #   knowledge_list             `tool_for_mode/1` for the `list` / `list_keyset` lanes +
  #                              KnowledgeSearchController's `request_tool/1`
  #   knowledge_hybrid_search    `tool_for_mode/1` for `hybrid_curated`/`hybrid_retrieved` +
  #                              KnowledgeHybridSearchController
  #   knowledge_context          KnowledgeContextController
  #   knowledge_progressive_index KnowledgeProgressiveController
  #   memory_recall              `Loopctl.Memory`'s `:_tool` override on the knowledge half
  #                              of /recall
  @profiles [
    %{
      tool: "knowledge_search",
      required: @baseline_required ++ @agent_required,
      enrichable: @enrichable
    },
    %{
      tool: "knowledge_hybrid_search",
      required: @baseline_required ++ @agent_required,
      enrichable: @enrichable
    },
    %{
      tool: "knowledge_context",
      required: @baseline_required ++ @agent_required,
      enrichable: @enrichable
    },
    %{
      tool: "knowledge_progressive_index",
      required: @baseline_required ++ @agent_required,
      enrichable: @enrichable
    },
    %{
      tool: "memory_recall",
      required: @baseline_required ++ @agent_required,
      enrichable: @enrichable
    },
    # `query` is DROPPED, not forgotten. These are query-less enumeration pages — the
    # browse endpoints record `""` by construction — so requiring it would report a 100%
    # miss that is the surface working as designed, and a report that cries every day is
    # one nobody reads.
    %{
      tool: "knowledge_list",
      required: (@baseline_required -- [:query]) ++ @agent_required,
      enrichable: @enrichable
    }
  ]

  @type column_report :: %{
          scope: :all | :ran | :agent,
          population: non_neg_integer(),
          missing: non_neg_integer(),
          share_missing: float() | nil
        }

  @type profile_report :: %{
          tool: String.t(),
          rows: non_neg_integer(),
          populations: %{all: non_neg_integer(), ran: non_neg_integer(), agent: non_neg_integer()},
          required: %{atom() => column_report()},
          enrichable: %{atom() => column_report()}
        }

  @doc "The declared profiles, in report order."
  @spec profiles() :: [map()]
  def profiles, do: @profiles

  @doc "The `tool` values that have a declared profile."
  @spec profiled_tools() :: [String.t()]
  def profiled_tools, do: Enum.map(@profiles, & &1.tool)

  @doc "Every column the registry can report on, mapped to `{population, missing_test}`."
  @spec columns() :: %{atom() => {:all | :ran | :agent, :text | :value}}
  def columns, do: @columns

  @doc "The three populations a declared column can be measured over."
  @spec scopes() :: [:all | :ran | :agent]
  def scopes, do: [:all, :ran, :agent]

  @doc "First instant this table can be asked about — the migration that created it."
  @spec history_starts() :: DateTime.t()
  def history_starts, do: @history_starts

  @doc "Longest window one report may cover, in days."
  @spec max_window_days() :: pos_integer()
  def max_window_days, do: @max_window_days

  @doc """
  Coverage over `[from, to)` for `tenant_id`.

  Returns `rows_total`, one entry per declared profile (including profiles with no rows),
  and an `unprofiled` bucket naming every `tool` value that HAS rows but no profile — a
  `nil` tool included, since a row that named no tool belongs to no profile and must not
  vanish from the accounting.

  RAISES `ArgumentError` on a window that cannot be measured, rather than returning an
  empty report: an unmeasurable window must not look like an uninformative one. Callers on
  the HTTP path clamp `from` to `history_starts/0` first, so the raise is a programming
  error, not a user error.
  """
  @spec report(Ecto.UUID.t(), DateTime.t(), DateTime.t()) :: map()
  def report(tenant_id, %DateTime{} = from, %DateTime{} = to) when is_binary(tenant_id) do
    measurable_window!(from, to)

    rows = tenant_id |> coverage_query(from, to) |> then(&HeavyRead.all(tenant_id, &1))

    by_tool = Map.new(rows, &{&1.tool, &1})

    %{
      window: %{from: from, to: to},
      rows_total: Enum.reduce(rows, 0, &(&1.rows + &2)),
      profiles: Enum.map(@profiles, &profile_report(&1, Map.get(by_tool, &1.tool))),
      unprofiled: unprofiled(rows)
    }
  end

  # ---------------------------------------------------------------------------
  # Window
  # ---------------------------------------------------------------------------

  defp measurable_window!(from, to) do
    cond do
      DateTime.compare(from, to) != :lt ->
        raise ArgumentError,
              "report/3 window #{from}..#{to} is empty or inverted: [from, to) needs from < to"

      DateTime.compare(from, @history_starts) == :lt ->
        raise ArgumentError,
              "report/3 from #{from}: search_events starts #{@history_starts}, so an earlier " <>
                "window is one in which the instrument did not exist, not a smaller sample"

      DateTime.diff(to, from, :day) > @max_window_days ->
        raise ArgumentError,
              "report/3 window #{from}..#{to} exceeds #{@max_window_days} days; narrow it"

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The one query
  # ---------------------------------------------------------------------------

  # ONE grouped count for the whole report, not one per profile: every profile needs the
  # same 14 columns over the same window, and the `(tenant_id, inserted_at)` index serves
  # the scan once. No `heavy_read_statement_timeout_overrides` entry — this is a grouped
  # aggregate with no join and no vector work, so the 10s default is not tight.
  #
  # Each aggregate is written out rather than generated, so it is greppable; the registry
  # and this select are bound by `report_column/3`'s `Map.fetch!`, which raises if a
  # declared column has no aggregate here, and by the test that walks every declared column.
  defp coverage_query(tenant_id, from, to) do
    from(e in SearchEvent,
      where: e.tenant_id == ^tenant_id,
      where: e.inserted_at >= ^from and e.inserted_at < ^to,
      group_by: e.tool,
      select: %{
        tool: e.tool,
        rows: count(),
        pop_ran: fragment("count(*) FILTER (WHERE ? IS DISTINCT FROM 'rejected')", e.outcome),
        pop_agent:
          fragment(
            "count(*) FILTER (WHERE ? IS NOT NULL OR ? IS NOT NULL)",
            e.client_kind,
            e.client_session_id
          ),
        query_missing: fragment("count(*) FILTER (WHERE coalesce(btrim(?), '') = '')", e.query),
        tool_missing: fragment("count(*) FILTER (WHERE coalesce(btrim(?), '') = '')", e.tool),
        mode_used_missing:
          fragment(
            "count(*) FILTER (WHERE ? IS DISTINCT FROM 'rejected' AND coalesce(btrim(?), '') = '')",
            e.outcome,
            e.mode_used
          ),
        result_count_missing: fragment("count(*) FILTER (WHERE ? IS NULL)", e.result_count),
        duration_ms_missing:
          fragment(
            "count(*) FILTER (WHERE ? IS DISTINCT FROM 'rejected' AND ? IS NULL)",
            e.outcome,
            e.duration_ms
          ),
        api_key_id_missing: fragment("count(*) FILTER (WHERE ? IS NULL)", e.api_key_id),
        client_host_missing:
          fragment(
            "count(*) FILTER (WHERE (? IS NOT NULL OR ? IS NOT NULL) AND coalesce(btrim(?), '') = '')",
            e.client_kind,
            e.client_session_id,
            e.client_host
          ),
        client_repo_missing:
          fragment(
            "count(*) FILTER (WHERE (? IS NOT NULL OR ? IS NOT NULL) AND coalesce(btrim(?), '') = '')",
            e.client_kind,
            e.client_session_id,
            e.client_repo
          ),
        client_entrypoint_missing:
          fragment(
            "count(*) FILTER (WHERE (? IS NOT NULL OR ? IS NOT NULL) AND coalesce(btrim(?), '') = '')",
            e.client_kind,
            e.client_session_id,
            e.client_entrypoint
          ),
        client_version_missing:
          fragment(
            "count(*) FILTER (WHERE (? IS NOT NULL OR ? IS NOT NULL) AND coalesce(btrim(?), '') = '')",
            e.client_kind,
            e.client_session_id,
            e.client_version
          ),
        client_kind_missing:
          fragment(
            "count(*) FILTER (WHERE (? IS NOT NULL OR ? IS NOT NULL) AND coalesce(btrim(?), '') = '')",
            e.client_kind,
            e.client_session_id,
            e.client_kind
          ),
        client_model_missing:
          fragment(
            "count(*) FILTER (WHERE (? IS NOT NULL OR ? IS NOT NULL) AND coalesce(btrim(?), '') = '')",
            e.client_kind,
            e.client_session_id,
            e.client_model
          ),
        client_effort_missing:
          fragment(
            "count(*) FILTER (WHERE (? IS NOT NULL OR ? IS NOT NULL) AND coalesce(btrim(?), '') = '')",
            e.client_kind,
            e.client_session_id,
            e.client_effort
          ),
        agent_id_missing: fragment("count(*) FILTER (WHERE ? IS NULL)", e.agent_id)
      }
    )
  end

  # ---------------------------------------------------------------------------
  # Shaping
  # ---------------------------------------------------------------------------

  defp profile_report(profile, nil) do
    empty = %{all: 0, ran: 0, agent: 0}

    %{
      tool: profile.tool,
      rows: 0,
      populations: empty,
      required: Map.new(profile.required, &{&1, empty_column(&1)}),
      enrichable: Map.new(profile.enrichable, &{&1, empty_column(&1)})
    }
  end

  defp profile_report(profile, row) do
    populations = %{all: row.rows, ran: row.pop_ran, agent: row.pop_agent}

    %{
      tool: profile.tool,
      rows: row.rows,
      populations: populations,
      required: Map.new(profile.required, &{&1, report_column(&1, row, populations)}),
      enrichable: Map.new(profile.enrichable, &{&1, report_column(&1, row, populations)})
    }
  end

  defp empty_column(column) do
    {scope, _test} = Map.fetch!(@columns, column)
    %{scope: scope, population: 0, missing: 0, share_missing: nil}
  end

  # `Map.fetch!` on BOTH maps on purpose. A column declared in a profile with no entry in
  # `@columns`, or with no aggregate in the select above, raises here instead of reporting a
  # confident zero — a coverage report that under-reports its own gaps is the one failure
  # this module cannot be allowed to have.
  defp report_column(column, row, populations) do
    {scope, _test} = Map.fetch!(@columns, column)
    population = Map.fetch!(populations, scope)
    missing = Map.fetch!(row, :"#{column}_missing")

    %{
      scope: scope,
      population: population,
      missing: missing,
      share_missing: share(missing, population)
    }
  end

  # `nil`, never `0.0`, on an empty population: zero would assert that every row carried the
  # column when the truth is that there were no rows to carry it. The same nil-for-n/a rule
  # `LiveRetrievalMetrics.summarise/1` and `RetrievalEval` follow.
  defp share(_missing, 0), do: nil
  defp share(missing, population), do: Float.round(missing / population, 4)

  # A tool value with rows and no profile is REPORTED, never dropped: an unrecognised
  # surface is the thing a declared registry exists to notice. `nil` is included — a row
  # that named no tool joins no profile, so silently discarding it would let
  # `sum(profile.rows)` disagree with `rows_total` for a reason nobody could see.
  defp unprofiled(rows) do
    declared = MapSet.new(profiled_tools())

    rows
    |> Enum.reject(&MapSet.member?(declared, &1.tool))
    |> Enum.map(&%{tool: &1.tool, rows: &1.rows})
    |> Enum.sort_by(&{-&1.rows, &1.tool || ""})
  end
end
