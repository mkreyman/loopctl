defmodule LoopctlWeb.AgentOutcomeController do
  @moduledoc """
  `GET /api/v1/agent_specs/:spec_id/outcomes` (Epic 48, US-48.12): an agent spec's track
  record from the run-outcome ledger — per version, the runs in a window and how many
  succeeded, were overridden by a human, or ran out of budget, with the median elapsed time
  and turns. `Loopctl.Agents.Outcomes.summary/3` computes it.

  ## Why `role: :agent`

  It is a READ of counts, rates and enums loopctl recorded from its own events — no session
  text, no ticket text, nothing a custody gate decides on — scoped to the caller's tenant by
  its key. Any role's key may read it, so the improvement loop (US-48.13) and an orchestrator
  on an agent key can both ask how a spec is doing.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.Agents.Outcomes
  alias Loopctl.ApiSpec.Schemas
  alias LoopctlWeb.CurrentTenant

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:summary]

  tags(["Agent specs"])

  # The format a spec module gives its id, bounded. A function, not an attribute: an
  # OTP 28 regex cannot be escaped into a module attribute.
  defp spec_id_format, do: ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @max_window_days Outcomes.max_window_days()

  @version_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      spec_version: %OpenApiSpex.Schema{type: :integer, minimum: 1},
      runs: %OpenApiSpex.Schema{
        type: :integer,
        description: "Dispatches of this version first recorded in the window."
      },
      ended: %OpenApiSpex.Schema{
        type: :integer,
        description: "Of those, the ones whose session end was recorded."
      },
      successes: %OpenApiSpex.Schema{
        type: :integer,
        description:
          "A build run whose work merged; a judge run whose verdict no human overrode; a " <>
            "draft run whose draft was stored `drafted`."
      },
      human_overrides: %OpenApiSpex.Schema{
        type: :integer,
        description:
          "Runs a human overrode: a triage verdict resolved to another route, or re-triaged."
      },
      budget_exhausted: %OpenApiSpex.Schema{
        type: :integer,
        description: "Runs whose session ended `wall_clock_exceeded` or `max_turns_exceeded`."
      },
      success_rate: %OpenApiSpex.Schema{type: :number, description: "successes / runs."},
      human_override_rate: %OpenApiSpex.Schema{type: :number},
      budget_exhausted_rate: %OpenApiSpex.Schema{type: :number},
      median_elapsed_s: %OpenApiSpex.Schema{
        type: :number,
        nullable: true,
        description: "Median session seconds, accepted to ended; null when no run ended."
      },
      median_turns: %OpenApiSpex.Schema{
        type: :number,
        nullable: true,
        description: "Median turns; null while no runner message reports turns."
      }
    }
  }

  operation(:summary,
    summary: "An agent spec's outcomes per version",
    description:
      "The run-outcome ledger's summary for one agent spec (US-48.12): per spec version, " <>
        "newest first, how many dispatches were recorded in the window and how many " <>
        "succeeded, were overridden by a human, or exhausted their budget, with the median " <>
        "elapsed seconds and turns. Every figure comes from an event loopctl recorded — a " <>
        "session end, a verdict, a merge-gate decision, a merge, a review, a human's " <>
        "resolution — never from session text. A spec with no runs in the window answers " <>
        "`versions: []`. Any authenticated key (agent role and up); scoped to the key's " <>
        "tenant. 400 for a malformed `spec_id` or a `window_days` outside 1..#{Outcomes.max_window_days()}.",
    parameters: [
      spec_id: [
        in: :path,
        type: :string,
        required: true,
        description: "The spec's id, e.g. `triage`, `implement`, `reply_draft`."
      ],
      window_days: [
        in: :query,
        type: :integer,
        required: false,
        description:
          "The window, in days back from now. Default #{Outcomes.default_window_days()}, " <>
            "at most #{Outcomes.max_window_days()}."
      ]
    ],
    responses: %{
      200 =>
        {"Outcome summary", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 spec_id: %OpenApiSpex.Schema{type: :string},
                 window_days: %OpenApiSpex.Schema{type: :integer},
                 since: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
                 until: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
                 versions: %OpenApiSpex.Schema{type: :array, items: @version_schema}
               }
             }
           }
         }},
      400 => {"Bad spec_id or window_days", "application/json", Schemas.ErrorResponse},
      401 => {"Unauthenticated", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/agent_specs/:spec_id/outcomes"
  def summary(conn, %{"spec_id" => spec_id} = params) do
    with {:ok, tenant_id} <- CurrentTenant.fetch_id(conn),
         :ok <- spec_id_ok(spec_id),
         {:ok, days} <- window_days(params["window_days"]),
         {:ok, summary} <- summarise(tenant_id, spec_id, days) do
      json(conn, %{data: summary})
    end
  end

  defp spec_id_ok(spec_id) do
    if Regex.match?(spec_id_format(), spec_id),
      do: :ok,
      else: {:error, :bad_request, "spec_id must be a spec id (lower-case, e.g. `triage`)"}
  end

  defp window_days(nil), do: {:ok, Outcomes.default_window_days()}
  defp window_days(""), do: {:ok, Outcomes.default_window_days()}

  defp window_days(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n in 1..@max_window_days//1 -> {:ok, n}
      _ -> window_error()
    end
  end

  defp window_days(_other), do: window_error()

  defp window_error,
    do:
      {:error, :bad_request,
       "window_days must be an integer from 1 to #{Outcomes.max_window_days()}"}

  defp summarise(tenant_id, spec_id, days) do
    case Outcomes.summary(tenant_id, spec_id, window_days: days) do
      {:ok, summary} -> {:ok, summary}
      {:error, :invalid_window} -> window_error()
    end
  end
end
