defmodule Loopctl.WebAuthn.BrowserSession do
  @moduledoc """
  Schema for `browser_sessions` (US-45.7): the server side of a thread-page login. The cookie
  carries this row's id and its tenant; the row carries what the cookie cannot be trusted to:
  when the session ends (`expires_at`) and whether it was logged out (`revoked_at`). Deleting
  the asserting authenticator or the tenant deletes the row. Every field is set by
  `Loopctl.WebAuthn.BrowserLogin`; nothing is cast.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "browser_sessions" do
    tenant_field()

    field :authenticator_id, :binary_id
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
