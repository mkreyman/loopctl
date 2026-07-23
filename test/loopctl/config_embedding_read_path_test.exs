defmodule Loopctl.ConfigEmbeddingReadPathTest do
  @moduledoc """
  US-41.1 regression guard: the read-path DI keys must stay TEST-ONLY, and the
  cutover flag must stay single-writer.

  Two invariants that are otherwise asserted nowhere and fail SILENTLY:

    1. `config :loopctl, :embedding_read_path` changes behaviour by mere PRESENCE — it
       decides which module answers `Loopctl.Embeddings.side_table_reads_enabled?/0`.
       `config/test.exs` points it at `Loopctl.MockEmbeddingReadPath`. The same line in
       `config/config.exs` (or dev/prod/runtime) would swap the PRODUCTION decision module
       for a Mox mock that does not exist outside the test env. Production correctness
       depends entirely on that key being absent everywhere else.

    2. `config :loopctl, :hnsw_iterative_scan` must not exist AT ALL. #488's iterative-scan
       remedy is deliberately a `SystemConfig`-only operator lever (see
       `Loopctl.HeavyRead.hnsw_iterative_scan/0`); an `Application`-level pin would either
       shadow the operator or make the test suite stop exercising the shipped default.

  Both are parsed from the config SOURCE (`config/runtime.exs` in particular is never
  reflected by `Application.get_env/2` during `mix test`), same technique as
  `Loopctl.ConfigPgbouncerSafeParametersTest`.

  Both call SHAPES are recognised — `config :loopctl, :key, value` AND the equally
  idiomatic keyword form `config :loopctl, key: value` (already used elsewhere in
  `config/test.exs`) — and every `config/*.exs` file is enumerated by wildcard, not by a
  hardcoded list, so a key added in a new config file cannot slip past.

  A third guard covers the flag WRITER: the read-flag key names a VM-GLOBAL
  `:persistent_term`-cached `SystemConfig` row, and exactly ONE test module may write it
  (`test/loopctl/embeddings/system_config_read_path_test.exs`, which is `async: false`
  precisely for that reason). A second writer would reintroduce the cross-module leakage
  that produced the flaky empty-result failures — stub `Loopctl.MockEmbeddingReadPath`
  instead. That guard matches on the AST (any `SystemConfig.put/2` whose first argument
  mentions `read_flag_key` or the literal key string), not on a formatted call string, so
  an alias, a pipe, or a reflow does not evade it.

  A fourth guard covers the OTHER side of the same DI seam: a `*_scale_test.exs` module on
  bare `ExUnit.Case` gets no `stub_all_defaults/0`, so a read reaching
  `Loopctl.Embeddings.side_table_reads_enabled?/0` raises `Mox.UnexpectedCallError` — and
  `:scale`/`:scale_nightly` tests are EXCLUDED from `mix precommit`, so it would surface
  only in the nightly job.
  """
  use ExUnit.Case, async: true

  @test_only_keys [:embedding_read_path]
  @forbidden_keys [:hnsw_iterative_scan]

  @flag_writer "test/loopctl/embeddings/system_config_read_path_test.exs"
  @self_path "test/loopctl/config_embedding_read_path_test.exs"

  @read_flag_key Loopctl.Embeddings.SystemConfigReadPath.read_flag_key()

  defp config_files, do: "config/*.exs" |> Path.wildcard() |> Enum.map(&Path.basename/1)
  defp non_test_config_files, do: config_files() -- ["test.exs"]

  describe "Application-level read-path overrides" do
    test ":embedding_read_path is set ONLY in config/test.exs" do
      for file <- non_test_config_files(), key <- @test_only_keys do
        refute config_key_set?(file, key),
               """
               config/#{file} sets `:loopctl, #{inspect(key)}`.

               That key selects the module answering the US-41.1 cutover question and is
               pointed at a Mox mock in config/test.exs. Outside the test env it must be
               ABSENT so `Loopctl.Embeddings.read_path/0` falls back to the production
               `Loopctl.Embeddings.SystemConfigReadPath`.
               """
      end

      assert config_key_set?("test.exs", :embedding_read_path),
             "config/test.exs must keep pointing :embedding_read_path at the Mox mock"
    end

    test "both config call shapes are detected (the guard itself)" do
      assert config_key_set_in_source?(
               "config :loopctl, :embedding_read_path, Some.Mod",
               :embedding_read_path
             ),
             "the 3-arg form must be detected"

      assert config_key_set_in_source?(
               "config :loopctl, embedding_read_path: Some.Mod",
               :embedding_read_path
             ),
             "the KEYWORD form must be detected — it is equally idiomatic and used in config/test.exs"

      refute config_key_set_in_source?("config :loopctl, :other_key, 1", :embedding_read_path)

      refute config_key_set_in_source?(
               "config :other_app, embedding_read_path: 1",
               :embedding_read_path
             )
    end

    test ":hnsw_iterative_scan is not set in ANY config file" do
      for file <- config_files(), key <- @forbidden_keys do
        refute config_key_set?(file, key),
               """
               config/#{file} sets `:loopctl, #{inspect(key)}`.

               #488's iterative-scan mode has exactly one source: the `SystemConfig` key
               "hnsw_iterative_scan" (see `Loopctl.HeavyRead.hnsw_iterative_scan/0`). An
               Application-level pin would shadow the operator lever in prod, and in the
               test env it would stop CI exercising the shipped default — blinding it to
               filtered-ANN under-return regressions.
               """
      end
    end
  end

  describe "the cutover flag has exactly one writer" do
    test "no module other than the SystemConfigReadPath test writes the read flag key" do
      writers =
        "test/**/*.exs"
        |> Path.wildcard()
        # This guard file names the key on purpose; it never writes it.
        |> Enum.reject(&(&1 == @self_path))
        |> Enum.filter(&writes_read_flag?/1)

      assert writers == [@flag_writer],
             """
             The VM-global US-41.1 cutover flag must be written by exactly one module
             (#{@flag_writer}, which is `async: false` for that reason). Found: #{inspect(writers)}.

             If a test needs the side-table read path, stub
             `Loopctl.MockEmbeddingReadPath` per-process — do NOT flip this flag.
             """
    end

    test "the writer guard matches the SEMANTIC shape, not one formatting (the guard itself)" do
      assert writes_read_flag_in_source?("SystemConfig.put(Embeddings.read_flag_key(), 1)")

      assert writes_read_flag_in_source?(
               "Loopctl.SystemConfig.put(Loopctl.Embeddings.read_flag_key(), 1)"
             ),
             "a fully-qualified call must be caught"

      assert writes_read_flag_in_source?(
               ~s|SystemConfig.put(@flag_key, 1)\n@flag_key "#{@read_flag_key}"|
             ),
             "naming the literal key string must be caught"

      refute writes_read_flag_in_source?("SystemConfig.put(\"hnsw_ef_search\", 1)")
      refute writes_read_flag_in_source?("Embeddings.read_flag_key()")
    end
  end

  describe "bare-ExUnit scale modules stub the injected read path" do
    test "every *_scale_test.exs without DataCase/ConnCase calls stub_embedding_read_path/0" do
      missing =
        "test/**/*_scale_test.exs"
        |> Path.wildcard()
        |> Enum.reject(fn file ->
          source = File.read!(file)

          source =~ "use Loopctl.DataCase" or source =~ "use Loopctl.ConnCase" or
            source =~ "stub_embedding_read_path"
        end)

      assert missing == [],
             """
             These scale modules are on bare `ExUnit.Case`, so `stub_all_defaults/0` never
             runs for them, and `config/test.exs` points `:embedding_read_path` at
             `Loopctl.MockEmbeddingReadPath` for the whole test env. Any read reaching
             `Loopctl.Embeddings.side_table_reads_enabled?/0` therefore raises
             `Mox.UnexpectedCallError` — and `:scale` tests are excluded from
             `mix precommit`, so it fails ONLY in the nightly job.

             Add `Loopctl.DataCase.stub_embedding_read_path()` to each module's `setup`:
             #{Enum.join(missing, "\n")}
             """
    end
  end

  defp config_key_set?(file, key) do
    Path.join("config", file) |> File.read!() |> config_key_set_in_source?(key)
  end

  # Matches BOTH `config :loopctl, :key, value` and `config :loopctl, key: value`.
  defp config_key_set_in_source?(source, key) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(false, fn
      {:config, _, [:loopctl, ^key | _]} = node, _acc ->
        {node, true}

      {:config, _, [:loopctl, kw]} = node, acc when is_list(kw) ->
        {node, acc or (Keyword.keyword?(kw) and Keyword.has_key?(kw, key))}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp writes_read_flag?(file), do: file |> File.read!() |> writes_read_flag_in_source?()

  # SEMANTIC match, not a call-string match: the module contains a `*.put/2` call AND
  # mentions the flag (via `read_flag_key` or the literal key string) somewhere — so an
  # alias, a full qualification, a module attribute holding the key, a pipe, or any
  # reformatting is still caught. Deliberately strict: over-matching costs a reviewer one
  # look, under-matching silently reopens the cross-module leak.
  defp writes_read_flag_in_source?(source) do
    ast = Code.string_to_quoted!(source)
    put_call?(ast) and mentions_read_flag?(ast)
  end

  defp put_call?(ast) do
    ast
    |> Macro.prewalk(false, fn
      {{:., _, [_mod, :put]}, _, [_key, _value]} = node, _acc -> {node, true}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  defp mentions_read_flag?(ast) do
    ast
    |> Macro.prewalk(false, fn
      # A LOCAL call `read_flag_key()`; the qualified `Mod.read_flag_key()` form is caught
      # by the bare-atom clause below (prewalk visits the `.`-call's arg list).
      {:read_flag_key, _, _} = node, _acc ->
        {node, true}

      node, acc ->
        {node, acc or node == :read_flag_key or node == @read_flag_key}
    end)
    |> elem(1)
  end
end
