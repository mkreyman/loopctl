defmodule Loopctl.ConfigPgbouncerSafeParametersTest do
  @moduledoc """
  US-27.13 regression guard: NO Ecto repo may carry a pgbouncer-INCOMPATIBLE startup
  parameter in its `:parameters` config.

  ## Why this exists (the outage it would have caught)

  Production fronts Postgres with pgbouncer (Fly Managed Postgres). pgbouncer accepts only
  a small allowlist of connection STARTUP parameters and REJECTS anything else with
  `FATAL 08P01 (protocol_violation) unsupported startup parameter: <name>`. US-27.11 set
  `config :loopctl, Loopctl.HeavyReadRepo, parameters: [statement_timeout: ...]` — a startup
  parameter pgbouncer rejects — which crash-looped every HeavyReadRepo connection in prod
  and 503'd every heavy vector/enumeration endpoint (suggested_links, semantic search,
  distant_pairs, novelty, heavy enumeration). It was invisible to the test suite because
  the suite connects to DIRECT Postgres (which ACCEPTS the startup param) and aliases heavy
  reads to AdminRepo — the false confidence that hid it.

  This guard parses the config SOURCE as an AST (so it covers `config/runtime.exs`, the
  PROD-only file that `Application.get_env` never reflects during `mix test` — i.e. the exact
  file the bug lived in) and fails the build if any `parameters: [...]` list carries a key
  outside the pgbouncer-safe allowlist. A server-side `statement_timeout` (or any GUC) must
  instead be applied per-read via `SET LOCAL` inside a transaction (`Loopctl.HeavyRead`), the
  pgbouncer-safe path; a connect-time GUC that must persist is set via `ALTER ROLE` (the
  documented `hnsw.ef_search` lever), NOT a startup parameter.

  AST (not regex) parsing is deliberate: it extracts EVERY top-level key of a `:parameters`
  list — including keys that follow a nested list value (e.g.
  `parameters: [socket_options: [...], statement_timeout: ...]`), which a non-greedy
  `parameters: [(.*?)\]` regex would miss by stopping at the first `]`.

  NB: there is NO startup-parameter escape hatch for a GUC behind pgbouncer. In particular
  `options` (`-c statement_timeout=...`) is NOT safe — Fly MPG's pgbouncer rejects a
  `statement_timeout` smuggled via `options` too (pgbouncer #907), and a GUC set via the
  startup `options` packet leaks across clients under transaction pooling. So `options` is
  deliberately NOT allowlisted.
  """
  use ExUnit.Case, async: true

  # Startup parameters pgbouncer forwards/accepts by DEFAULT (no pgbouncer-side config —
  # which loopctl does not control on Fly MPG). This is the minimal libpq-negotiated set.
  # Everything else — `statement_timeout`, `lock_timeout`,
  # `idle_in_transaction_session_timeout`, any pgvector custom GUC like `hnsw.ef_search`,
  # AND `options` (which can smuggle a GUC and is itself rejected) — is rejected with 08P01
  # and MUST NOT appear in an Ecto repo `:parameters` list.
  @pgbouncer_safe_startup_params ~w(
    application_name
    client_encoding
    datestyle
    timezone
    standard_conforming_strings
  )

  @config_files Path.wildcard("config/*.exs")

  describe "Ecto repo :parameters across ALL config files (incl. runtime.exs)" do
    test "no repo declares a pgbouncer-incompatible startup parameter" do
      assert @config_files != [], "expected to find config/*.exs files to scan"

      violations =
        for file <- @config_files,
            {param_list, keys} <- parameter_lists(file),
            bad = keys -- @pgbouncer_safe_startup_params,
            bad != [] do
          {Path.relative_to_cwd(file), param_list, bad}
        end

      assert violations == [],
             "Found pgbouncer-INCOMPATIBLE startup parameter(s) in Ecto repo `:parameters` — " <>
               "these crash-loop the pool behind pgbouncer (08P01), the US-27.13 outage. " <>
               "Apply a server-side statement_timeout via SET LOCAL (Loopctl.HeavyRead), not a " <>
               "startup parameter:\n" <>
               Enum.map_join(violations, "\n", fn {file, list, bad} ->
                 "  #{file}: parameters: [#{list}] — forbidden key(s): #{inspect(bad)}"
               end)
    end

    test "the scanner is NON-VACUOUS — it flags a synthetic forbidden parameter" do
      # Guard the guard: prove the parser actually extracts keys and would catch the exact
      # US-27.11 regression, so a future refactor can't silently neuter it into a no-op.
      synthetic = ~S|config :loopctl, Foo, parameters: [statement_timeout: "10000"]|
      assert [{_inner, keys}] = scan_parameter_lists(synthetic)
      assert "statement_timeout" in keys
      assert "statement_timeout" not in @pgbouncer_safe_startup_params
    end

    test "the `options` GUC-smuggle is flagged — `options: \"-c statement_timeout=...\"` is NOT a safe escape hatch" do
      # pgbouncer rejects statement_timeout via `options` too (pgbouncer #907), and a GUC set
      # via the startup `options` packet leaks across clients under transaction pooling. The
      # allowlist must NOT bless `options`, or it re-opens the US-27.13 outage class.
      smuggle = ~S|config :loopctl, Foo, parameters: [options: "-c statement_timeout=10000"]|
      assert [{_inner, keys}] = scan_parameter_lists(smuggle)
      assert "options" in keys
      assert "options" not in @pgbouncer_safe_startup_params
    end

    test "the scanner catches a forbidden parameter AFTER a nested list (no `socket_options: [...]` false-negative)" do
      # Regression: a non-greedy `parameters: [(.*?)\]` regex would stop at the first `]`
      # (end of the socket_options list) and MISS statement_timeout. AST parsing extracts
      # every top-level key of the :parameters list regardless of nested-list values.
      nested =
        ~S|config :loopctl, Foo, parameters: [socket_options: [keepalive: true], statement_timeout: "10000"]|

      assert [{_inner, keys}] = scan_parameter_lists(nested)

      assert "statement_timeout" in keys,
             "expected to find statement_timeout even after a nested list value"

      assert "statement_timeout" not in @pgbouncer_safe_startup_params
    end

    test "the scanner IGNORES comments (no false positive on documentation)" do
      # The config files DOCUMENT the forbidden shape in comments. AST parsing drops comments
      # natively, so neither a whole-line nor an inline comment mentioning the shape can trip
      # the guard.
      whole_line = ~S|# NO parameters: [statement_timeout: ...] here — pgbouncer rejects it|

      inline =
        ~S|config :loopctl, Foo, pool_size: 8 # note: parameters: [statement_timeout: "10000"]|

      assert scan_parameter_lists(whole_line) == []
      assert scan_parameter_lists(inline) == []
    end
  end

  # Extract every `parameters: [...]` keyword list from config source. Returns
  # `{rendered_keys, [key_strings]}` per `:parameters` declaration.
  defp parameter_lists(file) do
    file |> File.read!() |> scan_parameter_lists()
  end

  # Parse the source to an AST and walk the WHOLE tree (Macro.prewalk) for any
  # `{:parameters, list}` node — finding `:parameters` whether it sits inside a `config(...)`
  # call (real files) or a bare snippet (the synthetic tests), and extracting ALL top-level
  # keys including those after a nested-list value. config/*.exs is always valid Elixir; on a
  # parse error there is simply nothing to scan (another check owns the syntax error).
  defp scan_parameter_lists(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        {_ast, found} =
          Macro.prewalk(ast, [], fn
            {:parameters, value} = node, acc when is_list(value) ->
              {node, [{render_params(value), param_keys(value)} | acc]}

            node, acc ->
              {node, acc}
          end)

        Enum.reverse(found)

      {:error, _reason} ->
        []
    end
  end

  # The TOP-LEVEL keyword keys of a `:parameters` list, as strings. Only the keys of THIS
  # list — a nested-list value (e.g. `socket_options: [keepalive: true]`) contributes its own
  # key (`socket_options`), never the inner `keepalive`: prewalk visits the inner
  # `{:socket_options, [...]}` node separately, and it is not a `:parameters` node.
  defp param_keys(value) do
    for {k, _v} <- value, is_atom(k), do: Atom.to_string(k)
  end

  defp render_params(value) do
    value |> param_keys() |> Enum.map_join(", ", &"#{&1}: ...")
  end
end
