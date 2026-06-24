defmodule Loopctl.HeavyReadGuardTest do
  @moduledoc """
  Build guard (AC-27.11.4): the dedicated BYPASSRLS heavy-read pool may only be
  reached through `Loopctl.HeavyRead`, which structurally requires a tenant_id
  filter. This test fails if any `lib/` module other than the wrapper (or the repo
  module itself) calls `Loopctl.HeavyReadRepo.{all,one,stream,...}` directly — so a
  new heavy read cannot bypass the tenant guard by construction.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib", __DIR__)
  @allowed [
    "lib/loopctl/heavy_read.ex",
    "lib/loopctl/heavy_read_repo.ex"
  ]

  test "no lib/ module calls Loopctl.HeavyReadRepo directly except the sanctioned wrapper" do
    offenders =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        rel = Path.relative_to(path, Path.expand("..", @lib_root))
        rel in @allowed
      end)
      |> Enum.filter(fn path ->
        path |> File.read!() |> String.contains?("HeavyReadRepo.")
      end)
      |> Enum.map(&Path.relative_to(&1, Path.expand("..", @lib_root)))

    assert offenders == [],
           "These modules call Loopctl.HeavyReadRepo directly — route them through " <>
             "Loopctl.HeavyRead instead (it enforces the tenant_id filter): " <>
             inspect(offenders)
  end
end
