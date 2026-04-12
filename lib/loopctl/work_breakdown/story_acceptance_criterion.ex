defmodule Loopctl.WorkBreakdown.StoryAcceptanceCriterion do
  @moduledoc """
  US-26.4.1 — First-class schema for story acceptance criteria.

  Each row represents a single AC with a machine-checkable
  `verification_criterion` that the verification runner uses
  to independently validate the implementer's work.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(pending verified failed unverifiable)
  @criterion_types ~w(test code route migration manual)

  schema "story_acceptance_criteria" do
    field :tenant_id, Ecto.UUID
    field :story_id, Ecto.UUID
    field :ac_id, :string
    field :description, :string
    field :verification_criterion, :map, default: %{"type" => "manual", "description" => "legacy"}
    field :status, :string, default: "pending"
    field :verified_at, :utc_datetime_usec
    field :verified_by_dispatch_id, Ecto.UUID
    field :evidence_path, :string

    timestamps()
  end

  @doc false
  def changeset(criterion \\ %__MODULE__{}, attrs) do
    criterion
    |> cast(attrs, [
      :ac_id,
      :description,
      :verification_criterion,
      :status,
      :verified_at,
      :verified_by_dispatch_id,
      :evidence_path
    ])
    |> validate_required([:ac_id, :description])
    |> validate_inclusion(:status, @statuses)
    |> validate_criterion_type()
    |> unique_constraint([:story_id, :ac_id])
  end

  defp validate_criterion_type(changeset) do
    case get_field(changeset, :verification_criterion) do
      %{"type" => type} when type in @criterion_types -> changeset
      nil -> changeset
      _ -> add_error(changeset, :verification_criterion, "must have a valid type")
    end
  end

  def criterion_types, do: @criterion_types
end
