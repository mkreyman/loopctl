defmodule Loopctl.QualityAssurance.UiTestRun do
  @moduledoc """
  Schema for the `ui_test_runs` table.

  UI test runs record automated or manual UI testing sessions for a project,
  following a guide reference (path or URL). Each run captures structured
  findings with severity counts, screenshots, and a completion summary.

  ## Fields

  - `status` -- enum: in_progress, passed, failed, cancelled
  - `guide_reference` -- path or URL to the user guide being followed
  - `findings` -- array of structured finding maps
  - `summary` -- free-text completion summary (filled on completion)
  - `screenshots_count` -- total screenshots taken
  - `findings_count` -- total findings recorded
  - `critical_count` -- critical severity findings
  - `high_count` -- high severity findings
  - `started_at` -- when the run began
  - `completed_at` -- when the run finished (nil if in_progress)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses [:in_progress, :passed, :failed, :cancelled]
  @severities ~w(critical high medium low)

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :started_by_agent_id,
             :status,
             :guide_reference,
             :findings,
             :summary,
             :screenshots_count,
             :findings_count,
             :critical_count,
             :high_count,
             :started_at,
             :completed_at,
             :inserted_at,
             :updated_at
           ]}

  schema "ui_test_runs" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project
    belongs_to :started_by_agent, Loopctl.Agents.Agent

    field :status, Ecto.Enum, values: @statuses, default: :in_progress
    field :guide_reference, :string
    field :findings, {:array, :map}, default: []
    field :summary, :string

    field :screenshots_count, :integer, default: 0
    field :findings_count, :integer, default: 0
    field :critical_count, :integer, default: 0
    field :high_count, :integer, default: 0

    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a new UI test run.

  The `tenant_id`, `project_id`, and `started_by_agent_id` are set
  programmatically, not via cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(run \\ %__MODULE__{}, attrs) do
    run
    |> cast(attrs, [:guide_reference, :started_at])
    |> validate_required([:guide_reference, :started_at])
    |> validate_length(:guide_reference, min: 1, max: 1000)
  end

  @doc """
  Changeset for completing a UI test run.

  Sets status, summary, and completed_at. Cannot be applied to an already
  completed run — the context layer enforces that guard.
  """
  @spec complete_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def complete_changeset(run, attrs) do
    run
    |> cast(attrs, [:status, :summary])
    |> validate_required([:status, :summary])
    |> validate_terminal_status()
    |> put_change(:completed_at, DateTime.utc_now())
  end

  defp validate_terminal_status(changeset) do
    status = get_field(changeset, :status)

    if status in [:passed, :failed] do
      changeset
    else
      add_error(changeset, :status, "must be passed or failed")
    end
  end

  @doc """
  Changeset for appending a finding to the run's findings array.

  Updates findings array and increments the relevant counters atomically.
  """
  @spec add_finding_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def add_finding_changeset(run, finding_params) do
    finding =
      finding_params
      |> Map.take(~w(step severity type description screenshot_path console_errors))
      |> Map.put("recorded_at", DateTime.to_iso8601(DateTime.utc_now()))

    new_findings = run.findings ++ [finding]
    severity = Map.get(finding, "severity", "low")

    changeset =
      run
      |> change(findings: new_findings)
      |> change(findings_count: run.findings_count + 1)

    changeset =
      if "screenshot_path" in Map.keys(finding) and Map.get(finding, "screenshot_path") != nil do
        change(changeset, screenshots_count: run.screenshots_count + 1)
      else
        changeset
      end

    case severity do
      "critical" -> change(changeset, critical_count: run.critical_count + 1)
      "high" -> change(changeset, high_count: run.high_count + 1)
      _ -> changeset
    end
  end

  @doc """
  Returns the list of valid statuses.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Returns the list of valid severity levels.
  """
  @spec severities() :: [String.t()]
  def severities, do: @severities
end
