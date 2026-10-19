defmodule Loopctl.Telemetry.SyntheticRepoEventHygieneTest do
  @moduledoc """
  A test that emits a synthetic repo query event builds its metadata with
  `Loopctl.TelemetryHelpers.repo_query_metadata/1`.

  `[:loopctl, :repo | :admin_repo | :heavy_read_repo, :query]` is a VM-wide event name, so a
  synthetic emission reaches every handler a concurrent test has attached. Handlers match on
  the `:query` key a real Ecto event always carries; an emission without it raised
  `function_clause`, telemetry detached the handler, and an unrelated test failed (CI run
  39188596361 on PR #995). This scans the test tree's source for such emissions and fails on
  one whose metadata argument is anything but a `repo_query_metadata` call.
  """

  use ExUnit.Case, async: true

  @repo_events [:repo, :admin_repo, :heavy_read_repo]

  test "every synthetic repo query emission carries real-shaped metadata" do
    files = Path.wildcard("test/**/*.{ex,exs}")
    assert files != []

    emissions = Enum.flat_map(files, &emissions/1)

    # The scan must reach the emitters it exists for, or it passes vacuously.
    assert Enum.any?(emissions, fn {file, _line, _ok?} ->
             String.ends_with?(file, "scale_metrics_test.exs")
           end)

    offenders = for {file, line, false} <- emissions, do: "#{file}:#{line}"

    assert offenders == [],
           "synthetic repo query events must build metadata with " <>
             "TelemetryHelpers.repo_query_metadata/1: #{Enum.join(offenders, ", ")}"
  end

  defp emissions(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted(columns: false)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [:telemetry, :execute]}, meta, [[:loopctl, repo, :query], _m, metadata]} = node,
        acc
        when repo in @repo_events ->
          {node, [{file, meta[:line], metadata_call?(metadata)} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp metadata_call?({{:., _, [_alias, :repo_query_metadata]}, _, _args}), do: true
  defp metadata_call?({:repo_query_metadata, _, _args}), do: true
  defp metadata_call?(_other), do: false
end
