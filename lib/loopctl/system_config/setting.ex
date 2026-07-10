defmodule Loopctl.SystemConfig.Setting do
  @moduledoc """
  Schema for the `system_configs` table — a GLOBAL (non-tenant) key/value store
  of live-tunable operational knobs (timeout/retry budgets).

  Global, like `Loopctl.Tenants.Tenant`: there is no `tenant_id`. All access goes
  through `Loopctl.AdminRepo` (BYPASSRLS). Values are `:integer` (`bigint` in the
  DB) so millisecond timeouts and small counts share one column type.
  """

  use Loopctl.Schema, tenant_scoped: false

  @type t :: %__MODULE__{}

  schema "system_configs" do
    field :key, :string
    field :value, :integer
    field :description, :string

    timestamps()
  end

  @doc """
  Changeset for a single setting. `key` and `value` are required; `key` is
  unique. `description` is optional operator documentation.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :description])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
  end
end
