defmodule Loopctl.VaultTest do
  use ExUnit.Case, async: true

  alias Loopctl.Vault
  alias Loopctl.Vault.Rotation

  describe "active_first/1" do
    # Cloak encrypts with hd(ciphers), NOT with the entry labelled :default. Config cannot
    # be trusted to hold that position: Keyword.merge/3 (which Config.__merge__/2 uses)
    # appends an OVERRIDDEN key after the untouched ones, so a vault whose active key comes
    # from runtime.exs and whose retired key comes from another config file lands with the
    # retired cipher first — and every new write goes out under a dead key.
    test "hoists the :default cipher out from behind a retired one" do
      ciphers = [retired_0: :retired_cipher, default: :active_cipher]

      assert Vault.active_first(ciphers) == [default: :active_cipher, retired_0: :retired_cipher]
    end

    test "keeps the relative order of the retired ciphers" do
      ciphers = [retired_0: :first, retired_1: :second, default: :active]

      assert Vault.active_first(ciphers) ==
               [default: :active, retired_0: :first, retired_1: :second]
    end

    test "is a no-op when :default is already first" do
      ciphers = [default: :active, retired_0: :retired]

      assert Vault.active_first(ciphers) == ciphers
    end

    # Cloak's own semantic is first-is-active. With no :default label there is nothing to
    # hoist, and picking one would be a guess about which key is live.
    test "leaves an unlabelled list exactly as given" do
      ciphers = [primary: :one, secondary: :two]

      assert Vault.active_first(ciphers) == ciphers
    end

    test "tolerates an empty list" do
      assert Vault.active_first([]) == []
    end
  end

  # The invariant the ordering exists for, asserted end to end against the RUNNING vault
  # rather than against the config list: what it stamps is what it encrypts with.
  test "the running vault encrypts with the cipher labelled :default" do
    {_module, opts} = Keyword.fetch!(Application.get_env(:loopctl, Vault)[:ciphers], :default)

    assert Rotation.active_tag() == opts[:tag]
  end
end
