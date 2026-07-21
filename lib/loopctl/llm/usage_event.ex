defmodule Loopctl.Llm.UsageEvent do
  @moduledoc """
  Schema for the `llm_usage_events` table — one immutable row per successful
  tenant LLM operation (Epic 28 residual, #179).

  Records the operation, the model used, and the provider-reported token counts
  (Anthropic `input_tokens`/`output_tokens` for LLM ops; OpenAI
  `prompt_tokens`/`total_tokens` as `input_tokens` with `output_tokens: 0` for
  `:embedding`). This is a RECORD-ONLY ledger backing the per-tenant usage-summary
  API; there is NO budget enforcement anywhere in the system.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @operations [:extraction, :classification, :merge, :embedding]

  # The FIXED provider set. Never a user-supplied value.
  @providers ~w(anthropic embedding openai_compatible)

  schema "llm_usage_events" do
    tenant_field()

    field :operation, Ecto.Enum, values: @operations
    field :model, :string
    # US-41.3 (AC-41.3.6): which provider actually served the call. A FIXED set
    # (`"anthropic"` | `"embedding"` | `"openai_compatible"`) — NEVER the
    # tenant-supplied host, which would make this column unbounded and leak the
    # endpoint into the usage ledger.
    field :provider, :string, default: "anthropic"
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :source_type, :string
    field :article_id, :binary_id
    field :occurred_at, :utc_datetime_usec
  end

  @doc "The valid operation atoms (extraction | classification | merge | embedding)."
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
      :provider,
      :input_tokens,
      :output_tokens,
      :source_type,
      :article_id,
      :occurred_at
    ])
    |> validate_required([:operation, :model, :occurred_at])
    |> validate_inclusion(:provider, @providers)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    # A tenant deleted mid-flight (FK race) maps to a clean {:error, changeset}
    # instead of raising — so best-effort usage recording never crashes an
    # already-successful (already-billed) Anthropic call (review #3).
    |> foreign_key_constraint(:tenant_id)
  end
end
