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

    2. The Application-level iterative-scan pin must exist in `config/test.exs` and
       NOWHERE else. #488's iterative-scan remedy is a `SystemConfig` operator lever (see
       `Loopctl.HeavyRead.hnsw_iterative_scan/0`); an `Application` pin in a NON-test env
       would shadow that operator lever in prod.

       The live key is **`:hnsw_iterative_scan_default`** — the fallback
       `Loopctl.HeavyRead.default_iterative_scan_code/0` reads when no operator has set the
       `SystemConfig` row. `config/test.exs` pins it ON deliberately, because prod runs
       iterative scan ON and an unpinned test env asserted exact recall against a
       configuration nobody runs.

       `:hnsw_iterative_scan` (no suffix) is the PRE-RENAME spelling and is read by nothing
       today. It stays in the forbidden list so a revert to the old name is caught too —
       and because the rename is exactly how this guard went blind: the key moved, the
       guard did not follow, and for a while the only policed key was a dead one while the
       live pin was unpoliced in every environment.

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

  # `:hnsw_iterative_scan_default` is the key `HeavyRead.default_iterative_scan_code/0`
  # actually reads; `:hnsw_iterative_scan` is its pre-rename spelling, retained so a revert
  # is caught. Both are barred from every NON-test config; `config/test.exs` sets the live
  # one on purpose and the test below asserts that it still does.
  @forbidden_keys [:hnsw_iterative_scan, :hnsw_iterative_scan_default]
  @test_pinned_key :hnsw_iterative_scan_default

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

    test "no iterative-scan Application pin exists in any NON-test config file" do
      for file <- non_test_config_files(), key <- @forbidden_keys do
        refute config_key_set?(file, key),
               """
               config/#{file} sets `:loopctl, #{inspect(key)}`.

               #488's iterative-scan mode has exactly one operator source: the
               `SystemConfig` key "hnsw_iterative_scan" (see
               `Loopctl.HeavyRead.hnsw_iterative_scan/0`). An Application-level pin outside
               the test env would SHADOW that lever in prod, so an operator flipping the
               row would see no effect.
               """
      end
    end

    # The positive half. Without it the guard is one-sided: deleting the test pin would
    # silently return the suite to asserting recall against a configuration prod does not
    # run, which is the state #535 changed and is not visible from the forbidden list.
    test "config/test.exs DOES pin the live iterative-scan key" do
      assert config_key_set?("test.exs", @test_pinned_key),
             """
             config/test.exs no longer sets `:loopctl, #{inspect(@test_pinned_key)}`.

             It is pinned there ON PURPOSE: prod runs iterative scan ON, so an unpinned
             test env asserts exact ANN recall against a configuration nobody runs. If the
             pin was removed deliberately, re-derive the recall expectations in the
             embedding/ANN suites in the same change — do not just delete this assertion.
             """
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

  # These guards classify a module by what it DOES, so every pattern must match a real
  # directive/call — never a bare substring. `source =~ "use Loopctl.DataCase"` is a trap:
  # the standard explanatory comment in these very files reads "this module does not `use
  # Loopctl.DataCase`", so a substring test EXCLUDED every file it was meant to police and
  # the guard silently passed on an empty set. Anchor to line-start code instead.
  @uses_case_template ~r/^\s*use\s+Loopctl\.(DataCase|ConnCase)\b/m
  @calls_stub_all_defaults ~r/^\s*(Loopctl\.DataCase\.)?stub_all_defaults\(\)/m
  @calls_set_mox_global ~r/^\s*(Mox\.)?set_mox_global\(\)/m

  defp bare_exunit_scale_modules do
    "test/**/*_scale_test.exs"
    |> Path.wildcard()
    |> Enum.reject(&(File.read!(&1) =~ @uses_case_template))
  end

  describe "bare-ExUnit scale modules stub the injected collaborators" do
    test "the module classifier matches directives, not prose (the guard itself)" do
      assert "  use Loopctl.DataCase, async: true" =~ @uses_case_template
      assert "  use Loopctl.ConnCase" =~ @uses_case_template

      refute "  # this module does not `use Loopctl.DataCase`, so nothing stubbed it" =~
               @uses_case_template,
             "a COMMENT mentioning the template must not be read as using it — that is the " <>
               "exact substring bug that made this guard vacuous"

      assert "    Loopctl.DataCase.stub_all_defaults()" =~ @calls_stub_all_defaults
      assert "    stub_all_defaults()" =~ @calls_stub_all_defaults

      refute "  # `stub_all_defaults/0` is the single source of truth" =~
               @calls_stub_all_defaults,
             "a COMMENT naming the helper must not count as calling it"

      assert "    Mox.set_mox_global()" =~ @calls_set_mox_global

      refute "  # `set_mox_global` makes the stub visible from any process" =~
               @calls_set_mox_global,
             "a COMMENT naming set_mox_global must not count as calling it"

      refute bare_exunit_scale_modules() == [],
             "the glob/classifier matched NO modules — the guards below would be vacuous"
    end

    test "every *_scale_test.exs without DataCase/ConnCase calls stub_all_defaults/0" do
      missing =
        bare_exunit_scale_modules()
        |> Enum.reject(&(File.read!(&1) =~ @calls_stub_all_defaults))

      assert missing == [],
             """
             These scale modules are on bare `ExUnit.Case`, so `stub_all_defaults/0` never
             runs for them, and `config/test.exs` points EVERY injected collaborator at a
             Mox mock for the whole test env. Any call reaching an unstubbed mock raises
             `Mox.UnexpectedCallError` — and `:scale`/`:scale_nightly` tests are excluded
             from `mix precommit`, so it fails ONLY in the nightly job.

             This guard deliberately requires the FULL `stub_all_defaults/0`, not a
             narrower per-mock stub. Hand-picking one mock at a time is what kept the
             nightly red: a read-path-only stub still left `MockEmbeddingConcurrency`
             unstubbed, and the next unstubbed mock would repeat it. `stub_all_defaults/0`
             is the single source of truth, so a mock added to DataCase is covered here
             automatically.

             Add `Loopctl.DataCase.stub_all_defaults()` to each module:
             #{Enum.join(missing, "\n")}
             """
    end

    test "modules in Mox GLOBAL mode register the stubs in the global-owner process" do
      offenders =
        Enum.filter(bare_exunit_scale_modules(), fn file ->
          source = File.read!(file)

          case Regex.scan(@calls_set_mox_global, source, return: :index) do
            [] ->
              false

            matches ->
              # In global mode Mox lets ONLY the process that called `set_mox_global/0`
              # register stubs. So at least one `stub_all_defaults()` must appear AFTER
              # the last `set_mox_global()` — i.e. in that same (owner) block. A call that
              # only appears BEFORE it is running in some other process (typically a
              # per-test `setup` while the owner is `setup_all`) and raises ArgumentError,
              # failing every test in the module before its body runs.
              [{last_global, _} | _] = List.last(matches)

              stub_positions =
                @calls_stub_all_defaults
                |> Regex.scan(source, return: :index)
                |> Enum.map(fn [{pos, _} | _] -> pos end)

              not Enum.any?(stub_positions, &(&1 > last_global))
          end
        end)

      assert offenders == [],
             """
             These scale modules call `Mox.set_mox_global/0` but never call
             `Loopctl.DataCase.stub_all_defaults()` after it, so the stubs are registered
             from a NON-owner process. Mox raises

                 cannot add expectations/stubs to <Mock> in the current process ...
                 because Mox is in global mode

             which fails every test in the module before its body runs — and only in the
             nightly job, since these are `:scale_nightly`-tagged.

             Move the `stub_all_defaults()` call into the same block as `set_mox_global()`
             (immediately after it), not a per-test `setup`:
             #{Enum.join(offenders, "\n")}
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
