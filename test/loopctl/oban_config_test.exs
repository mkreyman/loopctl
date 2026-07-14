defmodule Loopctl.ObanConfigTest do
  @moduledoc """
  US-32.2: Oban queue widths are env-driven, defaulting to the current hardcoded
  values. Pure module — no DB needed, so this uses plain ExUnit.Case (not DataCase).

  Tests that need a REAL `OBAN_QUEUE_*` env var override run it in a subprocess
  (via `mix run --no-start -e`) rather than `System.put_env/2` in this process.
  `System.put_env/2` mutates BEAM-global OS env for every process, which conflicts
  with `async: true` (a global mutation any other async test could observe) —
  a subprocess's env is scoped to that child process only, so it's async-safe.
  """
  use ExUnit.Case, async: true

  alias Loopctl.ObanConfig

  describe "queues/0" do
    test "TC-32.2.1: defaults preserved when OBAN_QUEUE_* env vars are unset (CI default)" do
      assert ObanConfig.queues() == [
               default: 9,
               webhooks: 5,
               cleanup: 2,
               analytics: 3,
               maintenance: 2,
               embeddings: 5,
               knowledge: 3,
               ingestion: 2,
               memory: 3,
               audit: 3,
               verification: 1
             ]
    end

    @tag :tmp_dir
    test "TC-32.2.4: OBAN_QUEUE_<NAME> env var overrides only the matching queue (subprocess-scoped env)",
         %{tmp_dir: tmp_dir} do
      result =
        run_elixir_script(
          tmp_dir,
          """
          queues = Loopctl.ObanConfig.queues()

          result = %{
            webhooks: Keyword.get(queues, :webhooks),
            default: Keyword.get(queues, :default),
            audit: Keyword.get(queues, :audit)
          }
          """,
          [{"OBAN_QUEUE_WEBHOOKS", "99"}]
        )

      assert result.webhooks == 99
      assert result.default == 9
      assert result.audit == 3
    end
  end

  describe "queue_size/2" do
    test "TC-32.2.2: env override applies" do
      assert ObanConfig.queue_size("20", 5) == 20
      assert ObanConfig.queue_size(nil, 5) == 5
    end

    test "TC-32.2.3: invalid values fail loud instead of returning 0 or the default" do
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("0", 5) end
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("-3", 5) end
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("abc", 5) end
    end

    test "TC-32.2.3: non-integer suffix (e.g. 10s) also fails loud" do
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("10s", 5) end
    end
  end

  describe "release boot safety (Config.Provider.validate_compile_env/1)" do
    @tag :tmp_dir
    test "TC-32.2.5: no compile_env dependency on :loopctl, Oban — an override must never abort release boot",
         %{tmp_dir: tmp_dir} do
      result =
        run_elixir_script(
          tmp_dir,
          """
          app_file = Application.app_dir(:loopctl, "ebin/loopctl.app")
          {:ok, [{:application, :loopctl, props}]} = :file.consult(app_file)
          compile_env = Keyword.get(props, :compile_env, [])

          has_oban_entry? =
            Enum.any?(compile_env, fn {app, path, _} ->
              app == :loopctl and List.starts_with?(path, [Oban])
            end)

          # This is EXACTLY what `Config.Provider.validate_compile_env/1` runs at
          # release boot, fed the real recorded compile_env for this build, with a
          # real OBAN_QUEUE_DEFAULT override active. Before the fix this recorded a
          # dependency on the whole `Oban` key (which runtime.exs reassigns) and
          # `boot_result` would be `{:error, ...}` — aborting the release the instant
          # an operator set any OBAN_QUEUE_* env var. It must be `:ok`.
          boot_result = Config.Provider.validate_compile_env(compile_env)

          result = %{has_oban_compile_env_entry?: has_oban_entry?, boot_result: boot_result}
          """,
          [{"OBAN_QUEUE_DEFAULT", "20"}]
        )

      refute result.has_oban_compile_env_entry?,
             "compile_env must not record a dependency on :loopctl, Oban — that key is " <>
               "reassigned by config/runtime.exs, and recording it would abort release " <>
               "boot the moment an operator sets any OBAN_QUEUE_* env var"

      assert result.boot_result == :ok
    end

    @tag :tmp_dir
    test "TC-32.2.6: regression proof — a compile_env entry covering the whole Oban key would abort boot",
         %{tmp_dir: tmp_dir} do
      result =
        run_elixir_script(
          tmp_dir,
          """
          runtime_oban = Application.fetch_env!(:loopctl, Oban)

          # Reconstruct the pre-fix `@default_queues Application.compile_env(:loopctl, Oban)[:queues]`
          # dependency: it recorded the WHOLE Oban key as it stood at compile time (default
          # queue widths), not just `:queues`.
          legacy_compile_time_value =
            Keyword.put(runtime_oban, :queues,
              default: 10,
              webhooks: 5,
              cleanup: 2,
              analytics: 3,
              maintenance: 2,
              embeddings: 5,
              knowledge: 5,
              memory: 3,
              audit: 3
            )

          legacy_entry = {:loopctl, [Oban], {:ok, legacy_compile_time_value}}
          boot_result = Config.Provider.validate_compile_env([legacy_entry])

          result = %{boot_result: boot_result}
          """,
          [{"OBAN_QUEUE_DEFAULT", "20"}]
        )

      assert {:error, message} = result.boot_result
      assert message =~ "has a different value set"
      assert message =~ "during runtime compared to compile time"
    end
  end

  describe "sth_sweep_cron/0 (US-35.3, runtime-tunable via STH_SWEEP_CRON)" do
    test "TC-35.3.2: defaults to the 5-minute sweep when STH_SWEEP_CRON is unset" do
      # STH_SWEEP_CRON is not set in the test environment, so the default applies.
      assert ObanConfig.sth_sweep_cron() == "*/5 * * * *"
    end

    @tag :tmp_dir
    test "TC-35.3.3: a valid 5-field STH_SWEEP_CRON override is read at runtime and returned",
         %{tmp_dir: tmp_dir} do
      result =
        run_elixir_script(
          tmp_dir,
          "result = Loopctl.ObanConfig.sth_sweep_cron()",
          [{"STH_SWEEP_CRON", "0 * * * *"}]
        )

      assert result == "0 * * * *"
    end

    @tag :tmp_dir
    test "TC-35.3.4: an @nickname STH_SWEEP_CRON override is accepted (Oban parses nicknames)",
         %{tmp_dir: tmp_dir} do
      # Regression: validate_cron/2 previously counted fields and false-rejected the
      # single-field @nickname forms that Oban's own Cron parser accepts.
      result =
        run_elixir_script(
          tmp_dir,
          "result = Loopctl.ObanConfig.sth_sweep_cron()",
          [{"STH_SWEEP_CRON", "@hourly"}]
        )

      assert result == "@hourly"
    end

    @tag :tmp_dir
    test "TC-35.3.7: a STH_SWEEP_CRON padded with trailing whitespace/newline is trimmed to a value Oban accepts",
         %{tmp_dir: tmp_dir} do
      # Regression: validate_cron/2 validated `String.trim(value)` but previously
      # returned the RAW `value`. Oban's Cron plugin re-parses whatever it's handed and
      # REJECTS trailing whitespace/newlines, so a padded STH_SWEEP_CRON (common from
      # $(cat file), piped secrets, YAML quoting, copy-paste) passed boot validation
      # then crashed the Cron plugin fleet-wide with an unattributed "unrecognized cron
      # expression" error. sth_sweep_cron/0 must return the TRIMMED value, and that
      # value must be one Oban's own parser accepts.
      result =
        run_elixir_script(
          tmp_dir,
          """
          returned = Loopctl.ObanConfig.sth_sweep_cron()

          result = %{
            returned: returned,
            oban_accepts?: match?({:ok, _}, Oban.Cron.Expression.parse(returned))
          }
          """,
          [{"STH_SWEEP_CRON", "*/5 * * * *\n"}]
        )

      assert result.returned == "*/5 * * * *"

      assert result.oban_accepts?,
             "the value handed to Oban's Cron plugin must parse cleanly — a trailing " <>
               "newline would crash the plugin at boot"
    end

    @tag :tmp_dir
    test "TC-35.3.5: a malformed 5-field STH_SWEEP_CRON (out-of-range) aborts boot with ArgumentError",
         %{tmp_dir: tmp_dir} do
      # `config/runtime.exs` calls plugins/0 -> sth_sweep_cron/0 while loading config,
      # so a malformed value fails LOUD at boot (non-zero exit) rather than silently
      # falling back to the default — even under `mix run --no-start`.
      {output, exit_code} = run_boot(tmp_dir, [{"STH_SWEEP_CRON", "99 99 99 99 99"}])

      assert exit_code != 0
      assert output =~ "STH_SWEEP_CRON"
      assert output =~ "out of range"
    end

    @tag :tmp_dir
    test "TC-35.3.6: a non-cron STH_SWEEP_CRON string aborts boot with ArgumentError",
         %{tmp_dir: tmp_dir} do
      {output, exit_code} = run_boot(tmp_dir, [{"STH_SWEEP_CRON", "not a cron"}])

      assert exit_code != 0
      assert output =~ "STH_SWEEP_CRON"
    end
  end

  describe "tenant_fair_share_cap/1 + fair_share_config/0 (US-36.2)" do
    test "derives ceil(width/2) floored at 1 from the queue width when unset" do
      assert ObanConfig.tenant_fair_share_cap(:embeddings) == 3
      assert ObanConfig.tenant_fair_share_cap(:knowledge) == 2
      assert ObanConfig.tenant_fair_share_cap(:ingestion) == 1
      assert ObanConfig.tenant_fair_share_cap(:verification) == 1
    end

    test "a malformed cap fails LOUD (raises) rather than silently defaulting" do
      # Called at gate time, but the crash surfaces there rather than fail-open — and
      # fair_share_config/0 (below) forces this same parse at BOOT so it never gets
      # that far in a running node.
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        ObanConfig.queue_size("bogus", 3)
      end
    end

    test "fair_share_config/0 resolves every cap + the snooze base/jitter (CI defaults)" do
      config = ObanConfig.fair_share_config()

      # One cap per configured queue, all >= 1 (the never-wedge invariant).
      assert Keyword.keys(config.caps) == Keyword.keys(ObanConfig.queues())
      assert Enum.all?(config.caps, fn {_q, cap} -> cap >= 1 end)
      assert Keyword.get(config.caps, :embeddings) == 3
      assert config.snooze_base_seconds == 5
      assert config.snooze_jitter_seconds == 5
    end

    @tag :tmp_dir
    test "a malformed OBAN_TENANT_FAIRSHARE_<QUEUE> cap aborts boot (fail-loud, like OBAN_QUEUE_*)",
         %{tmp_dir: tmp_dir} do
      # config/runtime.exs evaluates `ObanConfig.fair_share_config()` at the top level,
      # so a fat-fingered cap fails LOUD at boot (non-zero exit) instead of surviving to
      # gate call-time where the count path fails OPEN and would SILENTLY disable
      # fairness on that queue. This is the US-36.2 medium finding's fix.
      {output, exit_code} = run_boot(tmp_dir, [{"OBAN_TENANT_FAIRSHARE_EMBEDDINGS", "lots"}])

      assert exit_code != 0
      assert output =~ "positive integer"
    end

    @tag :tmp_dir
    test "a malformed OBAN_TENANT_FAIRSHARE_SNOOZE_JITTER aborts boot too",
         %{tmp_dir: tmp_dir} do
      {output, exit_code} = run_boot(tmp_dir, [{"OBAN_TENANT_FAIRSHARE_SNOOZE_JITTER", "-1"}])

      assert exit_code != 0
      assert output =~ "non-negative integer"
    end
  end

  describe "ingest_backlog_max/0 (US-36.3, env-tunable via OBAN_INGEST_BACKLOG_MAX)" do
    test "TC-36.3.3: defaults to 500 when OBAN_INGEST_BACKLOG_MAX is unset" do
      # OBAN_INGEST_BACKLOG_MAX is not set in the test environment, so the default applies.
      assert ObanConfig.ingest_backlog_max() == 500
    end

    @tag :tmp_dir
    test "TC-36.3.3: a valid OBAN_INGEST_BACKLOG_MAX override is read at runtime (subprocess-scoped env)",
         %{tmp_dir: tmp_dir} do
      result =
        run_elixir_script(
          tmp_dir,
          "result = Loopctl.ObanConfig.ingest_backlog_max()",
          [{"OBAN_INGEST_BACKLOG_MAX", "3"}]
        )

      assert result == 3
    end

    @tag :tmp_dir
    test "TC-36.3.3: a malformed OBAN_INGEST_BACKLOG_MAX aborts boot (fail-loud, like OBAN_QUEUE_*)",
         %{tmp_dir: tmp_dir} do
      # config/runtime.exs evaluates `ObanConfig.ingest_backlog_max()` at the top level
      # (via `config :loopctl, :ingest_backlog_max, ...`), so a fat-fingered live-tuning
      # value fails LOUD at boot (non-zero exit) instead of surviving to the batch
      # endpoint's call time, where an unhandled raise would surface as per-request 500s.
      # This drives the REAL env-read path (System.get_env -> ingest_backlog_max/0 ->
      # queue_size/2), not just the shared queue_size/2 delegate.
      {output, exit_code} = run_boot(tmp_dir, [{"OBAN_INGEST_BACKLOG_MAX", "abc"}])

      assert exit_code != 0
      assert output =~ "positive integer"
    end

    test "TC-36.3.3: ingest_backlog_max/0 delegates to queue_size/2, which fails LOUD on a malformed value" do
      # Direct unit-level assertion on the shared parser the env-read path uses.
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("0", 500) end
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("-1", 500) end

      assert_raise ArgumentError, ~r/positive integer/, fn ->
        ObanConfig.queue_size("abc", 500)
      end
    end
  end

  # Runs `script` (must bind a `result` variable) in a fresh `mix run --no-start`
  # subprocess with `env` applied ONLY to that child process, then reads back the
  # term `script` wrote to `result_path` via :erlang.term_to_binary/1. Keeps this
  # async: true test file free of any global (System.put_env/Application.put_env)
  # mutation while still exercising a REAL env-var-driven boot path.
  defp run_elixir_script(tmp_dir, script, env) do
    result_path = Path.join(tmp_dir, "result.bin")

    full_script = """
    #{script}
    File.write!(#{inspect(result_path)}, :erlang.term_to_binary(result))
    """

    {output, exit_code} =
      System.cmd("mix", ["run", "--no-start", "-e", full_script],
        env: [{"MIX_ENV", "test"} | env],
        stderr_to_stdout: true
      )

    assert exit_code == 0, "subprocess script failed (exit #{exit_code}):\n#{output}"

    result_path |> File.read!() |> :erlang.binary_to_term()
  end

  # Boots a fresh `mix run --no-start` subprocess (which still evaluates
  # `config/runtime.exs`, and thus `ObanConfig.plugins/0 -> sth_sweep_cron/0`) with
  # `env` applied ONLY to that child process, and returns `{output, exit_code}` WITHOUT
  # asserting success — for tests that assert a malformed env value aborts boot. Keeps
  # this async: true file free of any global env mutation.
  defp run_boot(tmp_dir, env) do
    result_path = Path.join(tmp_dir, "booted.bin")

    System.cmd(
      "mix",
      ["run", "--no-start", "-e", "File.write!(#{inspect(result_path)}, <<>>)"],
      env: [{"MIX_ENV", "test"} | env],
      stderr_to_stdout: true
    )
  end
end
