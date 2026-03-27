defmodule Loopctl.Auth.IdempotencyCache do
  @moduledoc """
  Schema for the idempotency cache table.

  Stores idempotency keys and their response data (encrypted) for 24 hours.
  Used by the tenant registration endpoint to prevent duplicate registrations
  when the initial response is lost.
  """

  use Loopctl.Schema, tenant_scoped: false

  @type t :: %__MODULE__{}

  schema "idempotency_cache" do
    field :idempotency_key, :string
    field :response_data, :binary
    field :expires_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
