defmodule Loopctl.Agents.TuningNoSelfEditTest do
  @moduledoc """
  TC-48.13.3 (AC-48.13.4): loopctl never edits a prompt template and never flips a spec
  version. A template version is a compiled literal in one spec module, changed only by a pull
  request a person merges; a tuning draft is DATA a person reads, and nothing turns it into a
  dispatch.

  Every check reads CODE, not prose: the sources are parsed with `Code.string_to_quoted/2` and
  the AST is walked, so a comment or a moduledoc that mentions a write never matches, and every
  scanned set is asserted non-empty so a detector that stopped matching cannot pass vacuously.

  No tenant isolation case: this is a scan of `lib/`, which holds no tenant data.
  """

  use ExUnit.Case, async: true

  @specs_dir "lib/loopctl/agents/specs/"

  # The spec fields that carry a template's identity or the spec's own version.
  @spec_fields [:prompt, :version, :result_schema]

  defp sources, do: Path.wildcard("lib/**/*.ex")

  # The keys of a map update's pairs; string-keyed updates carry no spec field.
  defp update_keys(pairs), do: for({key, _value} when is_atom(key) <- pairs, do: key)

  defp ast(path), do: path |> File.read!() |> Code.string_to_quoted!(columns: false)

  # Every node of `quoted` for which `match` returns a non-nil value, as those values.
  defp collect(quoted, match) do
    {_ast, found} =
      Macro.prewalk(quoted, [], fn node, acc ->
        case match.(node) do
          nil -> {node, acc}
          hit -> {node, [hit | acc]}
        end
      end)

    found
  end

  describe "a template version is a compiled literal of one spec module" do
    test "every `prompt: {id, version}` literal is in a spec module" do
      declaring =
        for path <- sources(),
            collect(ast(path), fn
              {:prompt, {id, version}} when is_binary(id) and is_integer(version) -> true
              _ -> nil
            end) != [],
            do: path

      # Non-vacuous: every spec module declares one, the tuner's included.
      assert length(declaring) == length(Path.wildcard(@specs_dir <> "*.ex"))
      assert "lib/loopctl/agents/specs/spec_tuner_v1.ex" in declaring
      assert Enum.all?(declaring, &String.starts_with?(&1, @specs_dir)), inspect(declaring)
    end

    test "nothing in lib/ rewrites a spec's prompt, version or template at runtime" do
      fields = @spec_fields

      rewrites =
        for path <- sources(),
            hit <-
              collect(ast(path), fn
                # `%Spec{spec | prompt: ...}` and `%{spec | prompt: ...}`
                {:%{}, _, [{:|, _, [_base, pairs]}]} when is_list(pairs) ->
                  Enum.find(update_keys(pairs), &(&1 in fields))

                # `Map.put(spec, :prompt, ...)`, `Map.replace!/3`, `struct(spec, prompt: ...)`
                {{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [_m, key, _v]}
                when fun in [:put, :replace, :replace!] and key in @spec_fields ->
                  key

                _ ->
                  nil
              end),
            do: {path, hit}

      assert rewrites == []
    end

    test "the detector above sees a rewrite when one is there" do
      planted =
        Code.string_to_quoted!(
          "%Spec{spec | prompt: {\"triage\", 2}}\nMap.put(spec, :version, 2)"
        )

      hits =
        collect(planted, fn
          {:%{}, _, [{:|, _, [_base, pairs]}]} when is_list(pairs) ->
            Enum.find(update_keys(pairs), &(&1 in [:prompt, :version]))

          {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [_m, key, _v]} when is_atom(key) ->
            key

          _ ->
            nil
        end)

      assert Enum.sort(hits) == [:prompt, :version]
    end

    test "the registry is read-only: it exports no writer" do
      functions = Keyword.keys(Loopctl.Agents.Registry.__info__(:functions))

      assert :fetch in functions

      refute Enum.any?(
               functions,
               &(Atom.to_string(&1) =~ ~r/put|register|replace|update|set|write/)
             )
    end
  end

  describe "a tuning draft never reaches a dispatch or a file" do
    test "no module in agents/, delivery/ or runners/ writes a file" do
      writers =
        for path <- sources(),
            collect(ast(path), fn
              {{:., _, [{:__aliases__, _, [:File]}, fun]}, _, _args}
              when fun in [:write, :write!, :cp, :cp!, :rename, :rename!, :open, :open!] ->
                fun

              {{:., _, [:file, fun]}, _, _args} when fun in [:write_file, :open] ->
                fun

              _ ->
                nil
            end) != [],
            do: path

      # Non-vacuous: lib/ has file writers (mix tasks, the secrets adapter); none is here.
      assert writers != []

      assert Enum.filter(writers, fn path ->
               Enum.any?(
                 ~w(lib/loopctl/agents/ lib/loopctl/delivery/ lib/loopctl/runners/ lib/loopctl_web/),
                 &String.starts_with?(path, &1)
               )
             end) == []
    end

    test "only the tuning context, its schema, its controller and the router name TuningDraft" do
      readers =
        for path <- sources(),
            collect(ast(path), fn
              {:__aliases__, _, parts} when is_list(parts) ->
                if List.last(parts) in [:TuningDraft, :TuningDraftController], do: true

              _ ->
                nil
            end) != [],
            do: path

      assert Enum.sort(readers) == [
               "lib/loopctl/agents/tuning.ex",
               "lib/loopctl/agents/tuning_draft.ex",
               "lib/loopctl_web/controllers/tuning_draft_controller.ex",
               "lib/loopctl_web/router.ex"
             ]
    end

    test "the landed write changes the draft's status, PR and time, and nothing else" do
      changes =
        collect(ast("lib/loopctl/agents/tuning.ex"), fn
          {{:., _, [{:__aliases__, _, [:Ecto, :Changeset]}, :change]}, _, [_draft, fields]}
          when is_list(fields) ->
            Keyword.keys(fields)

          {:|>, _,
           [_draft, {{:., _, [{:__aliases__, _, [:Ecto, :Changeset]}, :change]}, _, [fields]}]}
          when is_list(fields) ->
            Keyword.keys(fields)

          _ ->
            nil
        end)

      # Two writes in the context: the answer, and the landing. Neither names a template, a
      # spec or a version of either, except the answer's PROPOSED `to_version`, stored as data.
      assert length(changes) == 2
      assert [:status, :pr_url, :landed_at] in changes

      for fields <- changes do
        refute Enum.any?(
                 fields,
                 &(&1 in [:template_id, :from_version, :target_spec_version, :prompt])
               )
      end
    end
  end
end
