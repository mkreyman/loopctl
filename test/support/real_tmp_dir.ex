defmodule Loopctl.RealTmpDir do
  @moduledoc """
  `System.tmp_dir!/0` with every symlink resolved.

  Git reports a repository's toplevel as a PHYSICAL path. On macOS the per-user tmp dir lives
  under `/var`, which is a symlink to `/private/var`, so a fixture created under the unresolved
  path never equals git's answer and every "is this fixture isolated?" guard fires on a fixture
  that is perfectly isolated. Linux CI never sees it because its `/tmp` is not a symlink.

  Build git fixtures under this directory instead of weakening those guards: they compare
  exactly, and they should keep doing so.
  """

  @spec path!() :: String.t()
  def path! do
    {physical, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())
    String.trim(physical)
  end
end
