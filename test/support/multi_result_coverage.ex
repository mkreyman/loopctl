defmodule Loopctl.MultiResultCoverage do
  @moduledoc """
  The drift guard behind `Loopctl.Progress.ForceUnclaimResultCoverageTest` and
  `Loopctl.Progress.UnclaimResultCoverageTest`: which steps of an `Ecto.Multi` have NO clause in
  the `case` over `AdminRepo.transaction/1` inside a named function. Read the first of those
  tests' moduledoc for why it reads the steps off the `%Ecto.Multi{}` and the clauses off the
  AST, and for the two bounds it states — both of which fail loud, never silently green.
  """

  @doc "The steps of `multi` that no clause of `fun`'s result `case` in `source` handles."
  @spec uncovered(Ecto.Multi.t(), String.t(), atom()) :: [atom()]
  def uncovered(multi, source, fun) do
    handled = handled_names(source, fun)

    multi |> steps_of() |> Enum.reject(&(&1 in handled)) |> Enum.uniq()
  end

  @doc "The step names, in order, off the operation list itself."
  @spec steps_of(Ecto.Multi.t()) :: [term()]
  def steps_of(multi), do: multi |> Ecto.Multi.to_list() |> Enum.map(&elem(&1, 0))

  @doc """
  The atoms in a POSITION THAT ACTUALLY HANDLES A STEP, read off the AST of the `case` over
  `AdminRepo.transaction/1` inside `fun`. The two positions are the only two that transaction
  offers:

    * the second element of an error clause HEAD — `{:error, :lock, reason, _} ->`, a tuple of
      FOUR elements, which in the AST is `{:{}, _, [:error, :lock, _, _]}`;
    * a member of a `when step in [...]` guard list, which is how one clause covers several.

  Nothing in a clause BODY is ever looked at, and a 2- or 3-element tuple is a different node
  from a 4-element one, so the two things a regex kept miscounting are not reachable.
  """
  @spec handled_names(String.t(), atom()) :: [atom()]
  def handled_names(source, fun) do
    source
    |> Code.string_to_quoted!()
    |> function_body(fun)
    |> transaction_case_clauses()
    |> Enum.flat_map(&clause_names/1)
    |> Enum.uniq()
  end

  defp function_body(ast, name) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [head, body]} = node, acc ->
          if def_name(head) == name, do: {node, body}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp def_name({:when, _, [head | _]}), do: def_name(head)
  defp def_name({name, _, _args}) when is_atom(name), do: name
  defp def_name(_), do: nil

  # ANCHORED ON THE SUBJECT, `AdminRepo.transaction(...)`, rather than on "the first case in
  # the function". A rename there finds no clauses, every step reports uncovered, and the
  # failure names the real problem — the declared bound in the moduledoc.
  defp transaction_case_clauses(nil), do: []

  defp transaction_case_clauses(body) do
    {_ast, clauses} =
      Macro.prewalk(body, [], fn
        {:case, _, [subject, [do: clauses]]} = node, acc ->
          if transaction_call?(subject), do: {node, acc ++ clauses}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    clauses
  end

  defp transaction_call?({{:., _, [{:__aliases__, _, [:AdminRepo]}, :transaction]}, _, _}),
    do: true

  defp transaction_call?(_), do: false

  defp clause_names({:->, _, [[{:when, _, [pattern, guard]}], _body]}) do
    case error_tuple_second(pattern) do
      {:var, var} -> guard_atoms(guard, var)
      {:atom, name} -> [name]
      :none -> []
    end
  end

  defp clause_names({:->, _, [[pattern], _body]}) do
    case error_tuple_second(pattern) do
      {:atom, name} -> [name]
      _ -> []
    end
  end

  defp clause_names(_), do: []

  # A FOUR-OR-MORE element tuple whose first element is `:error`. `{:{}, _, elements}` is the
  # AST for a tuple of any size other than two, so the length check is what excludes the
  # three-element `{:error, :unprocessable_entity, message}` return shape; a two-element
  # `{:error, :atom}` is a plain pair and does not match this head at all.
  defp error_tuple_second({:{}, _, [:error, second | rest]}) when length(rest) >= 2 do
    case second do
      name when is_atom(name) -> {:atom, name}
      {var, _, ctx} when is_atom(var) and is_atom(ctx) -> {:var, var}
      _ -> :none
    end
  end

  defp error_tuple_second(_), do: :none

  defp guard_atoms({:in, _, [{var, _, _}, list]}, var) when is_list(list),
    do: Enum.filter(list, &is_atom/1)

  defp guard_atoms({op, _, args}, var) when op in [:and, :or] and is_list(args),
    do: Enum.flat_map(args, &guard_atoms(&1, var))

  defp guard_atoms(_, _), do: []
end
