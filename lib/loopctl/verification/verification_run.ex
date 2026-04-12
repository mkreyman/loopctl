defmodule Loopctl.Verification.VerificationRun do
  @moduledoc """
  Schema for the `verification_runs` table.

  Each run represents an independent re-execution of a story's
  acceptance criteria against the committed code.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(pending running pass fail error)

  @doc "Valid runner types for verification."
  def runner_types, do: ~w(ci_github ci_gitlab fly_machine manual)

  schema "verification_runs" do
    field :tenant_id, Ecto.UUID
    field :story_id, Ecto.UUID
    field :commit_sha, :string
    field :commit_content_hash, :binary
    field :status, :string, default: "pending"
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :runner_type, :string
    field :ac_results, :map, default: %{}
    field :logs_url, :string
    field :machine_id, :string

    timestamps()
  end

  @doc false
  def changeset(run \\ %__MODULE__{}, attrs) do
    run
    |> cast(attrs, [
      :commit_sha,
      :commit_content_hash,
      :status,
      :started_at,
      :completed_at,
      :runner_type,
      :ac_results,
      :logs_url,
      :machine_id
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
