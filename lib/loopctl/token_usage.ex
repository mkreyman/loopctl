defmodule Loopctl.TokenUsage do
  @moduledoc """
  Context module for token usage reporting.

  Provides functions to create and query token usage reports.
  All functions take `tenant_id` as the first argument for multi-tenant
  scoping.

  ## Usage

  ### Creating a report

      Loopctl.TokenUsage.create_report(tenant_id, %{
        story_id: story_id,
        agent_id: agent_id,
        project_id: project_id,
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500,
        phase: "implementing"
      })

  ### Listing reports for a story

      Loopctl.TokenUsage.list_reports_for_story(tenant_id, story_id)

  ### Getting totals for a story

      Loopctl.TokenUsage.get_story_totals(tenant_id, story_id)
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.TokenUsage.Report

  @doc """
  Creates a new token usage report.

  The `attrs` map must include: `story_id`, `agent_id`, `project_id`,
  `input_tokens`, `output_tokens`, `model_name`, `cost_millicents`.

  Optional: `phase`, `session_id`, `skill_version_id`, `metadata`.

  The `tenant_id`, `agent_id`, `project_id`, and `story_id` are set
  programmatically on the struct (not via cast).

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  ## Returns

  - `{:ok, %Report{}}` on success
  - `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec create_report(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def create_report(tenant_id, attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)

    story_id = Map.get(attrs, :story_id)
    agent_id = Map.get(attrs, :agent_id)
    project_id = Map.get(attrs, :project_id)
    skill_version_id = Map.get(attrs, :skill_version_id)

    changeset =
      %Report{
        tenant_id: tenant_id,
        story_id: story_id,
        agent_id: agent_id,
        project_id: project_id
      }
      |> Report.create_changeset(maybe_put_skill_version(attrs, skill_version_id))

    case AdminRepo.insert(changeset) do
      {:ok, report} ->
        # Audit log the creation
        Audit.create_log_entry(tenant_id, %{
          entity_type: "token_usage_report",
          entity_id: report.id,
          action: "created",
          actor_type: Keyword.get(opts, :actor_type, "api_key"),
          actor_id: Keyword.get(opts, :actor_id),
          actor_label: Keyword.get(opts, :actor_label),
          new_state: %{
            "story_id" => report.story_id,
            "agent_id" => report.agent_id,
            "project_id" => report.project_id,
            "input_tokens" => report.input_tokens,
            "output_tokens" => report.output_tokens,
            "model_name" => report.model_name,
            "cost_millicents" => report.cost_millicents,
            "phase" => report.phase
          }
        })

        {:ok, report}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Creates a token usage report within an Ecto.Multi pipeline.

  Used by `Progress.report_story/4` to atomically create a token usage
  report alongside a status transition.

  ## Parameters

  - `multi` -- the Ecto.Multi struct
  - `name` -- the step name in the multi
  - `tenant_id` -- the tenant UUID
  - `attrs` -- map of report attributes (story_id, agent_id, project_id, etc.)

  ## Returns

  The updated Ecto.Multi struct.
  """
  @spec create_report_in_multi(Ecto.Multi.t(), atom(), Ecto.UUID.t(), map()) :: Ecto.Multi.t()
  def create_report_in_multi(multi, name, tenant_id, attrs) do
    attrs = normalize_attrs(attrs)

    story_id = Map.get(attrs, :story_id)
    agent_id = Map.get(attrs, :agent_id)
    project_id = Map.get(attrs, :project_id)
    skill_version_id = Map.get(attrs, :skill_version_id)

    Ecto.Multi.insert(multi, name, fn _changes ->
      %Report{
        tenant_id: tenant_id,
        story_id: story_id,
        agent_id: agent_id,
        project_id: project_id
      }
      |> Report.create_changeset(maybe_put_skill_version(attrs, skill_version_id))
    end)
  end

  @doc """
  Lists all token usage reports for a story, ordered by inserted_at descending.

  Includes pagination and total count.

  ## Options

  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%Report{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_reports_for_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Report.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_reports_for_story(tenant_id, story_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Report
      |> where([r], r.tenant_id == ^tenant_id and r.story_id == ^story_id)

    total = AdminRepo.aggregate(base_query, :count, :id)

    reports =
      base_query
      |> order_by([r], desc: r.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: reports, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Returns aggregated token usage totals for a story.

  ## Returns

  `{:ok, %{total_input_tokens: integer, total_output_tokens: integer, total_tokens: integer, total_cost_millicents: integer, report_count: integer}}`
  """
  @spec get_story_totals(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok,
           %{
             total_input_tokens: non_neg_integer(),
             total_output_tokens: non_neg_integer(),
             total_tokens: non_neg_integer(),
             total_cost_millicents: non_neg_integer(),
             report_count: non_neg_integer()
           }}
  def get_story_totals(tenant_id, story_id) do
    query =
      Report
      |> where([r], r.tenant_id == ^tenant_id and r.story_id == ^story_id)
      |> select([r], %{
        total_input_tokens: coalesce(sum(r.input_tokens), 0),
        total_output_tokens: coalesce(sum(r.output_tokens), 0),
        total_tokens: coalesce(sum(r.input_tokens), 0) + coalesce(sum(r.output_tokens), 0),
        total_cost_millicents: coalesce(sum(r.cost_millicents), 0),
        report_count: count(r.id)
      })

    result = AdminRepo.one(query)

    {:ok,
     %{
       total_input_tokens: decimal_to_int(result.total_input_tokens),
       total_output_tokens: decimal_to_int(result.total_output_tokens),
       total_tokens: decimal_to_int(result.total_tokens),
       total_cost_millicents: decimal_to_int(result.total_cost_millicents),
       report_count: result.report_count
     }}
  end

  # --- Private helpers ---

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  rescue
    ArgumentError -> Map.new(attrs, fn {k, v} -> {safe_to_atom(k), v} end)
  end

  defp safe_to_atom(k) when is_atom(k), do: k

  defp safe_to_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> String.to_atom(k)
  end

  defp maybe_put_skill_version(attrs, nil), do: attrs
  defp maybe_put_skill_version(attrs, _), do: attrs

  defp decimal_to_int(%Decimal{} = val), do: Decimal.to_integer(val)
  defp decimal_to_int(val) when is_integer(val), do: val
  defp decimal_to_int(nil), do: 0
end
