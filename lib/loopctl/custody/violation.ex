defmodule Loopctl.Custody.Violation do
  @moduledoc """
  One recorded chain-of-custody violation (L6 byzantine detection input).

  A row here means a caller was refused by a self-* custody gate — it tried to
  close its own custody loop. The row is the DURABLE evidence a halt decision is
  made from: `Loopctl.Custody.ViolationMonitor` counts these per tenant over a
  window and halts the tenant only once the count reaches the threshold, so a
  single event can no longer take a tenant down.

  `consumed_at` is stamped on the rows that ARMED a halt. They stay readable —
  they are the forensic answer to "why was this tenant halted" — but they no
  longer count, so the evidence for one halt cannot arm the next one.

  `tenant_id` is set programmatically and is never in `cast/3` (CLAUDE.md
  Multi-Tenant Rules #4). Writes go through `AdminRepo` — the custody gates run
  outside a tenant RLS context — so the explicit `tenant_id` predicate on every
  read is the isolation.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @valid_types ~w(self_verify_blocked self_report_blocked self_review_blocked)

  schema "custody_violations" do
    tenant_field()

    field :violation_type, :string
    field :story_id, :binary_id
    field :api_key_id, :binary_id
    field :agent_id, :binary_id
    field :occurred_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Builds a changeset for a violation record.

  `violation_type` is constrained to the gate outcomes that are UNAMBIGUOUSLY
  byzantine — all three lineage-aware self-* gates. A capability-token rejection
  is deliberately NOT one of them — see `Loopctl.Custody.ViolationMonitor` for why.

  `consumed_at` is never cast: it is stamped by the monitor's claim, not supplied.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(violation, attrs) do
    violation
    |> cast(attrs, [:violation_type, :story_id, :api_key_id, :agent_id, :occurred_at])
    |> validate_required([:violation_type, :occurred_at])
    |> validate_inclusion(:violation_type, @valid_types)
    |> foreign_key_constraint(:tenant_id)
  end

  @doc "The violation types that count toward a custody halt."
  @spec valid_types() :: [String.t()]
  def valid_types, do: @valid_types
end
