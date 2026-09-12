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

  ## Trust boundary

  `tenant_id`, `api_key_id` and `revoked_at` are set programmatically in
  `Loopctl.Runners`, never via `cast/3`. `name` is the only caller-supplied field.

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

  @derive {Jason.Encoder, only: [:id, :name, :revoked_at, :inserted_at, :updated_at]}

  schema "runners" do
    tenant_field()
    field :api_key_id, :binary_id
    field :name, :string
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The machine-name format a runner is enrolled under."
  @spec name_format() :: Regex.t()
  def name_format, do: @name_format

  @doc """
  Changeset for enrolling a runner. `tenant_id` and `api_key_id` must already be set
  on the struct.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = runner, attrs) do
    runner
    |> cast(attrs, [:name])
    |> validate_required([:name])
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
