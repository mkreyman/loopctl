defmodule Loopctl.WorkBreakdown.Story do
  @moduledoc """
  Schema for the `stories` table.

  Stories are the fundamental work unit in loopctl. The two-tier status model
  (agent_status + verified_status) is the core innovation: implementing agents
  set agent_status, while orchestrators independently set verified_status.

  ## Fields

  - `number` -- string (e.g., "2.1", "2.2"), unique within a project
  - `title` -- display name
  - `description` -- freeform text description
  - `acceptance_criteria` -- JSONB array of AC items
  - `estimated_hours` -- decimal for precision (e.g., 0.5 hours)
  - `agent_status` -- enum: pending, contracted, assigned, implementing, reported_done
  - `verified_status` -- enum: unverified, verified, rejected
  - `assigned_agent_id` -- FK to agents table
  - `sort_key` -- integer computed from story number for natural numeric sort
  - `metadata` -- JSONB map for extensibility
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @agent_statuses [:pending, :contracted, :assigned, :implementing, :reported_done]
  @verified_statuses [:unverified, :verified, :rejected]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :epic_id,
             :number,
             :title,
             :description,
             :acceptance_criteria,
             :estimated_hours,
             :agent_status,
             :verified_status,
             :assigned_agent_id,
             :reported_by_agent_id,
             :assigned_at,
             :reported_done_at,
             :verified_at,
             :rejected_at,
             :rejection_reason,
             :sort_key,
             :metadata,
             :implementer_dispatch_id,
             :verifier_dispatch_id,
             :verifier_needed,
             :inserted_at,
             :updated_at
           ]}

  schema "stories" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project
    belongs_to :epic, Loopctl.WorkBreakdown.Epic
    belongs_to :assigned_agent, Loopctl.Agents.Agent
    belongs_to :reported_by_agent, Loopctl.Agents.Agent

    field :number, :string
    field :title, :string
    field :description, :string
    field :acceptance_criteria, {:array, :map}, default: []
    field :estimated_hours, :decimal
    field :agent_status, Ecto.Enum, values: @agent_statuses, default: :pending
    field :verified_status, Ecto.Enum, values: @verified_statuses, default: :unverified
    field :assigned_at, :utc_datetime_usec
    field :reported_done_at, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec
    field :rejection_reason, :string
    field :sort_key, :integer, default: 0
    field :metadata, :map, default: %{}

    # US-26.2.2: Dispatch lineage for chain-of-custody enforcement
    field :implementer_dispatch_id, Ecto.UUID
    field :verifier_dispatch_id, Ecto.UUID
    field :verifier_needed, :boolean, default: false

    timestamps()
  end

  @doc """
  Changeset for creating a new story.

  The `tenant_id`, `project_id`, and `epic_id` are set programmatically,
  not via cast. The `sort_key` is computed from the story number.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(story \\ %__MODULE__{}, attrs) do
    story
    |> cast(attrs, [
      :number,
      :title,
      :description,
      :acceptance_criteria,
      :estimated_hours,
      :metadata
    ])
    |> validate_required([:number, :title])
    |> validate_length(:title, max: 500)
    |> validate_length(:description, max: 50_000)
    |> validate_number_format()
    |> compute_sort_key()
    |> validate_metadata()
    |> unique_constraint([:tenant_id, :project_id, :number],
      message: "has already been taken for this project"
    )
  end

  @doc """
  Changeset for updating an existing story.

  Excludes agent_status and verified_status from cast -- those are
  managed via dedicated status endpoints.
  Number cannot be changed after creation.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(story, attrs) do
    story
    |> cast(attrs, [
      :title,
      :description,
      :acceptance_criteria,
      :estimated_hours,
      :metadata
    ])
    |> validate_length(:title, max: 500)
    |> validate_length(:description, max: 50_000)
    |> validate_metadata()
  end

  @doc """
  Returns the list of valid agent statuses.
  """
  @spec agent_statuses() :: [atom()]
  def agent_statuses, do: @agent_statuses

  @doc """
  Returns the list of valid verified statuses.
  """
  @spec verified_statuses() :: [atom()]
  def verified_statuses, do: @verified_statuses

  @doc """
  Computes a sort key from a story number string for natural numeric ordering.

  Examples:
  - "1.1" -> 10010
  - "1.2" -> 10020
  - "1.10" -> 10100
  - "2.1" -> 20010
  - "10.5" -> 100050

  The formula is: major * 10000 + minor * 10
  """
  @spec compute_sort_key_value(String.t()) :: integer()
  def compute_sort_key_value(number) when is_binary(number) do
    case String.split(number, ".") do
      [major_str, minor_str] ->
        major = safe_parse_int(major_str)
        minor = safe_parse_int(minor_str)
        major * 10_000 + minor * 10

      [major_str] ->
        safe_parse_int(major_str) * 10_000

      _ ->
        0
    end
  end

  def compute_sort_key_value(_), do: 0

  # --- Private helpers ---

  defp validate_number_format(changeset) do
    validate_change(changeset, :number, fn :number, value ->
      parts = String.split(value, ".")

      cond do
        length(parts) > 2 ->
          [number: "must be in format 'major.minor' or 'major'"]

        Enum.any?(parts, fn part ->
          case Integer.parse(part) do
            {n, ""} -> n < 0 or n >= 10_000
            _ -> true
          end
        end) ->
          [number: "each part must be a non-negative integer less than 10000"]

        true ->
          []
      end
    end)
  end

  defp compute_sort_key(changeset) do
    case get_change(changeset, :number) do
      nil -> changeset
      number -> put_change(changeset, :sort_key, compute_sort_key_value(number))
    end
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if is_map(value) and not is_struct(value) do
        []
      else
        [metadata: "must be a map"]
      end
    end)
  end

  defp safe_parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end
end
