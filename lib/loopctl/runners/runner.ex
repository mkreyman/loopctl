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

  It does carry CAPACITY (#803): `max_sessions`, set at enrollment, and `in_flight`, the
  number of slots reserved on this machine right now. Those two are authoritative; the
  values a runner reports in Presence are a hint. `in_flight` is written only by
  `Loopctl.Runners.Capacity`, never through a changeset.

  ## Trust boundary

  `tenant_id`, `api_key_id`, `revoked_at` and `in_flight` are set programmatically in
  `Loopctl.Runners`, never via `cast/3`. `name` and `max_sessions` are the caller-supplied
  fields.

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

  @derive {Jason.Encoder,
           only: [:id, :name, :max_sessions, :in_flight, :revoked_at, :inserted_at, :updated_at]}

  schema "runners" do
    tenant_field()
    field :api_key_id, :binary_id
    field :name, :string
    field :max_sessions, :integer, default: @default_max_sessions
    field :in_flight, :integer, default: 0
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

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
    |> validate_format(:name, @name_format,
      message: "must be lowercase letters, digits, '.', '_' or '-', starting alphanumeric"
    )
    |> check_constraint(:name, name: :runners_name_shape)
    |> unique_constraint(:name,
      name: :runners_active_name_uidx,
      message: "an active runner already uses this name"
    )
  end

  @doc "Changeset that revokes a runner."
  @spec revoke_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{} = runner, now) do
    change(runner, revoked_at: now)
  end
end
