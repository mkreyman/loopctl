defmodule Loopctl.Knowledge.SearchEvent do
  @moduledoc """
  Schema for the `search_events` table — one immutable row per SEARCH ATTEMPT (#658).

  ## Why this exists alongside `ArticleAccessEvent`

  `ArticleAccessEvent` records one row per SURFACED RESULT. That is the right shape for
  "which articles do agents actually read", and the wrong shape for "which searches
  failed", because a search with no results surfaces nothing and therefore writes nothing.
  `Loopctl.Knowledge.maybe_record_search_access/5` makes that explicit — it returns `:ok`
  early when `results in [nil, []]`.

  The consequence, measured: the two failure modes that matter most were both invisible.
  A hand-mined catalogue of 6,457 Claude session transcripts across two machines found 86
  `knowledge_search` calls rejected before they ran (8% of every search made) and a silent
  degradation path where an embedding timeout returns HTTP 200 with an empty result array.
  Neither is recoverable from the database. An analysis that needs someone to grep six
  thousand transcripts is an analysis nobody runs twice.

  This table makes the ATTEMPT the unit of record, so a miss is a row.

  ## Outcomes

  - `"ok"` — results returned on the requested path
  - `"zero_results"` — ran normally, matched nothing. The signal the corpus or the query
    needs work, and the one thing the old schema could never express.
  - `"degraded"` — ran, but not on the requested path: semantic ranking was unavailable and
    it fell back to keyword-only. `fallback_reason` names why. A degraded search that also
    returned nothing is recorded as `"degraded"`, because the cause is the degradation and
    counting it as `zero_results` would blame the corpus for a provider outage.
  - `"rejected"` — never ran: a validation failure (a missing query, a malformed id).
    `rejection_reason` carries the code.

  ## Recording is best-effort and MUST NOT fail a search

  A telemetry write that can break the read path is a worse defect than the blindness it
  cures, so the recorder swallows its own errors. The trade is deliberate: an occasional
  lost row is acceptable, a failed search is not.
  """
  use Loopctl.Schema
  import Ecto.Changeset

  @outcomes ~w(ok zero_results degraded rejected)

  schema "search_events" do
    field :tenant_id, :binary_id
    field :search_id, :binary_id
    field :api_key_id, :binary_id
    field :agent_id, :binary_id
    field :project_id, :binary_id
    field :story_id, :binary_id

    field :query, :string
    field :query_terms, :integer

    field :tool, :string
    field :mode_requested, :string
    field :mode_used, :string

    # The corpus slice actually queried. tenant_id says WHICH KB; these say which PART.
    field :filters, :map, default: %{}
    field :limit_requested, :integer
    field :offset_requested, :integer

    field :total_count, :integer
    field :top_result_id, :binary_id
    field :top_result_score, :float

    field :result_count, :integer, default: 0
    field :degraded, :boolean, default: false
    field :fallback_reason, :string
    field :ann_iterative_scan, :string
    field :duration_ms, :integer

    # Client-supplied context — UNTRUSTED, analytics only, never authorization. See the
    # migration for why none of it is derivable server-side.
    field :client_session_id, :string
    field :client_effort, :string
    field :client_model, :string
    field :client_host, :string
    field :client_repo, :string
    field :client_entrypoint, :string
    field :client_subagent, :boolean
    field :client_version, :string

    field :outcome, :string
    field :rejection_reason, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @castable ~w(search_id api_key_id agent_id project_id story_id query query_terms tool
               mode_requested mode_used filters limit_requested offset_requested
               total_count top_result_id top_result_score result_count degraded
               fallback_reason ann_iterative_scan duration_ms outcome rejection_reason
               client_session_id client_effort client_model client_host client_repo
               client_entrypoint client_subagent client_version)a

  @doc """
  Builds an insert changeset. `tenant_id` is set programmatically by the caller and is
  deliberately NOT castable (multi-tenancy rule 4).
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> validate_required([:outcome])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:result_count, greater_than_or_equal_to: 0)
  end

  @doc "The valid `outcome` values."
  def outcomes, do: @outcomes

  @doc """
  Derives the outcome from a search's shape.

  DEGRADATION OUTRANKS EMPTINESS. A degraded search that returned nothing is `"degraded"`,
  not `"zero_results"` — the cause is a provider failure, and filing it under
  `zero_results` would read as a corpus gap and send the next investigation after the
  wrong thing. That misattribution is exactly what cost this investigation its first hour.
  """
  def derive_outcome(%{rejected?: true}), do: "rejected"
  def derive_outcome(%{degraded?: true}), do: "degraded"
  def derive_outcome(%{result_count: 0}), do: "zero_results"
  def derive_outcome(_), do: "ok"

  @doc """
  Counts whitespace-separated terms in a query, for query-shape analysis.

  Returns nil for a nil/blank query (enumeration mode has none), so "no query" and
  "one-word query" stay distinguishable — they are different defects.
  """
  def term_count(nil), do: nil

  def term_count(query) when is_binary(query) do
    case String.split(query, ~r/\s+/, trim: true) do
      [] -> nil
      terms -> length(terms)
    end
  end

  def term_count(_), do: nil
end
