defmodule Loopctl.Runners.Runner do
  @moduledoc """
  Schema for the `runners` table — the enrolled machines of the agent delivery loop
  (issue #801).

  A runner row binds ONE `api_keys` row to ONE machine name. The key is the credential;
  this row is what makes it a RUNNER credential. `LoopctlWeb.RunnerSocket` refuses a
  key with no active row here, and `LoopctlWeb.RunnerChannel` refuses a join whose
  declared machine name is not this row's `name` — so a token enrolled for `minis`
  cannot appear in the pool as `mac-mini`.

  The row carries no liveness. Presence does, and it dies with the socket.

  It does carry CAPACITY (#803): `max_sessions`, how many slots loopctl will reserve here, and
  `in_flight`, the number reserved right now. Both are written only by
  `Loopctl.Runners.Capacity`, never through a changeset after the insert.

  `max_sessions` is the MACHINE's own number BOUNDED BY THE OPERATOR's: every join writes
  `LEAST(declared, enrolled_max_sessions)` (`Loopctl.Runners.apply_declaration/4`, contract
  1.13.0). A machine may always lower itself and never raise itself. That asymmetry is the
  whole design: holding more than a machine can run places a dispatch it refuses
  `at_capacity`, and the refusal costs the story's claim, while holding less only under-uses
  the machine until it reconnects. Letting the declaration win OUTRIGHT would also have let a
  compromised or misconfigured runner enlarge its own share of the tenant's admission budget
  by declaring a bigger number — something it could not do before capacity followed the
  declaration at all.

  `enrolled_max_sessions` is therefore the operator's GRANT, written once at enrollment and
  never by a join. It is the ceiling, not the held value; `max_sessions` is what
  `Loopctl.Runners.Capacity` actually reserves against. Both are rendered, so a machine held
  below what it declares is explicable from one read.

  `max_sessions` stays a column rather than a read of the Presence meta because a reservation
  is a conditional UPDATE and a CRDT replica cannot hand out the last slot to exactly one
  caller. `in_flight` is loopctl's alone — the count a runner reports in Presence is of
  sessions it is running, which is a different fact and only ever a hint.

  It also names the AGENT its sessions work as (#803): `agent_id`, the `runner:<name>` agent
  row `Loopctl.Runners.enroll_runner/3` gets or creates. A dispatch claims the story it is
  sent for and a claim writes `stories.assigned_agent_id`, so without this a runner-claimed
  story named nobody. The agent belongs to the MACHINE rather than to this row: re-enrolling
  a revoked name makes a second runner row pointing at the same agent, which is why nothing
  makes `agent_id` unique here.

  ## Trust boundary

  `tenant_id`, `api_key_id`, `agent_id`, `revoked_at` and `in_flight` are set programmatically
  in `Loopctl.Runners`, never via `cast/3`. `name` and `max_sessions` are the caller-supplied
  fields. `enrolled_max_sessions` is DERIVED from the cast `max_sessions` inside
  `create_changeset/2` rather than cast itself, so the grant and the seeded held value cannot
  be given different numbers by a caller, and nothing after the insert can raise the ceiling.

  ## Isolation

  `AdminRepo` plus an explicit `tenant_id` predicate in every `Loopctl.Runners` query,
  the same convention as `Loopctl.Coordination`. RLS is ENABLED on the table as
  defense-in-depth.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # A hostname-shaped label: it is echoed into Presence keys, logs and the audit
  # chain, so it is bounded and has no whitespace or path characters. Mirrored by the
  # `runners_name_shape` CHECK constraint.
  @name_format ~r/^[a-z0-9][a-z0-9._-]{0,62}$/

  # Mirrored by the `runners_max_sessions_range` CHECK constraint.
  @max_sessions_range 1..64
  @default_max_sessions 2

  # The ONE declaration of what a runner renders as. `public_fields/0` reads it back so a
  # caller that needs to ADD a derived field (the API's `unsupported_kinds`) builds the same
  # map rather than restating this list — which would then quietly drift from it.
  @public_fields [
    :id,
    :name,
    :max_sessions,
    :enrolled_max_sessions,
    :in_flight,
    :revoked_at,
    :inserted_at,
    :updated_at
  ]

  @derive {Jason.Encoder, only: @public_fields}

  schema "runners" do
    tenant_field()
    field :api_key_id, :binary_id
    field :agent_id, :binary_id
    field :name, :string
    field :max_sessions, :integer, default: @default_max_sessions
    field :enrolled_max_sessions, :integer, default: @default_max_sessions
    field :in_flight, :integer, default: 0
    field :revoked_at, :utc_datetime_usec
    # US-44.6: written only by `Loopctl.Runners.Usage`, never cast. Not in `@public_fields`:
    # the pool renders the EFFECTIVE value (own or account-wide), which is what placement
    # decides on, and a raw per-row value beside it would be a second answer to one question.
    field :usage_exhausted_until, :utc_datetime_usec
    field :usage_cleared_at, :utc_datetime_usec
    field :usage_hold_provisional, :boolean, default: false
    field :account_ref, :string

    timestamps()
  end

  @doc "The fields a runner renders as — the same list the Jason encoder derives from."
  @spec public_fields() :: [atom()]
  def public_fields, do: @public_fields

  @doc "The machine-name format a runner is enrolled under."
  @spec name_format() :: Regex.t()
  def name_format, do: @name_format

  @doc "The range an enrolled `max_sessions` must fall in."
  @spec max_sessions_range() :: Range.t()
  def max_sessions_range, do: @max_sessions_range

  @doc "The `max_sessions` a runner is enrolled with when none is given."
  @spec default_max_sessions() :: pos_integer()
  def default_max_sessions, do: @default_max_sessions

  @doc """
  Changeset for enrolling a runner. `tenant_id` and `api_key_id` must already be set
  on the struct.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = runner, attrs) do
    runner
    |> cast(attrs, [:name, :max_sessions])
    |> validate_required([:name, :max_sessions])
    |> validate_number(:max_sessions,
      greater_than_or_equal_to: @max_sessions_range.first,
      less_than_or_equal_to: @max_sessions_range.last
    )
    |> check_constraint(:max_sessions, name: :runners_max_sessions_range)
    # The GRANT is the enrolled number, and it is taken from the validated `max_sessions`
    # rather than cast, so the two agree at the insert by construction. Nothing writes it
    # again: `Capacity.apply_declared/5` reads it as the ceiling and never sets it.
    |> put_enrolled_max_sessions()
    |> check_constraint(:enrolled_max_sessions, name: :runners_enrolled_max_sessions_range)
    |> validate_format(:name, @name_format,
      message: "must be lowercase letters, digits, '.', '_' or '-', starting alphanumeric"
    )
    |> check_constraint(:name, name: :runners_name_shape)
    |> unique_constraint(:name,
      name: :runners_active_name_uidx,
      message: "an active runner already uses this name"
    )
  end

  defp put_enrolled_max_sessions(changeset) do
    case get_field(changeset, :max_sessions) do
      nil -> changeset
      max -> put_change(changeset, :enrolled_max_sessions, max)
    end
  end

  @doc "Changeset that revokes a runner."
  @spec revoke_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{} = runner, now) do
    change(runner, revoked_at: now)
  end
end
