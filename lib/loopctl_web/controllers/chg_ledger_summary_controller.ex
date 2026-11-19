defmodule LoopctlWeb.ChgLedgerSummaryController do
  @moduledoc """
  `GET /api/v1/chg_ledger/summary` (Epic 50, US-50.6): the chg audit questions the `/chg`
  dashboard answers, for a session that has no browser. Every panel is computed by
  `Loopctl.Changes.Dashboard.summary/2`, the function set `LoopctlWeb.ChgLive` renders, so
  the API and the page cannot disagree.

  ## Why `role: :agent`

  It is a READ of counts, timings and identifiers the fleet's own chg outboxes sent, scoped
  to the caller's tenant by its key. Nothing here is a custody decision, and the fleet's
  sessions (agent keys) are the ones that need to ask how the gate is doing.

  ## The period cap

  One call covers at most `Loopctl.Changes.Dashboard.max_period_days/0` days, so a request
  never aggregates an unbounded slice of the ledger on the heavy-read pool. A wider period is
  a 422 naming the cap, never a silently shortened answer.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Changes.Dashboard
  alias LoopctlWeb.CurrentTenant

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show]

  tags(["chg ledger"])

  @max_period_days Dashboard.max_period_days()
  @default_period_days 7

  @panel_description "A panel's data, or the string `unavailable` when its read was shed " <>
                       "under load (retry later); the other panels are unaffected."

  operation(:show,
    summary: "The chg ledger summary",
    description:
      "The aggregates the /chg dashboard shows (US-50.6), from the chg ledger rows the " <>
        "fleet's outboxes sent: gate outcomes per day and kind, the fallback rate and its " <>
        "reasons, selection quality and misses (a chg check that passed on a commit whose " <>
        "gate failed its tests; the pre-push hook's own decision is not a gate verdict), " <>
        "time per gate phase, flaky tests, runner samples, merged-PR review " <>
        "outcomes, and changes the reconcile sweep flagged gap or stale. Lists are capped at " <>
        "#{Dashboard.list_limit()} rows. Any authenticated key (agent role and up); scoped " <>
        "to the key's tenant. 422 when `since`/`until` is not an ISO 8601 timestamp, when " <>
        "`since` is not before `until`, or when the period exceeds #{@max_period_days} days.",
    parameters: [
      repo: [
        in: :query,
        type: :string,
        required: false,
        description: "Only this repository (`owner/name`, any case)."
      ],
      host: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Only rows from this fleet host. Applies to ledger panels; review outcomes and " <>
            "flagged changes carry no host and ignore it."
      ],
      since: [
        in: :query,
        type: :string,
        required: false,
        description:
          "ISO 8601 start, inclusive. Default: #{@default_period_days} days before `until`."
      ],
      until: [
        in: :query,
        type: :string,
        required: false,
        description:
          "ISO 8601 end, exclusive. Default: now. At most #{@max_period_days} days after " <>
            "`since`."
      ]
    ],
    responses: %{
      200 =>
        {"Ledger summary", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 filters: %OpenApiSpex.Schema{
                   type: :object,
                   properties: %{
                     repo: %OpenApiSpex.Schema{type: :string, nullable: true},
                     host: %OpenApiSpex.Schema{type: :string, nullable: true},
                     since: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
                     until: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
                   }
                 },
                 gate_outcomes: %OpenApiSpex.Schema{
                   description:
                     "Per day and kind (`chg`, `gate`): counts per verdict (pass, fail, " <>
                       "error, skipped) and total. " <> @panel_description
                 },
                 fallbacks: %OpenApiSpex.Schema{
                   description:
                     "Checks that ran mode `all`: count, of total, rate, and the top " <>
                       "selection reasons. " <> @panel_description
                 },
                 selection: %OpenApiSpex.Schema{
                   description:
                     "Selection stats (checks, mean and max selected, mean floor) and misses. " <>
                       @panel_description
                 },
                 phase_times: %OpenApiSpex.Schema{
                   description:
                     "Per gate phase (hydrate, static, affected, tests, lock_wait): rows, " <>
                       "mean ms, max ms. " <> @panel_description
                 },
                 flaky: %OpenApiSpex.Schema{description: @panel_description},
                 runner_samples: %OpenApiSpex.Schema{description: @panel_description},
                 review_outcomes: %OpenApiSpex.Schema{
                   description:
                     "Merged PRs' review findings by severity and disposition, and the count " <>
                       "merged without a counted review round, totalled over every merged PR " <>
                       "in the period; `outcomes` lists the newest of them. " <>
                       @panel_description
                 },
                 attention: %OpenApiSpex.Schema{
                   description:
                     "Changes flagged gap or stale and still flagged. Current state: `since` " <>
                       "and `until` do not apply. " <> @panel_description
                 },
                 findings: %OpenApiSpex.Schema{
                   description:
                     "The feedback loop's findings (US-51.6): `by_state` and `by_kind` " <>
                       "counts and the `escalated` ones, newest first. Current state: " <>
                       "`since`, `until` and `host` do not apply; `repo` does. " <>
                       @panel_description
                 }
               }
             }
           }
         }},
      401 => {"Unauthenticated", "application/json", Schemas.ErrorResponse},
      422 => {"Bad timestamp or period", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/chg_ledger/summary"
  def show(conn, params) do
    with {:ok, tenant_id} <- CurrentTenant.fetch_id(conn),
         {:ok, filters} <- filters(params, DateTime.utc_now()) do
      summary = tenant_id |> Dashboard.summary(filters) |> wire()
      json(conn, %{data: Map.put(summary, :filters, filters)})
    end
  end

  @doc false
  # The one shape change between the page and the wire: a runner sample's `fields` is a sorted
  # list of `{key, value}` pairs for display, and JSON has no pairs, so it goes out as an object.
  @spec wire(map()) :: map()
  def wire(%{runner_samples: samples} = summary) when is_list(samples) do
    %{summary | runner_samples: Enum.map(samples, &%{&1 | fields: Map.new(&1.fields)})}
  end

  def wire(summary), do: summary

  @doc false
  # Public for the controller test's cap boundary; the parsing has no other caller.
  @spec filters(map(), DateTime.t()) :: {:ok, map()} | {:error, :unprocessable_entity, String.t()}
  def filters(params, now) do
    with {:ok, until} <- timestamp(params["until"], "until", now),
         {:ok, since} <-
           timestamp(params["since"], "since", DateTime.add(until, -@default_period_days, :day)),
         :ok <- period_ok(since, until) do
      {:ok, %{repo: text(params["repo"]), host: text(params["host"]), since: since, until: until}}
    end
  end

  defp timestamp(nil, _name, default), do: {:ok, default}
  defp timestamp("", _name, default), do: {:ok, default}

  defp timestamp(raw, name, _default) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _} -> {:error, :unprocessable_entity, "#{name} must be an ISO 8601 timestamp"}
    end
  end

  defp timestamp(_other, name, _default),
    do: {:error, :unprocessable_entity, "#{name} must be an ISO 8601 timestamp"}

  defp period_ok(since, until) do
    cond do
      DateTime.compare(since, until) != :lt ->
        {:error, :unprocessable_entity, "since must be before until"}

      DateTime.diff(until, since, :second) > @max_period_days * 86_400 ->
        {:error, :unprocessable_entity,
         "the period may be at most #{@max_period_days} days (since to until)"}

      true ->
        :ok
    end
  end

  defp text(value) when is_binary(value) and value != "", do: String.slice(value, 0, 200)
  defp text(_), do: nil
end
