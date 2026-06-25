defmodule Loopctl.Credo.Check.CosineQueryReintroduction do
  @moduledoc """
  Custom Credo check (US-27.8, AC-27.8.5): the cosine-`<=>` reintroduction guard.

  ## What it catches

  The `suggested_links` 500 shipped three times (#168/#170/#172) because a
  hand-rolled cosine `ORDER BY embedding <=> $const` / distance query defeated the
  HNSW index at prod scale. US-27.7a routed every single-target top-k through the
  ONE sanctioned helper, `Loopctl.Knowledge.VectorSearch`, whose SQL shape is
  scale-gated. This check makes "no new hand-rolled cosine site outside the helper"
  a STANDING CI property: if a future edit reintroduces a raw `<=>` somewhere new,
  `mix credo --strict` fails — at PR time, not in prod.

  ## How it detects (pure AST, no process, no DB)

  A cosine `<=>` only ever appears in loopctl source inside a **string literal**
  passed to `fragment(...)` / raw SQL (e.g. `"? <=> ?"`, `"(? <=> ?) BETWEEN ..."`,
  `"MIN(? <=> ?::vector)"`). So the check walks the source AST (`Credo.Code.prewalk`
  is NOT used directly; we descend manually to keep each `<=>` attributed to its
  ENCLOSING `def`/`defp`) and collects every binary-string node whose value contains
  `"<=>"`, resolving for each:

    * the enclosing `def`/`defp` **name + arity** (the nearest such ancestor — loopctl
      never nests `def`s, so attribution is unambiguous), and
    * the **module** (the file's `defmodule`).

  ## Exemptions (the allowlist exempts the LINT, never the scale gate)

  1. The whole `Loopctl.Knowledge.VectorSearch` module — it IS the sanctioned home of
     the top-k `<=>` literal (`candidate_pool_query/4` + the two `pool_select/3`
     similarity projections), so every `<=>` there is expected.
  2. Any `{module, fun, arity}` registered in
     `Loopctl.Knowledge.CosineLintExceptions` with a NON-EMPTY rationale — the
     auditable list of the deliberately-different shapes that cannot route through
     `nearest/4` (`do_distant_pairs/7` column-to-column self-join,
     `novelty_distance_query/4` MIN-aggregate, and `nearest_prior_distance/4` its
     documented owner).

  This check reads the allowlist as **data** — `CosineLintExceptions.exceptions/0`
  folded into a MapSet once per `run/2` — rather than calling `registered?/3` per site,
  so there is no fragile runtime-call-from-a-check assumption (the constant is read at
  Credo runtime, after `mix compile`, when the module is loaded). The non-empty-rationale
  rule is honored: a blank rationale does NOT suppress (the entry never enters the set).

  CRITICAL: this allowlist exempts only the LINT location. It does NOT exempt a bad
  query shape from the scale plan-gate — an index-defeating change inside an allowlisted
  function still fails `PlanAssertions.refute_full_scan`/`refute_seq_scan` at 80k
  (proven by `cosine_lint_vs_scale_gate_scale_test.exs`).

  Anything else → an issue naming the offending `M.f/a`, telling the author to route it
  through `Loopctl.Knowledge.VectorSearch` or, if it is a justified exception, register
  it (with a rationale) in `Loopctl.Knowledge.CosineLintExceptions`.
  """

  use Credo.Check,
    id: "LOOPCTL_COSINE_REINTRODUCTION",
    category: :warning,
    base_priority: :high,
    explanations: [
      check: """
      A hand-rolled cosine `<=>` distance / ORDER BY outside the shared
      `Loopctl.Knowledge.VectorSearch` helper is forbidden: that exact SQL shape is
      what defeated the HNSW index and shipped the `suggested_links` 500 three times
      (#168/#170/#172). Route single-target top-k similarity through
      `Loopctl.Knowledge.VectorSearch` (its shape is scale-gated). If the site is a
      genuinely-different shape that cannot use `nearest/4` (a column-to-column
      self-join, or a MIN aggregate), register it — with a one-line rationale — in
      `Loopctl.Knowledge.CosineLintExceptions`, which this check reads as its allowlist.
      """
    ]

  alias Loopctl.Knowledge.CosineLintExceptions

  # The module that legitimately HOSTS the top-k `<=>` literal — exempt wholesale.
  @vector_search_module Loopctl.Knowledge.VectorSearch

  @doc false
  def run(%Credo.SourceFile{} = source_file, params \\ []) do
    if lib_source?(source_file) do
      run_on_lib_source(source_file, params)
    else
      # The guard governs PRODUCTION query paths (`lib/`). `test/` builds deliberate
      # raw probe queries (e.g. the under-fill gate's index-ordered `<=>` scan that
      # models the exact rows the ANN draws) — those are test scaffolding, not the
      # production rot this guard prevents, so they are out of scope.
      []
    end
  end

  # Only `lib/` source files are governed (AC-27.8.5 targets `lib/loopctl`). Match on
  # the path so `test/`, `priv/`, `.credo/`, etc. are skipped. The check's own source
  # lives under `.credo/` and is excluded here too (it would otherwise self-flag the
  # `@sql_call_names`/doc `<=>` text — though detection is fragment-scoped, this is an
  # explicit belt-and-braces).
  defp lib_source?(%Credo.SourceFile{filename: filename}) when is_binary(filename) do
    normalized = String.replace(filename, "\\", "/")
    String.starts_with?(normalized, "lib/") or String.contains?(normalized, "/lib/")
  end

  defp lib_source?(_), do: false

  defp run_on_lib_source(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    allowlist = allowlisted_mfa_set()

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        module = defmodule_name(ast)

        if module == @vector_search_module do
          # The helper's home — every `<=>` here is the sanctioned shape.
          []
        else
          ast
          |> cosine_sites(module)
          |> Enum.reject(fn site ->
            MapSet.member?(allowlist, {site.module, site.fun, site.arity})
          end)
          |> Enum.map(&issue_for(issue_meta, &1))
        end

      # An unparseable file is another check's problem (Credo reports the parse
      # error itself); we simply find nothing to flag here.
      _ ->
        []
    end
  end

  # The set of `{module, fun, arity}` whose rationale is non-empty — read from the
  # auditable registry as DATA (no per-site runtime call). Mirrors
  # `CosineLintExceptions.registered?/3`'s non-empty-rationale rule so a blank
  # rationale can never silently suppress.
  defp allowlisted_mfa_set do
    # `mix credo` does not boot the app, so the compiled registry beam is on the code
    # path but not yet loaded — `ensure_loaded/1` loads it from `_build`. It is plain
    # `lib/` code (no app start needed), so this is safe and process-free. If it could
    # NOT be loaded (it always can in dev/test), we FAIL CLOSED by raising rather than
    # returning an empty set that would mis-flag the registered exceptions.
    case Code.ensure_loaded(CosineLintExceptions) do
      {:module, _} ->
        CosineLintExceptions.exceptions()
        |> Enum.filter(&non_empty_rationale?/1)
        |> Enum.map(fn %{module: m, function: f, arity: a} -> {m, f, a} end)
        |> MapSet.new()

      {:error, reason} ->
        raise "#{inspect(__MODULE__)} could not load " <>
                "#{inspect(CosineLintExceptions)} (the cosine-lint allowlist): " <>
                "#{inspect(reason)}. The check cannot run without its allowlist."
    end
  end

  defp non_empty_rationale?(%{rationale: r}) when is_binary(r), do: String.trim(r) != ""
  defp non_empty_rationale?(_), do: false

  # The file's `defmodule` name (loopctl is one-module-per-file). nil if none.
  defp defmodule_name(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, nil when is_list(parts) ->
          {node, Module.concat(parts)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # Collect every cosine `<=>` site, attributed to its ENCLOSING `def`/`defp` (name +
  # arity). We descend manually (NOT `prewalk`-flatten) so each site keeps its function
  # scope AND the line of its enclosing call.
  #
  # DETECTION IS SCOPED TO SQL-BEARING CALLS — a binary containing `<=>` is flagged
  # ONLY when it is the (first) argument of a `fragment(...)` call or a `*.query!`/
  # `query`/`explain` raw-SQL call. This is deliberate: a `<=>` in a `@moduledoc`,
  # `@doc`, comment, rationale-data string, or a Regex is documentation/data, NOT a
  # hand-rolled query, and must NOT be flagged (those are how the allowlist, the plan
  # assertions, and this very check DESCRIBE the operator). loopctl's every real cosine
  # query goes through `fragment/_`, so this is both precise and complete for the rot
  # the guard targets. A `<=>` site outside any `def` is still reported (`fun: nil`).
  defp cosine_sites(ast, module) do
    do_collect(ast, module, nil, nil, [])
    |> Enum.reverse()
  end

  # SQL-bearing call names whose string arguments are real query text (where a `<=>`
  # is a hand-rolled cosine site), as opposed to docstrings / data / regex literals.
  @sql_call_names [:fragment, :query, :query!, :explain]

  # State threaded down the walk:
  #   * `scope` — the current `{fun, arity}` (nil at module level), set on `def`/`defp`.
  #   * `line`  — the nearest ancestor call node's `meta[:line]`, stamped on a site.
  defp do_collect({op, meta, [head | _] = args}, module, _scope, _line, acc)
       when op in [:def, :defp] do
    new_scope = def_scope(head)
    new_line = meta[:line]

    Enum.reduce(args, acc, fn child, inner ->
      do_collect(child, module, new_scope, new_line, inner)
    end)
  end

  # A SQL-bearing call: `fragment("…<=>…", …)`, `Repo.query!("…<=>…", …)`, etc. The
  # call name may be bare (`{:fragment, _, args}`) or qualified
  # (`{{:., _, [_mod, :query!]}, _, args}`). If ANY string arg holds `<=>`, record one
  # site (the call's line), then keep descending so nested cosine fragments are caught.
  defp do_collect({form, meta, children} = node, module, scope, line, acc)
       when is_list(children) do
    call_line = meta[:line] || line

    acc =
      if sql_call?(form) and Enum.any?(children, &cosine_string?/1) do
        {fun, arity} = scope || {nil, nil}
        [%{module: module, fun: fun, arity: arity, line: call_line, trigger: "<=>"} | acc]
      else
        acc
      end

    children = elem(node, 2)

    Enum.reduce(children, acc, fn child, inner ->
      do_collect(child, module, scope, call_line, inner)
    end)
  end

  defp do_collect({left, right}, module, scope, line, acc) do
    acc
    |> then(&do_collect(left, module, scope, line, &1))
    |> then(&do_collect(right, module, scope, line, &1))
  end

  defp do_collect(list, module, scope, line, acc) when is_list(list) do
    Enum.reduce(list, acc, fn child, inner -> do_collect(child, module, scope, line, inner) end)
  end

  defp do_collect(_other, _module, _scope, _line, acc), do: acc

  # A bare call name (`fragment`) or a qualified one (`Repo.query!`) whose final name
  # is in @sql_call_names.
  defp sql_call?(name) when is_atom(name), do: name in @sql_call_names
  defp sql_call?({:., _, [_target, name]}) when is_atom(name), do: name in @sql_call_names
  defp sql_call?(_), do: false

  # True for a binary AST literal containing the cosine operator. (String literals are
  # plain binaries in quoted AST; interpolated strings are `{:<<>>, …}` and never carry
  # a raw `<=>` segment for our SQL purposes — fragment SQL is always a plain literal.)
  defp cosine_string?(node) when is_binary(node), do: String.contains?(node, "<=>")
  defp cosine_string?(_), do: false

  # Resolve a `def`/`defp` head to `{name, arity}`. Handles guard heads
  # (`def f(x) when g`), zero-arity (`def f`/`def f()`), and the parenthesised forms.
  defp def_scope({:when, _, [inner | _]}), do: def_scope(inner)
  defp def_scope({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp def_scope({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, 0}
  defp def_scope(_), do: {nil, nil}

  defp issue_for(issue_meta, %{module: module, fun: fun, arity: arity} = site) do
    mfa = format_mfa(module, fun, arity)

    message =
      "hand-rolled cosine `<=>` in #{mfa} outside Loopctl.Knowledge.VectorSearch — " <>
        "route single-target top-k similarity through the shared helper " <>
        "(Loopctl.Knowledge.VectorSearch), or, if it is a justified exception " <>
        "(column-to-column self-join / MIN aggregate), register it with a rationale " <>
        "in Loopctl.Knowledge.CosineLintExceptions."

    opts =
      [message: message, trigger: site.trigger]
      |> maybe_put_line(site.line)

    format_issue(issue_meta, opts)
  end

  defp maybe_put_line(opts, line) when is_integer(line), do: Keyword.put(opts, :line_no, line)
  defp maybe_put_line(opts, _), do: opts

  defp format_mfa(module, nil, _arity), do: "#{inspect(module)} (module-level)"

  defp format_mfa(module, fun, arity),
    do: "#{inspect(module)}.#{fun}/#{arity}"
end
