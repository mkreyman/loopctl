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

  A cosine `<=>` reaches the database only inside a SQL string passed to `fragment(...)`
  / a raw `query`/`query!`/`explain` call. So the check walks the source AST (descending
  manually to keep each `<=>` attributed to its enclosing module + `def`/`defp`) and, for
  every SQL-bearing call, DEEP-WALKS its argument subtrees for ANY binary literal
  containing `"<=>"`. The deep walk is deliberate: the `<=>` may be a plain literal
  (`fragment("? <=> ?", …)`), an INTERPOLATED string (`fragment("\#{col} <=> ?", …)` — the
  `<=>` lives in a `{:<<>>, …}` segment), or a CONCATENATION (`fragment("? <=>" <> "?", …)`
  — a `{:<>, …}` node). A shallow direct-child check would MISS the interpolated/concat
  forms (the rot can be written with one interpolated token), so we recurse through the
  arg trees. For each site it resolves:

    * the enclosing `def`/`defp` **name + arity** (the nearest such ancestor), and
    * the **enclosing module** — tracked through `defmodule` nodes during the walk, so a
      site in a NESTED module gets its own full name (`Outer.Inner`) and is exempted on its
      own module (the VectorSearch whole-module exemption can never wholesale-suppress a
      rogue `<=>` in an unrelated module merely nested inside an exempt one).

  ### Residual boundary (documented)

  A `<=>` SQL string assembled in a VARIABLE and then piped into `query!` (`sql = "… <=>
  …"; Repo.query!(sql, …)`) is NOT caught — the call's argument is a var node, not a
  literal, and tracking it would require data-flow analysis. loopctl builds every real
  cosine query via `fragment` literals, so this boundary is currently empty; if a raw-SQL
  var path is ever introduced, register it explicitly (or route it through the helper).

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
        ast
        |> cosine_sites()
        |> Enum.reject(fn site -> exempt?(site, allowlist) end)
        |> Enum.map(&issue_for(issue_meta, &1))

      # An unparseable file is another check's problem (Credo reports the parse
      # error itself); we simply find nothing to flag here.
      _ ->
        []
    end
  end

  # A site is exempt iff its ENCLOSING module is the sanctioned VectorSearch helper
  # (per-MODULE, not per-file — a rogue `<=>` in a module merely nested inside an exempt
  # one is still flagged), OR its `{module, fun, arity}` is in the auditable allowlist.
  defp exempt?(site, allowlist) do
    site.module == @vector_search_module or
      MapSet.member?(allowlist, {site.module, site.fun, site.arity})
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

  # Collect every cosine `<=>` site, attributed to its ENCLOSING module + `def`/`defp`
  # (name + arity). We descend manually (NOT `prewalk`-flatten) so each site keeps its
  # module + function scope AND the line of its enclosing call.
  #
  # DETECTION IS SCOPED TO SQL-BEARING CALLS — a `<=>` is flagged ONLY when it appears in
  # an argument subtree of a `fragment(...)` / `*.query!`/`query`/`explain` raw-SQL call.
  # This is deliberate: a `<=>` in a `@moduledoc`, `@doc`, comment, rationale-data string,
  # or a Regex is documentation/data, NOT a hand-rolled query, and must NOT be flagged
  # (those are how the allowlist, the plan assertions, and this very check DESCRIBE the
  # operator). loopctl's every real cosine query goes through `fragment/_`, so this is both
  # precise and complete for the rot the guard targets. A `<=>` site outside any `def` is
  # still reported (`fun: nil`).
  defp cosine_sites(ast) do
    do_collect(ast, nil, nil, nil, [])
    |> Enum.reverse()
  end

  # SQL-bearing call names whose string arguments are real query text (where a `<=>`
  # is a hand-rolled cosine site), as opposed to docstrings / data / regex literals.
  @sql_call_names [:fragment, :query, :query!, :explain]

  # State threaded down the walk:
  #   * `module` — the current enclosing module (nil before the first `defmodule`).
  #   * `scope`  — the current `{fun, arity}` (nil at module level), set on `def`/`defp`.
  #   * `line`   — the nearest ancestor call node's `meta[:line]`, stamped on a site.

  # Entering a (possibly nested) module sets the module for its body — a NESTED module
  # gets the full concatenated name (`Outer.Inner`) so its sites are attributed and
  # exempted on their OWN module, never wholesale-suppressed by an enclosing exempt one.
  # A new module resets the def scope.
  defp do_collect(
         {:defmodule, _meta, [{:__aliases__, _, parts} | rest]},
         module,
         _scope,
         line,
         acc
       )
       when is_list(parts) do
    new_module = if module, do: Module.concat([module | parts]), else: Module.concat(parts)

    Enum.reduce(rest, acc, fn child, inner ->
      do_collect(child, new_module, nil, line, inner)
    end)
  end

  # A `def`/`defp` sets the `{fun, arity}` scope for its body.
  defp do_collect({op, meta, [head | _] = args}, module, _scope, _line, acc)
       when op in [:def, :defp] do
    new_scope = def_scope(head)
    new_line = meta[:line]

    Enum.reduce(args, acc, fn child, inner ->
      do_collect(child, module, new_scope, new_line, inner)
    end)
  end

  # A SQL-bearing call: `fragment("…<=>…", …)`, `Repo.query!("…<=>…", …)`, etc. (bare or
  # qualified). Record ONE site if ANY argument SUBTREE contains a `<=>` binary —
  # DEEP-WALKED, so an interpolated (`{:<<>>,…}`) or concatenated (`{:<>,…}`) SQL string is
  # caught, not just a plain direct-child literal. Then keep descending so nested cosine
  # fragments are still found.
  defp do_collect({form, meta, children} = node, module, scope, line, acc)
       when is_list(children) do
    call_line = meta[:line] || line

    acc =
      if sql_call?(form) and Enum.any?(children, &arg_has_cosine?/1) do
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

  # Deep-walk an argument subtree for ANY binary literal containing `<=>` — so the cosine
  # operator is caught whether the SQL string is a plain literal, an INTERPOLATED string
  # (a `{:<<>>,…}` node with a `" <=> ?"` segment), or a CONCATENATION (`{:<>,…}`). Gated by
  # `sql_call?` at the call site, so doc/comment/regex/data strings (never SQL-call args)
  # are not examined. A var-held SQL string (not a literal) is the documented residual
  # boundary — there is no literal to find.
  defp arg_has_cosine?(node) when is_binary(node), do: String.contains?(node, "<=>")

  defp arg_has_cosine?({_, _, children}) when is_list(children),
    do: Enum.any?(children, &arg_has_cosine?/1)

  defp arg_has_cosine?({left, right}), do: arg_has_cosine?(left) or arg_has_cosine?(right)
  defp arg_has_cosine?(list) when is_list(list), do: Enum.any?(list, &arg_has_cosine?/1)
  defp arg_has_cosine?(_), do: false

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
