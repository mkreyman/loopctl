defmodule Loopctl.DataMigrations.ReserveIdempotencyTagsTest do
  use ExUnit.Case, async: true

  alias Loopctl.DataMigrations.ReserveIdempotencyTags

  # The behavioural tests live in
  # `test/mix/tasks/loopctl_reserve_idempotency_tags_test.exs`, which needs the DB.
  # This file guards the one property that has nothing to do with behaviour: the
  # module must stay callable in a RELEASE, where the :mix application is absent.
  #
  # home_care_billing paid for this rule already —
  # `docs/handoff/2026-07-25-epic-83-status-collapse-release.md`: a Mix task that
  # could not be run against prod data because `Code.ensure_loaded?(Mix) == false`
  # there and it reported through `Mix.shell/0` in seven places. Same shape, same
  # remedy: the logic lives in a Mix-free module, the Mix task is a thin argv
  # wrapper, and a test reads the COMPILED artifact rather than the source, so a
  # reintroduced call cannot hide behind a comment or a string.
  describe "the sweep is callable from a release" do
    test "the compiled module imports nothing from Mix" do
      chunks = beam_chunks()

      imports =
        chunks
        |> Keyword.get(:imports, [])
        |> Enum.map(fn {module, _fun, _arity} -> module end)
        |> Enum.uniq()

      refute imports == [], "read no imports — this test would pass vacuously"

      mix_imports = Enum.filter(imports, &mix_module?/1)

      assert mix_imports == [],
             "#{inspect(ReserveIdempotencyTags)} imports #{inspect(mix_imports)}; " <>
               ":mix does not exist in a release, so this raises mid-sweep in production"
    end

    test "and references no Mix module at all" do
      refs =
        beam_chunks()
        |> Keyword.get(:refs, [])
        |> Enum.map(fn
          {module, _} -> module
          module when is_atom(module) -> module
        end)
        |> Enum.filter(&mix_module?/1)

      assert refs == [], "#{inspect(ReserveIdempotencyTags)} references #{inspect(refs)}"
    end

    test "the Mix task delegates here rather than carrying the sweep" do
      # If the sweep ever moves back into the task, the guards above go quiet
      # while the defect returns — so pin the delegation itself.
      Code.ensure_loaded!(ReserveIdempotencyTags)
      assert function_exported?(ReserveIdempotencyTags, :backfill, 1)

      source = File.read!("lib/mix/tasks/loopctl.reserve_idempotency_tags.ex")
      assert source =~ "ReserveIdempotencyTags.backfill(opts)"
      refute source =~ "defp sweep(", "the sweep belongs in the Mix-free module"
    end

    test "Loopctl.Release exposes it as the production entry point" do
      Code.ensure_loaded!(Loopctl.Release)
      assert function_exported?(Loopctl.Release, :reserve_idempotency_tags, 1)
    end
  end

  defp beam_chunks do
    path = :code.which(ReserveIdempotencyTags)
    refute path == :non_existing, "module is not compiled"

    {:ok, {_module, chunks}} = :beam_lib.chunks(path, [:imports, :refs])
    chunks
  rescue
    _ ->
      path = :code.which(ReserveIdempotencyTags)
      {:ok, {_module, chunks}} = :beam_lib.chunks(path, [:imports])
      chunks
  end

  defp mix_module?(module) do
    module == Mix or String.starts_with?(Atom.to_string(module), "Elixir.Mix.")
  end
end
