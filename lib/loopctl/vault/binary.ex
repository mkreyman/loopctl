defmodule Loopctl.Vault.Binary do
  @moduledoc """
  Cloak-encrypted binary type backed by `Loopctl.Vault`.

  Use this type for any schema field that stores sensitive binary data
  at rest (e.g., cached API key responses, webhook signing secrets).

  ## Usage

      field :response_data, Loopctl.Vault.Binary
  """

  use Cloak.Ecto.Binary, vault: Loopctl.Vault
end
