defmodule Loopctl.Delivery.StagesNestingGuardTest do
  @moduledoc """
  A SOURCE guard for the one defect class this suite is structurally blind to.

  `Loopctl.Repo.with_tenant/2` refuses to be nested inside a `Repo` transaction, and
  `Loopctl.Delivery.Stages.advance/4` calls it — so a caller that wraps `advance/4` in
  `Repo.transaction/1` raises in production. No test can catch that by RUNNING it:
  `Loopctl.Repo`'s own comment says the guard is inert under the SQL sandbox, "i.e. for the
  entire test suite ... actual nesting must be verified by inspection or in dev/prod".

  "By inspection" is not a mechanism, and it failed the first time it was relied on: contract
  1.9.0's verdict path shipped through a review with `Stages.advance/4` inside a
  `Repo.transaction/1`, green on every test, and would have raised out of `handle_in/3` on the
  first real verdict and taken the channel down with every session on it.

  So this reads the SOURCE instead. It is deliberately crude — it flags a file that calls both
  in the same module rather than proving a call path — because the realistic mistake is
  writing the two together, and a guard that only catches what a whole-program analysis could
  prove would catch nothing at all.

  ## If this fails

  Do not wrap the transition. `Stages.advance/4` owns its transaction by design, so the fix is
  to sequence the work and make the RETRY converge — which is what `Loopctl.Delivery.TriageVerdict`
  does: it records first, transitions second, and its replay path re-attempts the transitions
  rather than trusting the record.

  The allow-list is empty and should stay that way: no module legitimately wraps a transition.
  """

  use ExUnit.Case, async: true

  # Files allowed to contain both, with the reason. Empty today, and that is the point: no
  # module legitimately wraps a transition. An entry here needs a reason a reader can check.
  @allowed %{}

  # The same, for the nesting scan below. Empty, and with an AST predicate it should stay that
  # way: nothing legitimately opens a tenant scope and then asks `Stages` to open another
  # inside it — the row is readable inline from the scope you already hold.
  @allowed_nesting %{}

  test "no module calls a tenant-scoping Stages function from inside a tenant scope" do
    # THE SAME CLASS ONE CALL DEEPER, and the widening is paid for: #847 round 2 found
    # `Stages.get/2` called from inside a `Repo.with_tenant/2` this module had opened itself.
    # `get/2` opens one of its own, `assert_not_nested!/2` raises on that in production, and
    # the sandbox makes it inert — so an accepted triage verdict would have raised out of
    # `handle_in/3` on the first real message, with the whole suite green.
    #
    # The scan is the same crude shape and for the same reason: a file that opens a tenant
    # scope AND calls one of the `Stages` functions that opens its own is the realistic
    # mistake. Reading the row inline is the fix, which is what that module does now.
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(&1 |> File.read!() |> nests_tenant_scope?()))
      |> Enum.reject(&Map.has_key?(@allowed_nesting, &1))

    assert offenders == [],
           """
           These files open Repo.with_tenant/2 AND call a Stages function that opens one:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}

           Read the row inline against StoryStage inside the scope you already hold.
           """
  end

  test "the NESTING predicate catches the shape the bug actually had" do
    # DIRECTLY inside the block.
    assert nests_tenant_scope?("""
           def f do
             Repo.with_tenant(tenant_id, fn -> Stages.get(tenant_id, story_id) end)
           end
           """)

    # ONE HELPER DEEP, which is how #847 was written and what a lexical-only scan misses.
    assert nests_tenant_scope?("""
           def f do
             Repo.with_tenant(tenant_id, fn -> stage_of(tenant_id, story_id) end)
           end

           defp stage_of(tenant_id, story_id), do: Stages.get(tenant_id, story_id)
           """)

    # TWO deep, to prove the closure is a closure rather than one hop.
    assert nests_tenant_scope?("""
           def f, do: Repo.with_tenant(tenant_id, fn -> a(tenant_id) end)
           defp a(tenant_id), do: b(tenant_id)
           defp b(tenant_id), do: Stages.open(tenant_id, story_id, [])
           """)

    # And the two shapes that are FINE, which is what the substring version got wrong: the
    # scope and the call in different functions, and a scope that reads its own rows.
    refute nests_tenant_scope?("""
           def f, do: Repo.with_tenant(tenant_id, fn -> Repo.one(q) end)
           defp g(tenant_id, story_id), do: Stages.get(tenant_id, story_id)
           """)

    refute nests_tenant_scope?("def f, do: Stages.get(tenant_id, story_id)")

    # THROUGH A LOCAL WRAPPER, which is the shape #847 actually had and the one two earlier
    # versions of this predicate walked straight past: the scope is opened by a one-line local
    # that takes the work as a closure, so the literal `with_tenant` call's arguments are a
    # bare variable and carry nothing to inspect.
    assert nests_tenant_scope?("""
           def f, do: in_tenant(tenant_id, fn -> stage_of(tenant_id, story_id) end)
           defp in_tenant(tenant_id, fun), do: Repo.with_tenant(tenant_id, fun)
           defp stage_of(tenant_id, story_id), do: Stages.get(tenant_id, story_id)
           """)

    refute nests_tenant_scope?("""
           def f, do: in_tenant(tenant_id, fn -> Repo.one(q) end)
           defp in_tenant(tenant_id, fun), do: Repo.with_tenant(tenant_id, fun)
           defp stage_of(tenant_id, story_id), do: Stages.get(tenant_id, story_id)
           """)
  end

  # AST, AND IT FOLLOWS LOCAL CALLS, which is the whole difference between a guard that works
  # and one that reads well. Two cruder versions were tried on the way here:
  #
  #   * substring-matching a file for both `Repo.with_tenant(` and `Stages.get(` flagged three
  #     files, two of which do the two things in DIFFERENT functions and are perfectly fine;
  #   * matching only what is LEXICALLY inside the `with_tenant` block caught nothing at all —
  #     verified by mutation, and the reason is the bug's own shape: #847's defect was a call
  #     to a one-line local helper that called `Stages.get/2`, which is how anyone would write
  #     it.
  #
  # So this builds the set of local functions that reach a scoping `Stages` call — transitively
  # within the file — and then flags a `with_tenant` block that calls Stages directly OR calls
  # one of them. `get/2`, `open/3` and `list/2` each open a `Repo.with_tenant/2` of their own.
  @scoping_stages_functions ~w(get open list)a

  defp nests_tenant_scope?(source) when is_binary(source) do
    ast = Code.string_to_quoted!(source)
    reaching = locals_reaching_stages(ast)
    openers = locals_opening_a_scope(ast)

    ast
    |> scope_openings(openers)
    |> Enum.any?(&reaches_stages?(&1, reaching))
  end

  # Local function names whose bodies reach a scoping `Stages` call, to a fixpoint: a helper
  # that calls a helper that calls `Stages.get/2` is in the set.
  defp locals_reaching_stages(ast) do
    definitions = local_definitions(ast)

    Enum.reduce_while(1..10, MapSet.new(), fn _pass, acc ->
      next =
        for {name, body} <- definitions,
            reaches_stages?(body, acc),
            into: acc,
            do: name

      if MapSet.equal?(next, acc), do: {:halt, acc}, else: {:cont, next}
    end)
  end

  # A CALL, not a keyword. `{name, meta, args}` is also the shape of `when`, `fn`, `case`, a
  # block and every operator — and `when` in particular put itself into both closures on the
  # first run (a multi-clause guard), which then made every function in the file "reach"
  # everything and flagged a file that nests nothing.
  @not_calls ~w(when fn -> __block__ __aliases__ %{} {} <<>> . try case cond if unless with
                for receive quote unquote)a

  defp local_call?(name, args) do
    name not in @not_calls and not Macro.operator?(name, length(args))
  end

  defp local_definitions(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {def_kind, _, [{name, _, _args}, body]} = node, acc when def_kind in [:def, :defp] ->
          {node, [{name, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    defs
  end

  # THE ARGUMENTS OF EVERY SCOPE OPENING, and a local wrapper counts as one. This is the third
  # thing the guard had to learn: the defect it exists for goes through `in_tenant/2`, a
  # one-line local that wraps `Repo.with_tenant/2` and takes the work as a closure — so the
  # literal `with_tenant` call's own arguments are just a variable, and looking only at those
  # sees nothing. What carries the work is the CLOSURE handed to the wrapper.
  defp scope_openings(ast, openers) do
    {_ast, args} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Repo]}, :with_tenant]}, _, call_args} = node, acc ->
          {node, [call_args | acc]}

        {name, _, call_args} = node, acc when is_atom(name) and is_list(call_args) ->
          if local_call?(name, call_args) and MapSet.member?(openers, name),
            do: {node, [call_args | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    args
  end

  # Local functions that open a tenant scope, transitively — `in_tenant/2` and anything that
  # wraps it in turn.
  defp locals_opening_a_scope(ast) do
    definitions = local_definitions(ast)

    Enum.reduce_while(1..10, MapSet.new(), fn _pass, acc ->
      next =
        for {name, body} <- definitions,
            opens_a_scope?(body, acc),
            into: acc,
            do: name

      if MapSet.equal?(next, acc), do: {:halt, acc}, else: {:cont, next}
    end)
  end

  defp opens_a_scope?(ast, openers) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Repo]}, :with_tenant]}, _, _args} = node, _acc ->
          {node, true}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, acc or (local_call?(name, args) and MapSet.member?(openers, name))}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp reaches_stages?(ast, reaching) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Stages]}, fun]}, _, _args} = node, _acc
        when fun in @scoping_stages_functions ->
          {node, true}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, acc or (local_call?(name, args) and MapSet.member?(reaching, name))}

        node, acc ->
          {node, acc}
      end)

    found
  end

  test "no module wraps Stages.advance/4 in a Repo transaction" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(&1 |> File.read!() |> calls_both?()))
      |> Enum.reject(&Map.has_key?(@allowed, &1))

    assert offenders == [],
           """
           These files call Stages.advance/4 AND open a Repo transaction:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}

           `advance/4` calls `Repo.with_tenant/2`, which raises when nested — and the SQL
           sandbox makes that guard inert, so every test will pass while production crashes.
           Sequence the work and make the retry converge instead; see this module's doc.
           """
  end

  test "the PREDICATE is not vacuous, on sources written for it" do
    # The scan clears every file in `lib/`, so on its own it is indistinguishable from a
    # predicate that matches nothing — which is the inert-guard shape this whole file exists
    # to prevent, one level up. There is no real file that legitimately does both, so the
    # positive control is written here rather than allow-listed.
    assert calls_both?("""
           def f do
             Repo.transaction(fn -> Stages.advance(tenant_id, story_id, t, opts) end)
           end
           """)

    refute calls_both?("def f, do: Stages.advance(tenant_id, story_id, t, opts)")
    refute calls_both?("def f, do: Repo.transaction(fn -> Repo.insert(changeset) end)")
  end

  defp calls_both?(source) when is_binary(source) do
    String.contains?(source, "Stages.advance(") and String.contains?(source, "Repo.transaction(")
  end
end
