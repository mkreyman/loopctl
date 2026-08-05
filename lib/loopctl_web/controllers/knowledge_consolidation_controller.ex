defmodule LoopctlWeb.KnowledgeConsolidationController do
  @moduledoc """
  Read surface for the nightly consolidation ("dream") pass — #584 stage 1.

  - `GET /api/v1/knowledge/consolidation` — the tenant's most recent consolidation
    report and its numbered proposals (orchestrator+)

  This endpoint READS persisted rows only. It never runs the pass: consolidation is a
  whole-corpus job and belongs in the nightly worker, not in a request path. Stage 1
  applies nothing — every proposal is `pending`, and there is no endpoint here that
  could approve or apply one.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.Knowledge.ConsolidationProposal

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  @classes Enum.map(ConsolidationProposal.classes(), &to_string/1)
  @max_limit Consolidation.hard_max_per_class()

  tags(["Knowledge Wiki"])

  operation(:show,
    summary: "Nightly consolidation report",
    description:
      "The tenant's most recent nightly consolidation (\"dream\") report and its NUMBERED " <>
        "proposals, each naming the articles involved and quoting an excerpt " <>
        "(#{Consolidation.excerpt_chars()} characters) from each as evidence. " <>
        "REPORT ONLY (#584 stage 1): the pass writes no articles, links or conflict " <>
        "resolutions, every proposal is `pending`, and nothing here applies one. " <>
        "Read-only; returns persisted rows and never recomputes. Role: orchestrator+.\n\n" <>
        "CLASSES — `duplicate_capture` (titles that collide once case/punctuation are " <>
        "normalized away, or idempotency keys that collide under the same normalization " <>
        "while differing verbatim: capture tag-format drift, which the novelty gate does " <>
        "not catch because novelty scoring and idempotency are separate paths); " <>
        "`contradiction_candidate` (RETIRED as of #605 and no longer produced — the nightly " <>
        "lint now judges those pairs automatically; historical reports may still carry the " <>
        "class); " <>
        "`generic_title` (a placeholder title that collides on active-title uniqueness " <>
        "and blocks hub creation); `stale_entry` (past the lint staleness threshold and " <>
        "never reconciled).\n\n" <>
        "DENOMINATORS — `report.corpus_size` counts PUBLISHED articles owned by this " <>
        "tenant at scan time, not its total article count. `report.proposal_count` is the " <>
        "TRUE pre-cap count of PROPOSALS, not of articles: one duplicate group of three " <>
        "articles is ONE proposal, and one article can appear in proposals of several " <>
        "classes. `report.persisted_count` is how many proposal ROWS the report carries " <>
        "— lower than `proposal_count` exactly when a class hit `report.max_per_class`, " <>
        "which `report.truncated` flags per class. `meta.total_count` is the number of " <>
        "persisted proposals matching the `class` filter, so it is bounded by " <>
        "`persisted_count`, never by `proposal_count`.\n\n" <>
        "REVIEW STATE — `review_status` / `reviewed_by` / `reviewed_at` are reset to " <>
        "`pending` / null whenever the nightly pass re-derives a proposal: refreshed " <>
        "machine output must earn review again and never inherits an earlier approval.\n\n" <>
        "EVIDENCE FRESHNESS — each evidence entry is a COPY taken when the proposal was " <>
        "derived, and it is re-checked against the live published corpus on every read. " <>
        "If the article has since been hard-deleted, archived or unpublished, the entry " <>
        "comes back as `article_id` with a null title, an empty excerpt and " <>
        "`redacted: true` — a quoted excerpt never outlives the article it quotes, " <>
        "including in prior-day reports read via `day`.",
    parameters: [
      day: [
        in: :query,
        type: :string,
        description:
          "ISO8601 date (UTC) of the report to read. Defaults to the tenant's most recent report.",
        required: false
      ],
      class: [
        in: :query,
        type: :string,
        description: "Filter proposals by class (#{Enum.join(@classes, " | ")}).",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description:
          "Proposals per page (default 50, max #{@max_limit}). Clamped, never rejected.",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description:
          "Proposals to skip (default 0, max #{Consolidation.max_offset()}). " <>
            "Clamped, never rejected.",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Consolidation report", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/consolidation"
  def show(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, opts} <- parse_params(params),
         {:ok, result} <- Consolidation.latest(tenant_id, opts) do
      json(conn, LoopctlWeb.KnowledgeConsolidationJSON.show(result))
    end
  end

  defp parse_params(params) do
    with {:ok, opts} <- parse_day(params, []),
         {:ok, opts} <- parse_class(params, opts) do
      {:ok,
       opts
       |> put_int(:limit, params["limit"], 50)
       |> put_int(:offset, params["offset"], 0)}
    end
  end

  defp parse_day(%{"day" => raw}, opts) when is_binary(raw) and raw != "" do
    case Date.from_iso8601(raw) do
      {:ok, day} -> {:ok, Keyword.put(opts, :day, day)}
      {:error, _} -> {:error, :bad_request, "day must be an ISO8601 date (YYYY-MM-DD)"}
    end
  end

  defp parse_day(_params, opts), do: {:ok, opts}

  defp parse_class(%{"class" => raw}, opts) when is_binary(raw) and raw != "" do
    if raw in @classes do
      {:ok, Keyword.put(opts, :class, String.to_existing_atom(raw))}
    else
      {:error, :bad_request, "class must be one of: #{Enum.join(@classes, ", ")}"}
    end
  end

  defp parse_class(_params, opts), do: {:ok, opts}

  # Clamped, never rejected — mirrors the other knowledge analytics readers.
  defp put_int(opts, key, raw, default) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> Keyword.put(opts, key, n)
      _ -> Keyword.put(opts, key, default)
    end
  end

  defp put_int(opts, key, raw, _default) when is_integer(raw), do: Keyword.put(opts, key, raw)
  defp put_int(opts, key, _raw, default), do: Keyword.put(opts, key, default)
end
