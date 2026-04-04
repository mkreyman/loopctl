defmodule LoopctlWeb.TokenBudgetController do
  @moduledoc """
  Controller for token budget configuration.

  - `POST /api/v1/token-budgets` -- create a budget (user+)
  - `GET /api/v1/token-budgets` -- list budgets for tenant (agent+)
  - `GET /api/v1/token-budgets/:id` -- get a single budget (agent+)
  - `PATCH /api/v1/token-budgets/:id` -- update a budget (user+)
  - `DELETE /api/v1/token-budgets/:id` -- delete a budget (user+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Formatting
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:create, :update, :delete]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:index, :show]

  tags(["Token Efficiency"])

  operation(:create,
    summary: "Create token budget",
    description:
      "Creates a budget for a project, epic, or story scope. " <>
        "Only one budget per (scope_type, scope_id) pair is allowed.",
    request_body:
      {"Token budget params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:scope_type, :scope_id, :budget_millicents],
         properties: %{
           scope_type: %OpenApiSpex.Schema{
             type: :string,
             enum: ["project", "epic", "story"]
           },
           scope_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           budget_millicents: %OpenApiSpex.Schema{type: :integer, minimum: 1},
           budget_input_tokens: %OpenApiSpex.Schema{
             type: :integer,
             minimum: 0,
             nullable: true
           },
           budget_output_tokens: %OpenApiSpex.Schema{
             type: :integer,
             minimum: 0,
             nullable: true
           },
           alert_threshold_pct: %OpenApiSpex.Schema{
             type: :integer,
             minimum: 1,
             maximum: 100,
             default: 80
           },
           metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      201 =>
        {"Budget created", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             token_budget: Schemas.TokenBudget
           }
         }},
      404 => {"Scope entity not found", "application/json", Schemas.ErrorResponse},
      409 => {"Budget already exists for scope", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List token budgets",
    description:
      "Returns all token budgets for the tenant. Filterable by scope_type and scope_id. " <>
        "Includes current spend and remaining budget for each entry.",
    parameters: [
      scope_type: [
        in: :query,
        type: :string,
        description: "Filter by scope type: project, epic, story"
      ],
      scope_id: [in: :query, type: :string, description: "Filter by scope UUID"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Budget list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: Schemas.TokenBudget
             },
             meta: Schemas.PaginationMeta
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:show,
    summary: "Get token budget",
    description:
      "Returns a single token budget with current spend and remaining calculated in real-time.",
    parameters: [
      id: [in: :path, type: :string, description: "Budget UUID"]
    ],
    responses: %{
      200 =>
        {"Budget details", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             token_budget: Schemas.TokenBudget
           }
         }},
      404 => {"Budget not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Update token budget",
    description:
      "Updates budget_millicents, token limits, or alert_threshold_pct. " <>
        "Cannot change scope_type or scope_id.",
    parameters: [
      id: [in: :path, type: :string, description: "Budget UUID"]
    ],
    request_body:
      {"Token budget update params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           budget_millicents: %OpenApiSpex.Schema{type: :integer, minimum: 1},
           budget_input_tokens: %OpenApiSpex.Schema{
             type: :integer,
             minimum: 0,
             nullable: true
           },
           budget_output_tokens: %OpenApiSpex.Schema{
             type: :integer,
             minimum: 0,
             nullable: true
           },
           alert_threshold_pct: %OpenApiSpex.Schema{
             type: :integer,
             minimum: 1,
             maximum: 100
           },
           metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      200 =>
        {"Budget updated", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             token_budget: Schemas.TokenBudget
           }
         }},
      404 => {"Budget not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Delete token budget",
    description: "Deletes a token budget. Does not delete associated token usage reports.",
    parameters: [
      id: [in: :path, type: :string, description: "Budget UUID"]
    ],
    responses: %{
      200 =>
        {"Budget deleted", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           description: "Confirmation of deletion",
           properties: %{
             token_budget: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 id: %OpenApiSpex.Schema{type: :string, format: :uuid},
                 deleted: %OpenApiSpex.Schema{type: :boolean, example: true}
               }
             }
           }
         }},
      404 => {"Budget not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/token-budgets

  Creates a token budget for a project, epic, or story scope.
  """
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    case TokenUsage.create_budget(tenant_id, params, audit_opts) do
      {:ok, budget} ->
        spend = TokenUsage.get_scope_spend(tenant_id, budget.scope_type, budget.scope_id)

        conn
        |> put_status(:created)
        |> json(%{token_budget: format_budget_with_spend(budget, spend)})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :conflict} ->
        {:error, :conflict}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  GET /api/v1/token-budgets

  Lists all token budgets for the tenant with filtering and pagination.
  """
  def index(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:scope_type, params["scope_type"])
      |> maybe_add_opt(:scope_id, params["scope_id"])
      |> maybe_add_opt(:page, parse_int(params["page"]))
      |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

    {:ok, result} = TokenUsage.list_budgets(tenant_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &format_budget_entry/1),
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  @doc """
  GET /api/v1/token-budgets/:id

  Returns a single budget with current spend and remaining.
  """
  def show(conn, %{"id" => id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, budget} <- TokenUsage.get_budget(tenant_id, id) do
      spend = TokenUsage.get_scope_spend(tenant_id, budget.scope_type, budget.scope_id)

      json(conn, %{token_budget: format_budget_with_spend(budget, spend)})
    end
  end

  @doc """
  PATCH /api/v1/token-budgets/:id

  Updates budget amounts and thresholds. Cannot change scope.
  """
  def update(conn, %{"id" => id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    # Strip the id from params so it's not passed as an attr
    attrs = Map.delete(params, "id")

    with {:ok, budget} <- TokenUsage.update_budget(tenant_id, id, attrs, audit_opts) do
      spend = TokenUsage.get_scope_spend(tenant_id, budget.scope_type, budget.scope_id)

      json(conn, %{token_budget: format_budget_with_spend(budget, spend)})
    end
  end

  @doc """
  DELETE /api/v1/token-budgets/:id

  Deletes a budget. Does not delete associated token usage reports.
  """
  def delete(conn, %{"id" => id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, budget} <- TokenUsage.delete_budget(tenant_id, id, audit_opts) do
      json(conn, %{
        token_budget: %{
          id: budget.id,
          deleted: true
        }
      })
    end
  end

  # --- Private helpers ---

  defp format_budget_with_spend(budget, spend) do
    remaining = max(budget.budget_millicents - spend, 0)

    %{
      id: budget.id,
      tenant_id: budget.tenant_id,
      scope_type: budget.scope_type,
      scope_id: budget.scope_id,
      budget_millicents: budget.budget_millicents,
      budget_dollars: Formatting.millicents_to_dollars(budget.budget_millicents),
      budget_input_tokens: budget.budget_input_tokens,
      budget_output_tokens: budget.budget_output_tokens,
      alert_threshold_pct: budget.alert_threshold_pct,
      current_spend_millicents: spend,
      current_spend_dollars: Formatting.millicents_to_dollars(spend),
      remaining_millicents: remaining,
      remaining_dollars: Formatting.millicents_to_dollars(remaining),
      metadata: budget.metadata,
      inserted_at: budget.inserted_at,
      updated_at: budget.updated_at
    }
  end

  defp format_budget_entry(%{budget: budget, current_spend_millicents: spend}) do
    format_budget_with_spend(budget, spend)
  end

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
