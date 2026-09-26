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

  @doc "The physical tmp dir, resolved once per VM: the answer cannot change during a run."
  @spec path!() :: String.t()
  def path! do
    case :persistent_term.get({__MODULE__, :path}, nil) do
      nil ->
        path = physical!(System.tmp_dir!())
        :persistent_term.put({__MODULE__, :path}, path)
        path

      path ->
        path
    end
  end

  @doc """
  `dir` with every symlink resolved: what git reports as a toplevel. For the isolation guards,
  which compare a fixture's path with git's answer and must compare the same spelling.
  """
  @spec physical!(String.t()) :: String.t()
  def physical!(dir) do
    case System.cmd("pwd", ["-P"], cd: dir, stderr_to_stdout: true) do
      {physical, 0} -> String.trim_trailing(physical, "\n")
      {output, status} -> raise "pwd -P in #{inspect(dir)} exited #{status}: #{output}"
    end
  end
end
