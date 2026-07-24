defmodule Loopctl.Test.CustodyProfileStub do
  @moduledoc """
  Test double for the custody-profile config source (LCP-1 §9.3 enforcement).

  Reads the profile integer from the PROCESS DICTIONARY, so a test can force the
  `signed` profile for its own process only — async-safe, no VM-global mutation
  (CLAUDE.md test rule 2). Wired via `config :loopctl, :custody_profile_source`
  in `config/test.exs`; a test opts in with `set_profile(:signed)`.
  """

  @key :custody_profile_int

  @doc "Behaviour-shaped: `SignedProfilePolicy` calls this instead of `SystemConfig.get_int/2`."
  def get_int(_key, default), do: Process.get(@key, default)

  @doc "Force the profile for the CURRENT process. `:bearer` clears the override."
  def set_profile(:signed), do: Process.put(@key, 1)
  def set_profile(:bearer), do: Process.delete(@key)
end
