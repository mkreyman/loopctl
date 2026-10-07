defmodule Loopctl.Vault.CloakAdvisoryReachabilityTest do
  @moduledoc """
  The cloak advisories CVE-2026-95105 (unauthenticated AES-CTR) and CVE-2026-94206 (PBKDF2
  iteration count ignored) are ignored in mix.exs ONLY because loopctl uses neither affected
  module: every vault cipher is AES.GCM and no field is PBKDF2-hashed. Naming either module
  would make the advisory reachable while the ignore entries keep `mix hex.audit` green, so
  this fails first.
  """

  use ExUnit.Case, async: true

  @sources Path.wildcard("lib/**/*.ex") ++ Path.wildcard("config/**/*.exs")

  # The affected modules: Cloak.Ciphers.AES.CTR (and its Deprecated twin) and
  # Cloak.Ecto.PBKDF2, matched however the module is aliased or referenced.
  @affected ~r/AES\.CTR\b|Ecto\.PBKDF2\b/

  test "the scan reads the files that configure the vault" do
    # Without this the guard below passes vacuously on an empty or wrong file set.
    gcm_sites = Enum.filter(@sources, &(File.read!(&1) =~ "Cloak.Ciphers.AES.GCM"))

    assert "lib/loopctl/config.ex" in gcm_sites
  end

  test "nothing in lib or config names an advisory-affected cloak module" do
    offenders = Enum.filter(@sources, &(File.read!(&1) =~ @affected))

    assert offenders == [],
           "an affected cloak module makes an ignored advisory in mix.exs reachable"
  end
end
