defmodule Loopctl.Agents.RunOutcome do
  @moduledoc """
  Schema for the `agent_run_outcomes` table (Epic 48, US-48.12): one row per runner dispatch,
  keyed by the agent spec `{spec_id, spec_version}` it ran under.

  The core columns are the dispatch's identity and its session's own facts; `signals` is
  what later happened to its work, as `%{"<signal>" => %{"value" => v, "at" => iso8601,
  "source" => "<the system event that proved it>"}}`. Every signal is written once, by
  `Loopctl.Agents.Outcomes`, from an event loopctl itself recorded — never from anything a
  session wrote.

  Every field is set programmatically by `Loopctl.Agents.Outcomes`; there is no caller
  changeset. See the migration for the CHECKs.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @archetypes ~w(judge build draft)

  schema "agent_run_outcomes" do
    tenant_field()
    field :dispatch_id, :binary_id
    field :runner_id, :binary_id
    field :story_id, :binary_id
    field :project_id, :binary_id
    field :kind, :string
    field :spec_id, :string
    field :spec_version, :integer
    field :archetype, :string
    field :prompt_template_id, :string
    field :prompt_template_version, :integer
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :elapsed_s, :integer
    field :turns, :integer
    field :cost_millicents, :integer
    field :end_reason, :string
    field :signals, :map, default: %{}

    timestamps()
  end

  @doc "The archetypes a row may carry, as stored."
  @spec archetypes() :: [String.t()]
  def archetypes, do: @archetypes
end
