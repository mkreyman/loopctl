defmodule Loopctl.Vault do
  @moduledoc """
  Cloak vault for field-level encryption at rest.

  Uses AES-256-GCM for encrypting sensitive fields such as
  API key secrets and webhook signing secrets.

  The encryption key is sourced from the CLOAK_KEY environment
  variable (32-byte base64-encoded).

  ## Generating a key

      :crypto.strong_rand_bytes(32) |> Base.encode64()

  ## Key rotation

  Retired keys arrive from `CLOAK_RETIRED_KEYS` (see `Loopctl.Config.cloak_ciphers!/3`) and
  are decrypt-only. `mix loopctl.reencrypt_secrets` moves stored rows onto the active key;
  `docs/runbooks/cloak-key-rotation.md` is the procedure.
  """

  use Cloak.Vault, otp_app: :loopctl

  @doc """
  Hoists the `:default`-labelled cipher to the front of the `:ciphers` list.

  Cloak encrypts new writes with `hd(ciphers)` — the FIRST entry, not the one labelled
  `:default` (`Cloak.Vault.encrypt/2`). Config order is not a reliable way to hold that
  position: `Config.__merge__/2` merges keyword lists with `Keyword.merge/3`, which appends
  overridden keys AFTER the untouched ones. So a `Loopctl.Vault` config assembled in two
  places — `config/test.exs` listing a retired cipher and `config/runtime.exs` supplying
  `CLOAK_KEY` — comes out with the retired cipher first, and every new write goes out under
  a key the operator is about to delete.

  Ordering here rather than at each config site makes the invariant hold no matter how the
  config was assembled. A ciphers list with no `:default` label is left exactly as given —
  that is Cloak's own first-is-active semantic, and reordering it would be a guess.
  """
  @spec active_first(keyword()) :: keyword()
  def active_first(ciphers) do
    case Keyword.fetch(ciphers, :default) do
      {:ok, cipher} -> [{:default, cipher} | Keyword.delete(ciphers, :default)]
      :error -> ciphers
    end
  end

  @impl GenServer
  def init(config) do
    {:ok, Keyword.update(config, :ciphers, [], &active_first/1)}
  end
end
