defmodule Loopctl.Llm.UsageEvent do
  @moduledoc """
  Schema for the `llm_usage_events` table — one immutable row per successful
  tenant LLM operation (Epic 28 residual, #179).

  Records the operation, the model used, and the Anthropic-reported token counts.
  This is a RECORD-ONLY ledger backing the per-tenant usage-summary API; there is
  NO budget enforcement anywhere in the system.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @operations [:extraction, :classification, :merge]

  schema "llm_usage_events" do
    tenant_field()

    field :operation, Ecto.Enum, values: @operations
    field :model, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :source_type, :string
    field :article_id, :binary_id
    field :occurred_at, :utc_datetime_usec
  end

  @doc "The valid operation atoms (extraction | classification | merge)."
  @spec operations() :: [atom()]
  def operations, do: @operations

  @doc """
  Changeset for inserting a usage event. `tenant_id` and `occurred_at` are set
  programmatically by the context.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(event \\ %__MODULE__{}, attrs) do
    event
    |> cast(attrs, [
      :operation,
      :model,
      :input_tokens,
      :output_tokens,
      :source_type,
      :article_id,
      :occurred_at
    ])
    |> validate_required([:operation, :model, :occurred_at])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
  end
end
