defmodule Loopctl.Webhooks.WebhookEvent do
  @moduledoc """
  Schema for the `webhook_events` table -- outbound event queue for webhooks.

  Each record represents a single event targeted at a specific webhook
  endpoint. Events are created transactionally alongside the state change
  that triggers them and processed asynchronously by the Oban delivery worker.

  ## Status Lifecycle

  - `pending` -- created, awaiting delivery
  - `delivered` -- successfully delivered (HTTP 2xx)
  - `failed` -- delivery failed, may be retried
  - `exhausted` -- all retry attempts used up
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses [:pending, :delivered, :failed, :exhausted]

  schema "webhook_events" do
    tenant_field()

    belongs_to :webhook, Loopctl.Webhooks.Webhook, type: :binary_id

    field :event_type, :string
    field :payload, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :attempts, :integer, default: 0
    field :last_attempt_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :error, :string

    timestamps()
  end

  @doc """
  Changeset for creating a new webhook event.

  The `tenant_id` and `webhook_id` are set programmatically.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(event \\ %__MODULE__{}, attrs) do
    event
    |> cast(attrs, [:event_type, :payload])
    |> validate_required([:event_type, :payload])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:webhook_id)
  end

  @doc """
  Changeset for updating delivery status after an attempt.
  """
  @spec delivery_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def delivery_changeset(event, attrs) do
    event
    |> cast(attrs, [:status, :attempts, :last_attempt_at, :delivered_at, :error])
  end
end
