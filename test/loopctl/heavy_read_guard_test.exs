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

  # US-37.5 review finding #5: `@known_endpoints` is documented as the SOURCE OF TRUTH the
  # TenantGate weight-drift guard partitions into heavy/light. That guard
  # (`tenant_gate_test.exs`) only checks endpoints ALREADY in `known_endpoints/0`, so an
  # endpoint introduced the `:llm_usage` way — a literal `HeavyRead.opts(:new_endpoint)`
  # call added WITHOUT registering it — escaped the guard and silently got LIGHT weight,
  # under-charging a potentially heavy read. This static scan closes that hole: every
  # literal atom passed to `HeavyRead.opts/1` (directly or via the `heavy_read_opts/1`
  # delegate) across `lib/` MUST be a `known_endpoints/0` member, so registering a new
  # endpoint (and thus making a deliberate heavy/light decision) is unskippable.
  @opts_call_regex ~r/(?:HeavyRead\.opts|heavy_read_opts)\(:([a-z_]+)\)/

  test "every literal HeavyRead.opts(:endpoint) atom in lib/ is a known endpoint" do
    known = MapSet.new(Loopctl.HeavyRead.known_endpoints())

    unregistered =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&opts_endpoint_atoms/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known, &1))

    assert unregistered == [],
           "These endpoint atoms are passed to HeavyRead.opts/1 in lib/ but are NOT in " <>
             "Loopctl.HeavyRead.known_endpoints/0 — register them (with a deliberate " <>
             "heavy/light weight decision in TenantGate) so the drift guard can see them: " <>
             inspect(unregistered)
  end

  # Literal endpoint atoms passed to `opts/1` on non-comment lines of a source file.
  defp opts_endpoint_atoms(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    |> Enum.flat_map(fn line ->
      @opts_call_regex
      |> Regex.scan(line, capture: :all_but_first)
      |> Enum.map(fn [atom] -> String.to_atom(atom) end)
    end)
  end
end
