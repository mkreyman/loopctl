defmodule Loopctl.Vault.CloakAdvisoryReachabilityTest do
  @moduledoc """
  The cloak advisories CVE-2026-95105 (unauthenticated AES-CTR) and CVE-2026-94206 (PBKDF2
  iteration count ignored) are ignored in mix.exs because loopctl uses neither affected
  module: every vault cipher is AES.GCM and no field is PBKDF2-hashed. Using either module
  would make its advisory reachable while the ignore entries keep `mix hex.audit` green, so
  this fails first.

  It reads what is COMPILED, not source text: every `:loopctl` module's atom table, which
  holds each module the code names however it was written (an alias, a multi-alias child,
  an atom literal, a macro's expansion) and holds nothing from a comment. The vault's cipher
  lists are checked by building them: `Loopctl.Config.cloak_ciphers!/3` is what
  `config/runtime.exs` calls in every environment, and the test env's list is read back
  from the app env that `config/test.exs` wrote.

  ## What it cannot see

  A module resolved at runtime from a string (`Module.concat/1`, `String.to_existing_atom/1`,
  a tag-to-module map built from env values) is in no atom table until it runs. A green run
  is evidence about the compiled code and the cipher builders, not proof about every value
  the running vault could be handed.
  """

  use ExUnit.Case, async: true

  @affected [Cloak.Ciphers.AES.CTR, Cloak.Ciphers.Deprecated.AES.CTR, Cloak.Ecto.PBKDF2]

  # The beam FILE in the app's ebin, not `:code.which/1`: other tests recompile some lib
  # modules in memory (a credo check's registry, for one), and `:code.which/1` then answers ""
  # for a module that has no file behind its loaded copy. The file is what was compiled.
  defp atoms(module) do
    beam = Application.app_dir(:loopctl, ["ebin", "#{module}.beam"])
    {:ok, {^module, [atoms: atoms]}} = :beam_lib.chunks(String.to_charlist(beam), [:atoms])
    Enum.map(atoms, fn {_index, atom} -> atom end)
  end

  defp cipher_modules(ciphers), do: Enum.map(ciphers, fn {_label, {module, _opts}} -> module end)

  test "no compiled loopctl module references an advisory-affected cloak module" do
    modules = Application.spec(:loopctl, :modules)

    # The scan reads atom tables at all: the module that builds the vault cipher names GCM.
    assert Cloak.Ciphers.AES.GCM in atoms(Loopctl.Config)

    offenders =
      Enum.filter(modules, fn module -> Enum.any?(@affected, &(&1 in atoms(module))) end)

    assert offenders == [],
           "an affected cloak module makes an ignored advisory in mix.exs reachable"
  end

  test "every vault cipher is AES.GCM, in the runtime builder and in the test env" do
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    retired = "OLD.V1:" <> Base.encode64(:crypto.strong_rand_bytes(32))

    built = Loopctl.Config.cloak_ciphers!(key, "NEW.V2", retired)
    configured = Application.fetch_env!(:loopctl, Loopctl.Vault)[:ciphers]

    assert length(built) == 2
    assert Enum.uniq(cipher_modules(built)) == [Cloak.Ciphers.AES.GCM]
    assert Enum.uniq(cipher_modules(configured)) == [Cloak.Ciphers.AES.GCM]
  end

  test "the ignores are re-evaluated when cloak or cloak_ecto moves" do
    # hex.audit only WARNS when an ignore entry stops matching, so a bump would otherwise
    # leave CVE-2026-95105 and CVE-2026-94206 silenced for good. Changing either version
    # fails here: re-check both advisories against the new release, then update the ignore
    # entries in mix.exs and these pins together. Read from the LOADED apps, not mix.lock,
    # so a lock and deps/ that disagree cannot pass on the lock's text.
    assert Application.spec(:cloak, :vsn) == ~c"1.1.4"
    assert Application.spec(:cloak_ecto, :vsn) == ~c"1.3.0"
  end
end
