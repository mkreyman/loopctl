defmodule Loopctl.Knowledge.KbCurationEvent do
  @moduledoc """
  One concise, human-readable KB curation adjustment (a novelty-gate decision, a conflict
  supersede/merge/dismiss, ...). The skimmable "what did the KB change" feed, distinct from
  the verbose immutable `audit_log`. Written only when the tenant has
  `settings["kb_curation_log"]` on (rollout observability). `tenant_id` is set
  programmatically, never cast.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "kb_curation_events" do
    tenant_field()

    field :kind, :string
    field :summary, :string
    field :refs, {:array, :binary_id}, default: []
    field :actor, :string
    field :confidence, :string
    field :metadata, :map, default: %{}
    field :at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @cast_fields [:kind, :summary, :refs, :actor, :confidence, :metadata, :at]

  @doc "Changeset for a curation event. `tenant_id` is set on the struct, not cast."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(event \\ %__MODULE__{}, attrs) do
    event
    |> cast(attrs, @cast_fields)
    |> validate_required([:kind, :summary, :at])
  end
end
