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

  This guard scans the config SOURCE (so it covers `config/runtime.exs`, the PROD-only file
  that `Application.get_env` never reflects during `mix test` — i.e. the exact file the bug
  lived in) and fails the build if any `parameters: [...]` list carries a key outside the
  pgbouncer-safe allowlist. A server-side `statement_timeout` must instead be applied
  per-read via `SET LOCAL` inside a transaction (`Loopctl.HeavyRead`), the pgbouncer-safe
  path. The pgbouncer-safe escape hatch for a server GUC at connect is the `options` startup
  parameter (allowlisted), not a bare GUC key.
  """
  use ExUnit.Case, async: true

  # Startup parameters pgbouncer forwards/accepts (its default tracked set + the `options`
  # escape hatch). Everything else — `statement_timeout`, `lock_timeout`,
  # `idle_in_transaction_session_timeout`, any pgvector custom GUC like `hnsw.ef_search` —
  # is rejected with 08P01 and MUST NOT appear in an Ecto repo `:parameters` list.
  @pgbouncer_safe_startup_params ~w(
    application_name
    client_encoding
    datestyle
    timezone
    standard_conforming_strings
    extra_float_digits
    search_path
    options
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
      synthetic = ~s(  parameters: [statement_timeout: "10000"])
      assert [{_inner, keys}] = scan_parameter_lists(synthetic)
      assert "statement_timeout" in keys
      assert "statement_timeout" not in @pgbouncer_safe_startup_params
    end

    test "the scanner IGNORES comment lines (no false positive on documentation)" do
      # The config files DOCUMENT the forbidden shape in comments (e.g. "no
      # `parameters: [statement_timeout: ...]` here"). Those must not trip the guard.
      commented = ~s(  # NO parameters: [statement_timeout: ...] here — pgbouncer rejects it)
      assert scan_parameter_lists(commented) == []
    end
  end

  # Extract every `parameters: [ ... ]` list from a config file (comments stripped) as
  # `{inner_text, [key_strings]}`.
  defp parameter_lists(file) do
    file |> File.read!() |> scan_parameter_lists()
  end

  defp scan_parameter_lists(source) do
    source
    |> strip_comment_lines()
    |> then(&Regex.scan(~r/parameters:\s*\[(.*?)\]/s, &1))
    |> Enum.map(fn [_full, inner] ->
      keys = ~r/(\w+):/ |> Regex.scan(inner) |> Enum.map(fn [_, key] -> key end)
      {String.trim(inner), keys}
    end)
  end

  # Drop whole-line comments so documentation that mentions the forbidden shape can't
  # false-positive. Inline trailing comments after real code are harmless: the `parameters`
  # list closes before any `#`.
  defp strip_comment_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&(&1 =~ ~r/^\s*#/))
    |> Enum.join("\n")
  end
end
