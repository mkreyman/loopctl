defmodule LoopctlWeb.ChgFindingController do
  @moduledoc """
  The chg feedback loop's findings (Epic 51, US-51.6).

  - `GET /api/v1/chg_findings` lists them. `role: :agent`: a read of what the nightly sweep
    derived from the fleet's own ledger rows, scoped to the key's tenant, and the fleet's
    sessions are the ones that need to ask what the loop is working on.
  - `POST /api/v1/chg_findings/:id/clear` sends an ESCALATED finding round the loop again.
    `role: :user` on a human-anchored tenant: escalation is the loop handing a problem to a
    person, and the loop must not be able to take it back by itself.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Changes.Finding
  alias Loopctl.Changes.Findings
  alias LoopctlWeb.CurrentTenant

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:clear]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:index]
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:clear]

  tags(["chg findings"])

  @state_names Enum.map(Finding.states(), &Atom.to_string/1)
  @list_cap Findings.list_cap()

  @finding_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      kind: %OpenApiSpex.Schema{type: :string, enum: Finding.kinds()},
      fingerprint: %OpenApiSpex.Schema{type: :string},
      repo: %OpenApiSpex.Schema{type: :string},
      state: %OpenApiSpex.Schema{type: :string, enum: @state_names},
      occurrences: %OpenApiSpex.Schema{type: :integer},
      fix_attempts: %OpenApiSpex.Schema{type: :integer},
      loop_depth: %OpenApiSpex.Schema{type: :integer},
      cycle: %OpenApiSpex.Schema{
        type: :integer,
        description: "How many times a person cleared this finding from escalated."
      },
      issue_number: %OpenApiSpex.Schema{type: :integer, nullable: true},
      issue_url: %OpenApiSpex.Schema{type: :string, nullable: true},
      escalated_reason: %OpenApiSpex.Schema{type: :string, nullable: true},
      first_seen_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      last_seen_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      filed_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      fixed_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      closed_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      escalated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true}
    }
  }

  operation(:index,
    summary: "List chg feedback loop findings",
    description:
      "The problems the nightly sweep derived from the chg ledger (US-51.1), newest sighting " <>
        "first. Any authenticated key (agent role and up); scoped to the key's tenant. 422 " <>
        "for an unknown `state` or `kind`, or a `limit` that is not 1..#{@list_cap}.",
    parameters: [
      state: [
        in: :query,
        type: :string,
        required: false,
        description: "One of #{Enum.join(@state_names, ", ")}."
      ],
      kind: [
        in: :query,
        type: :string,
        required: false,
        description: "One of #{Enum.join(Finding.kinds(), ", ")}."
      ],
      repo: [
        in: :query,
        type: :string,
        required: false,
        description: "The repository a finding is filed on (`owner/name`, any case)."
      ],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Default 50, at most #{@list_cap}."
      ]
    ],
    responses: %{
      200 =>
        {"Findings", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{data: %OpenApiSpex.Schema{type: :array, items: @finding_schema}}
         }},
      401 => {"Unauthenticated", "application/json", Schemas.ErrorResponse},
      422 => {"Bad filter", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "GET /api/v1/chg_findings"
  def index(conn, params) do
    with {:ok, tenant_id} <- CurrentTenant.fetch_id(conn),
         {:ok, opts} <- list_opts(params) do
      json(conn, %{data: tenant_id |> Findings.list(opts) |> Enum.map(&finding_json/1)})
    end
  end

  operation(:clear,
    summary: "Clear an escalated chg finding",
    description:
      "Sends an ESCALATED finding back to `queued`: its fix attempts reset, its issue " <>
        "number is dropped, and the next sweep files a fresh issue so the loop tries again. " <>
        "The escalated issue is left open for the person to close. Audited as " <>
        "`chg_finding_cleared`. Needs a `:user` key on a human-anchored tenant (403 " <>
        "`insufficient_role` or `custody_tier_required` otherwise). 404 for no such finding " <>
        "in the tenant; 409 `not_escalated` for a finding in any other state.",
    parameters: [id: [in: :path, type: :string, required: true, description: "The finding id."]],
    responses: %{
      200 =>
        {"Cleared finding", "application/json",
         %OpenApiSpex.Schema{type: :object, properties: %{data: @finding_schema}}},
      401 => {"Unauthenticated", "application/json", Schemas.ErrorResponse},
      403 =>
        {"Not a user key, or tenant not human-anchored", "application/json",
         Schemas.ErrorResponse},
      404 => {"No such finding", "application/json", Schemas.ErrorResponse},
      409 => {"Finding not escalated", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/chg_findings/:id/clear"
  def clear(conn, %{"id" => id}) do
    api_key = conn.assigns.current_api_key
    actor = %{api_key_id: api_key.id, label: LoopctlWeb.ActorLabel.of(api_key)}

    with {:ok, tenant_id} <- CurrentTenant.fetch_id(conn) do
      case Findings.clear(tenant_id, id, actor) do
        {:ok, finding} ->
          json(conn, %{data: finding_json(finding)})

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, :not_escalated} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error: %{
              status: 409,
              code: "not_escalated",
              message: "Only an escalated finding can be cleared."
            }
          })
      end
    end
  end

  @doc false
  # Public for the controller test; the parsing has no other caller.
  @spec list_opts(map()) :: {:ok, keyword()} | {:error, :unprocessable_entity, String.t()}
  def list_opts(params) do
    with {:ok, state} <- state_opt(params["state"]),
         {:ok, kind} <- kind_opt(params["kind"]),
         {:ok, limit} <- limit_opt(params["limit"]) do
      {:ok, [state: state, kind: kind, repo: text(params["repo"]), limit: limit]}
    end
  end

  defp state_opt(blank) when blank in [nil, ""], do: {:ok, nil}

  defp state_opt(raw) do
    case Enum.find(Finding.states(), &(Atom.to_string(&1) == raw)) do
      nil ->
        {:error, :unprocessable_entity, "state must be one of #{Enum.join(@state_names, ", ")}"}

      state ->
        {:ok, state}
    end
  end

  defp kind_opt(blank) when blank in [nil, ""], do: {:ok, nil}

  defp kind_opt(raw) do
    if raw in Finding.kinds(),
      do: {:ok, raw},
      else:
        {:error, :unprocessable_entity, "kind must be one of #{Enum.join(Finding.kinds(), ", ")}"}
  end

  defp limit_opt(blank) when blank in [nil, ""], do: {:ok, 50}

  defp limit_opt(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n in 1..@list_cap -> {:ok, n}
      _ -> {:error, :unprocessable_entity, "limit must be an integer from 1 to #{@list_cap}"}
    end
  end

  defp text(value) when is_binary(value) and value != "", do: String.slice(value, 0, 200)
  defp text(_), do: nil

  defp finding_json(%Finding{} = f) do
    %{
      id: f.id,
      kind: f.kind,
      fingerprint: f.fingerprint,
      repo: f.repo_full_name,
      state: f.state,
      occurrences: f.occurrences,
      fix_attempts: f.fix_attempts,
      loop_depth: f.loop_depth,
      cycle: f.cycle,
      issue_number: f.issue_number,
      issue_url: issue_url(f),
      escalated_reason: f.escalated_reason,
      first_seen_at: f.first_seen_at,
      last_seen_at: f.last_seen_at,
      filed_at: f.filed_at,
      fixed_at: f.fixed_at,
      closed_at: f.closed_at,
      escalated_at: f.escalated_at
    }
  end

  defp issue_url(%Finding{issue_number: nil}), do: nil

  defp issue_url(%Finding{repo_full_name: repo, issue_number: n}),
    do: "https://github.com/#{repo}/issues/#{n}"
end
