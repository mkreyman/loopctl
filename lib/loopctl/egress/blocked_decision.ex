defmodule Loopctl.Egress.BlockedDecision do
  @moduledoc """
  An AGGREGATED record of egress refusals (US-41.4, AC-41.4.6).

  Blocking is cheap and happens before any network call, so a per-call write
  would be a self-inflicted write amplifier: one misconfigured harvest loop
  would flood the audit path. Records are therefore deduplicated per
  `(scope_key, endpoint_host, reason, window_start)` and carry an
  `occurrence_count`; the EXACT per-call rate lives in the
  `[:loopctl, :egress, :blocked]` telemetry counter, never in rows.

  US-41.7 turns these rows into the witnessed custody claim.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "egress_blocked_decisions" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project, type: :binary_id

    field :scope_key, :string
    field :endpoint_host, :string
    field :reason, :string
    field :window_start, :utc_datetime_usec
    field :occurrence_count, :integer, default: 1

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :project_id,
      :scope_key,
      :endpoint_host,
      :reason,
      :window_start,
      :occurrence_count
    ])
    |> validate_required([:scope_key, :endpoint_host, :reason, :window_start])
  end
end
