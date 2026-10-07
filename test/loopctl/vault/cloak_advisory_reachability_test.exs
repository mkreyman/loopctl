defmodule Loopctl.Vault.CloakAdvisoryReachabilityTest do
  @moduledoc """
  The cloak advisories CVE-2026-95105 (unauthenticated AES-CTR) and CVE-2026-94206 (PBKDF2
  iteration count ignored) are ignored in mix.exs because loopctl uses neither affected
  module: every vault cipher is AES.GCM and no field is PBKDF2-hashed. Referencing either
  module would make its advisory reachable while the ignore entries keep `mix hex.audit`
  green, so this fails first.

  It parses the files (`Loopctl.SourceScan.references_alias?/2`), so a comment saying "we
  never use AES.CTR" does not trip it and a multi-alias (`alias Cloak.Ciphers.AES.{CTR, GCM}`)
  does.

  ## What it cannot see

  A cipher module resolved at runtime from a string (`Module.concat/1`, a tag-to-module map
  built from config strings, `String.to_existing_atom/1`) names no alias in source, so it is
  invisible here. So is any Elixir outside the scanned set below, for example a `.heex`
  template or `rel/env.sh.eex`. A green run is evidence about the scanned files' source, not
  proof about the running vault.
  """

  use ExUnit.Case, async: true

  alias Loopctl.SourceScan

  @sources Enum.flat_map(
             ["lib/**/*.{ex,exs}", "config/**/*.exs", "rel/**/*.exs", "priv/**/*.exs"],
             &Path.wildcard/1
           )

  # Cloak.Ciphers.AES.CTR, its Cloak.Ciphers.Deprecated.AES.CTR twin, and Cloak.Ecto.PBKDF2.
  @affected_last_segments [:CTR, :PBKDF2]

  test "the scan reads both halves of where the vault's ciphers are configured" do
    # Without this the guard below passes vacuously if either glob matches nothing: the
    # vault cipher is built in lib/loopctl/config.ex, and its test ciphers in config/test.exs.
    gcm_sites = Enum.filter(@sources, &SourceScan.references_alias?(&1, [:GCM]))

    assert "lib/loopctl/config.ex" in gcm_sites
    assert "config/test.exs" in gcm_sites
  end

  test "nothing scanned references an advisory-affected cloak module" do
    offenders = Enum.filter(@sources, &SourceScan.references_alias?(&1, @affected_last_segments))

    assert offenders == [],
           "an affected cloak module makes an ignored advisory in mix.exs reachable"
  end

  test "the ignores are re-evaluated when cloak or cloak_ecto moves" do
    # hex.audit only WARNS when an ignore entry stops matching, so a bump would otherwise
    # leave CVE-2026-95105 and CVE-2026-94206 silenced for good. Changing either version
    # fails here: re-check both advisories against the new release, then update the ignore
    # entries in mix.exs and these pins together.
    {lock, _binding} = Code.eval_file("mix.lock")

    assert {:hex, :cloak, "1.1.4", _, _, _, _, _} = lock[:cloak]
    assert {:hex, :cloak_ecto, "1.3.0", _, _, _, _, _} = lock[:cloak_ecto]
  end
end
