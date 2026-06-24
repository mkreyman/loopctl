defmodule Loopctl.HeavyReadGuardTest do
  @moduledoc """
  Build guard (AC-27.11.4): the dedicated BYPASSRLS heavy-read pool may only be
  reached through `Loopctl.HeavyRead`, which structurally requires a tenant_id
  equality. This test fails if any `lib/` module other than the wrapper (or the repo
  module itself) either calls `Loopctl.HeavyReadRepo.*` directly OR aliases
  `Loopctl.HeavyReadRepo` (the alias would let `HR.all(...)` evade a literal
  `HeavyReadRepo.` scan) — so a new heavy read cannot bypass the tenant guard by
  construction. Comment-only lines are ignored to avoid false positives on docs.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib", __DIR__)
  @repo_dir Path.expand("..", @lib_root)
  @allowed [
    "lib/loopctl/heavy_read.ex",
    "lib/loopctl/heavy_read_repo.ex"
  ]

  test "no lib/ module reaches Loopctl.HeavyReadRepo directly except the sanctioned wrapper" do
    offenders =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(Path.relative_to(&1, @repo_dir) in @allowed))
      |> Enum.filter(&references_heavy_read_repo?/1)
      |> Enum.map(&Path.relative_to(&1, @repo_dir))

    assert offenders == [],
           "These modules reach Loopctl.HeavyReadRepo (direct call or alias) — route them " <>
             "through Loopctl.HeavyRead instead (it enforces the tenant_id equality): " <>
             inspect(offenders)
  end

  # A reference is a non-comment line that either calls `HeavyReadRepo.` or aliases it.
  defp references_heavy_read_repo?(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    |> Enum.any?(fn line ->
      String.contains?(line, "HeavyReadRepo.") or
        String.contains?(line, "alias Loopctl.HeavyReadRepo")
    end)
  end
end
