defmodule LoopctlWeb.UiTestController do
  @moduledoc """
  Controller for project-level UI test run management.

  - `POST   /api/v1/projects/:project_id/ui-tests`              -- Start a run
  - `GET    /api/v1/projects/:project_id/ui-tests`              -- List runs
  - `GET    /api/v1/projects/:project_id/ui-tests/:id`          -- Get run
  - `POST   /api/v1/projects/:project_id/ui-tests/:id/findings` -- Add a finding
  - `POST   /api/v1/projects/:project_id/ui-tests/:id/complete` -- Complete the run

  All actions require the `agent` role or above.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.QualityAssurance
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:create, :index, :show, :add_finding, :complete]

  tags(["UI Tests"])

  operation(:create,
    summary: "Start a UI test run",
    description: "Creates a new UI test run for a project with status in_progress.",
    parameters: [
      project_id: [in: :path, type: :string, description: "Project UUID"]
    ],
    request_body: {"Start UI test params", "application/json", Schemas.StartUiTestRequest},
    responses: %{
      201 =>
        {"UI test run created", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List UI test runs",
    description: "Lists all UI test runs for a project with optional status filter.",
    parameters: [
      project_id: [in: :path, type: :string, description: "Project UUID"],
      status: [
        in: :query,
        type: :string,
        description: "Filter by status",
        required: false
      ],
      limit: [in: :query, type: :integer, description: "Max results (default 20)"],
      offset: [in: :query, type: :integer, description: "Pagination offset (default 0)"]
    ],
    responses: %{
      200 =>
        {"UI test run list", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:show,
    summary: "Get a UI test run",
    description: "Returns a single UI test run with all findings.",
    parameters: [
      project_id: [in: :path, type: :string, description: "Project UUID"],
      id: [in: :path, type: :string, description: "UI test run UUID"]
    ],
    responses: %{
      200 =>
        {"UI test run", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:add_finding,
    summary: "Add a finding to a UI test run",
    description: "Appends a structured finding to an in-progress run.",
    parameters: [
      project_id: [in: :path, type: :string, description: "Project UUID"],
      id: [in: :path, type: :string, description: "UI test run UUID"]
    ],
    request_body: {"Finding params", "application/json", Schemas.UiTestFindingRequest},
    responses: %{
      200 =>
        {"Run updated with finding", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Run not in progress", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:complete,
    summary: "Complete a UI test run",
    description: "Marks the run as passed or failed and records a summary.",
    parameters: [
      project_id: [in: :path, type: :string, description: "Project UUID"],
      id: [in: :path, type: :string, description: "UI test run UUID"]
    ],
    request_body: {"Complete run params", "application/json", Schemas.CompleteUiTestRequest},
    responses: %{
      200 =>
        {"Run completed", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Run not in progress or validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/projects/:project_id/ui-tests

  Starts a new UI test run for the project.
  """
  def create(conn, %{"project_id" => project_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    run_params = Map.take(params, ["guide_reference"])

    opts = Keyword.merge(audit_opts, agent_id: api_key.agent_id)

    case QualityAssurance.start_ui_test(tenant_id, project_id, run_params, opts) do
      {:ok, run} ->
        conn
        |> put_status(:created)
        |> json(%{ui_test_run: run})

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  GET /api/v1/projects/:project_id/ui-tests

  Lists UI test runs for a project with optional status filter and pagination.
  """
  def index(conn, %{"project_id" => project_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:status, params["status"])
      |> maybe_add_opt(:limit, parse_int(params["limit"]))
      |> maybe_add_opt(:offset, parse_int(params["offset"]))

    {:ok, result} = QualityAssurance.list_ui_tests(tenant_id, project_id, opts)

    json(conn, %{
      data: result.data,
      meta: %{
        total: result.total,
        limit: result.limit,
        offset: result.offset
      }
    })
  end

  @doc """
  GET /api/v1/projects/:project_id/ui-tests/:id

  Returns a single UI test run with all findings.
  """
  def show(conn, %{"project_id" => _project_id, "id" => run_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, run} <- QualityAssurance.get_ui_test(tenant_id, run_id) do
      json(conn, %{ui_test_run: run})
    end
  end

  @doc """
  POST /api/v1/projects/:project_id/ui-tests/:id/findings

  Appends a finding to an in-progress UI test run.
  """
  def add_finding(conn, %{"project_id" => _project_id, "id" => run_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    finding_params =
      Map.take(params, [
        "step",
        "severity",
        "type",
        "description",
        "screenshot_path",
        "console_errors"
      ])

    case QualityAssurance.add_finding(tenant_id, run_id, finding_params) do
      {:ok, run} ->
        json(conn, %{ui_test_run: run})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :run_not_in_progress} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{status: 422, message: "Run is not in progress"}})
    end
  end

  @doc """
  POST /api/v1/projects/:project_id/ui-tests/:id/complete

  Completes a UI test run, setting status to passed or failed.
  """
  def complete(conn, %{"project_id" => _project_id, "id" => run_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    complete_params = Map.take(params, ["status", "summary"])

    case QualityAssurance.complete_ui_test(tenant_id, run_id, complete_params, audit_opts) do
      {:ok, run} ->
        json(conn, %{ui_test_run: run})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :run_not_in_progress} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{status: 422, message: "Run is already completed"}})

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # --- Private helpers ---

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
end
