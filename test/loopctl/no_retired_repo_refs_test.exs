defmodule Loopctl.NoRetiredRepoRefsTest do
  @moduledoc """
  TC-52.11.5 (US-52.11): no tracked file points anyone at the retired repositories
  (mkreyman/chg, mkreyman/loopctl-runner) or at their old checkout paths.

  The allowlist holds the files that carry the migration itself. `test/`, `mcp-server/test/`
  and `chg/tests/` are outside the scan: their fixtures use the names as sample data and point
  nobody at a repository. A name followed at once by `#<digits>` cites an issue, which the
  archived repository still serves, so it is not an offence.
  """
  use ExUnit.Case, async: true

  @pattern ~r{mkreyman/chg|mkreyman/loopctl-runner|workspace/chg|workspace/loopctl-runner}
  @citation ~r{(mkreyman/chg|mkreyman/loopctl-runner)#\d+}

  @allowed [
    "release/imports.toml",
    "release/manifest.toml",
    "release/install-machine.sh",
    "release/retire-repo.sh",
    "release/lib/rewrite_runner_config.py",
    "chg/bin/chg-loop.py",
    "CHANGELOG.md",
    "test/loopctl/no_retired_repo_refs_test.exs"
  ]
  @allowed_dirs ["docs/factory/", "docs/user_stories/", "test/", "mcp-server/test/", "chg/tests/"]

  test "no tracked file outside the allowlist names a retired repo or its old path" do
    {files, 0} = System.cmd("git", ["ls-files", "-z"], cd: File.cwd!())

    offences =
      files
      |> String.split(<<0>>, trim: true)
      |> Enum.reject(&allowed?/1)
      |> Enum.flat_map(&offences_in/1)

    assert offences == [],
           "stale references to retired repositories:\n" <> Enum.join(offences, "\n")
  end

  test "the scan sees a stale reference and passes an issue citation" do
    assert offence?("clone it with git -C ~/workspace/chg pull")
    assert offence?("lives in mkreyman/loopctl-runner")
    refute offence?("confirmed on mkreyman/chg#33")
  end

  defp allowed?(path),
    do: path in @allowed or Enum.any?(@allowed_dirs, &String.starts_with?(path, &1))

  defp offences_in(path) do
    case File.read(path) do
      {:ok, body} -> if String.valid?(body), do: line_offences(path, body), else: []
      {:error, _} -> []
    end
  end

  defp line_offences(path, body) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> offence?(line) end)
    |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{String.trim(line)}" end)
  end

  defp offence?(line),
    do: Regex.match?(@pattern, Regex.replace(@citation, line, ""))
end
