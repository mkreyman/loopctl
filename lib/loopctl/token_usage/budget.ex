defmodule Loopctl.TokenUsage.Budget do
  @moduledoc """
  Schema for the `token_budgets` table.

  Defines cost and token budgets at project, epic, or story scope.
  Each budget is uniquely constrained to `(tenant_id, scope_type, scope_id)`.

  ## Fields

  - `scope_type` -- `:project`, `:epic`, or `:story`
  - `scope_id` -- UUID of the project, epic, or story
  - `budget_millicents` -- total cost budget in 1/1000 of a cent
  - `budget_input_tokens` -- optional input token budget
  - `budget_output_tokens` -- optional output token budget
  - `alert_threshold_pct` -- percentage at which to alert (default 80)
  - `metadata` -- extensible JSONB map
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @scope_types [:project, :epic, :story]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :scope_type,
             :scope_id,
             :budget_millicents,
             :budget_input_tokens,
             :budget_output_tokens,
             :alert_threshold_pct,
             :warning_fired,
             :exceeded_fired,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "token_budgets" do
    tenant_field()

    field :scope_type, Ecto.Enum, values: @scope_types
    field :scope_id, :binary_id
    field :budget_millicents, :integer
    field :budget_input_tokens, :integer
    field :budget_output_tokens, :integer
    field :alert_threshold_pct, :integer, default: 80
    field :warning_fired, :boolean, default: false
    field :exceeded_fired, :boolean, default: false
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Changeset for creating a new token budget.

  The `tenant_id` is set programmatically and must not be in cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(budget \\ %__MODULE__{}, attrs) do
    budget
    |> cast(attrs, [
      :scope_type,
      :scope_id,
      :budget_millicents,
      :budget_input_tokens,
      :budget_output_tokens,
      :alert_threshold_pct,
      :metadata
    ])
    |> validate_required([:scope_type, :scope_id, :budget_millicents])
    |> validate_number(:budget_millicents, greater_than: 0)
    |> validate_number(:budget_input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:budget_output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:alert_threshold_pct,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_inclusion(:scope_type, @scope_types)
    |> validate_metadata_size()
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :scope_type, :scope_id],
      name: :token_budgets_tenant_id_scope_type_scope_id_index,
      message: "budget already exists for this scope"
    )
  end

  @doc """
  Changeset for updating an existing token budget.

  Cannot change `scope_type` or `scope_id`.

  When `budget_millicents` or `alert_threshold_pct` changes, the
  `warning_fired` and `exceeded_fired` deduplication flags are reset
  to `false` so that webhook events will re-fire at the new threshold.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(budget, attrs) do
    budget
    |> cast(attrs, [
      :budget_millicents,
      :budget_input_tokens,
      :budget_output_tokens,
      :alert_threshold_pct,
      :metadata
    ])
    |> validate_number(:budget_millicents, greater_than: 0)
    |> validate_number(:budget_input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:budget_output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:alert_threshold_pct,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_metadata_size()
    |> maybe_reset_dedup_flags()
  end

  # If budget_millicents or alert_threshold_pct changed, reset the
  # warning_fired / exceeded_fired flags so webhook events re-fire at the
  # new threshold level (AC-21.7.6).
  defp maybe_reset_dedup_flags(changeset) do
    if get_change(changeset, :budget_millicents) || get_change(changeset, :alert_threshold_pct) do
      changeset
      |> put_change(:warning_fired, false)
      |> put_change(:exceeded_fired, false)
    else
      changeset
    end
  end

  @metadata_max_bytes 65_536

  defp validate_metadata_size(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if byte_size(Jason.encode!(value)) > @metadata_max_bytes,
        do: [metadata: "must be smaller than 64KB"],
        else: []
    end)
  end
end
