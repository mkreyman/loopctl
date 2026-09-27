defmodule Loopctl.WebAuthn.LoginChallenge do
  @moduledoc """
  Schema for `webauthn_login_challenges` (US-45.7): a usernameless login's challenge, issued
  before anyone is identified and therefore bound to no tenant. Stored, single-use and
  TTL-bounded like `Loopctl.WebAuthn.ReauthChallenge`, and read only on `AdminRepo` by
  `Loopctl.WebAuthn.Reauth`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "webauthn_login_challenges" do
    field :challenge, :binary
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
