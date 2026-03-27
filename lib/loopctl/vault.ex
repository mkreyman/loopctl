defmodule Loopctl.Vault do
  @moduledoc """
  Cloak vault for field-level encryption at rest.

  Uses AES-256-GCM for encrypting sensitive fields such as
  API key secrets and webhook signing secrets.

  The encryption key is sourced from the CLOAK_KEY environment
  variable (32-byte base64-encoded).

  ## Generating a key

      :crypto.strong_rand_bytes(32) |> Base.encode64()
  """

  use Cloak.Vault, otp_app: :loopctl
end
