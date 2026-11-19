defmodule Mix.Tasks.Chg.Snapshot do
  @shortdoc "Builds the artifacts of a chg snapshot (contract command `snapshot`)"
  @moduledoc """
  Brings `deps`, `_build/{dev,test}`, the dialyzer PLTs (dialyxir's classic one and the
  incremental one `mix chg.dialyzer` checks against) and the test reference cache up to
  date with the commit the tree holds, incrementally from whatever is already there. chg
  names that commit in `CHG_SHA`, since a snapshot tree has no `.git`; run by hand in a
  checkout, it is git's HEAD (`ChgAdapter.head!/0`).

      mix chg.snapshot

  Idempotent: when that commit, `mix.lock`, the toolchain and the tree's absolute path
  match the marker the last successful run wrote, it does nothing and reports
  `{"work":"none"}`. The marker is written last, so an interrupted run is redone, never
  trusted. The path is in it because a build can bake in absolute paths: `check_cwd: false`
  turns off only Mix's cwd check, and a module whose `__mix_recompile__?` hashes absolute
  paths (Phoenix's `embed_templates`) or config that expands them still recompiles at
  another path. A tree cloned there must therefore build again, though its commit is the
  same.

  Prints `{"work":"none"|"incremental"|"full","ms":N}`.

  Refuses a project that compiles with the cwd check on: a workspace cloned from the
  snapshot sits at another path, and Mix would recompile every module there.
  """
  use Mix.Task

  alias ChgAdapter.Refs

  @impl true
  def run(_args) do
    started = System.monotonic_time()

    unless honours_check_cwd?(System.version()) do
      Mix.raise(
        "Elixir #{System.version()} ignores `check_cwd: false` (it exists since 1.19.2), so a " <>
          "workspace cloned from this snapshot would recompile every module"
      )
    end

    for env <- [:dev, :test], not check_cwd_off?(project_config(Mix.Project.get!(), env)) do
      Mix.raise(
        "add `elixirc_options: [check_cwd: false]` to project/0 in mix.exs (MIX_ENV=#{env} " <>
          "has the cwd check on): a workspace cloned from this snapshot has another path, " <>
          "and with the check on Mix recompiles every module there"
      )
    end

    key = key()
    marker = Path.join(ChgAdapter.state_dir(), "snapshot")

    work =
      case File.read(marker) do
        {:ok, ^key} -> if match?({:ok, _}, Refs.read()), do: "none", else: "incremental"
        {:ok, _} -> "incremental"
        {:error, _} -> "full"
      end

    if work != "none" do
      build!()
      ChgAdapter.write_atomic!(marker, key)
    end

    # A snapshot built before deps/.chg_lock existed: its key covers mix.lock, so the deps
    # it holds are the lock's.
    if work == "none" and not File.exists?(ChgAdapter.lock_marker()), do: ChgAdapter.record_lock()

    ChgAdapter.emit(%{work: work, ms: ChgAdapter.ms_since(started)})
  end

  @doc """
  True when `config` compiles without the cwd check: `elixirc_options: [check_cwd: false]`,
  or a `compile` alias passing `--no-check-cwd`.
  """
  def check_cwd_off?(config) do
    Keyword.get(config[:elixirc_options] || [], :check_cwd, true) == false or
      config
      |> Keyword.get(:aliases, [])
      |> Keyword.get(:compile, [])
      |> List.wrap()
      |> Enum.any?(&(is_binary(&1) and &1 =~ "--no-check-cwd"))
  end

  @doc """
  `project/0` of the mix.exs module `project` as it evaluates under `env`: the snapshot
  compiles dev and test, and a mix.exs may choose its elixirc_options per env.
  """
  def project_config(project, env) do
    previous = Mix.env()
    Mix.env(env)

    try do
      project.project()
    after
      Mix.env(previous)
    end
  end

  defp key do
    Enum.join(
      [
        ChgAdapter.head!(),
        File.cwd!(),
        ChgAdapter.lock_digest(),
        System.version(),
        System.otp_release()
      ],
      "\n"
    )
  end

  defp build! do
    step!("mix", ["deps.get"], [])
    ChgAdapter.record_lock()

    for env <- ["dev", "test"] do
      step!("mix", ["chg.compile"], [{"MIX_ENV", env}])
    end

    if env = ChgAdapter.dep_env(:dialyxir) do
      step!("mix", ["dialyzer", "--plt"], [{"MIX_ENV", env}])
      incremental_plt(env)
    end

    step!("mix", ["chg.refs"], [{"MIX_ENV", "test"}])
  end

  # The incremental PLT `mix chg.static` checks against. Never fatal: without it a check
  # runs `mix dialyzer` against the classic PLT built above, so a failed build removes the
  # file rather than leave one that no longer matches the tree.
  defp incremental_plt(env) do
    IO.puts(:standard_error, "chg: MIX_ENV=#{env} mix chg.dialyzer --build")

    case ChgAdapter.stream("mix", ["chg.dialyzer", "--build"], [{"MIX_ENV", env}]) do
      0 ->
        :ok

      status ->
        File.rm(Mix.Tasks.Chg.Dialyzer.iplt(env))

        IO.puts(
          :standard_error,
          "chg: mix chg.dialyzer --build exited #{status}; checks run mix dialyzer instead"
        )
    end
  end

  defp step!(cmd, args, env) do
    line = Enum.map(env, fn {k, v} -> "#{k}=#{v}" end) ++ [cmd | args]
    IO.puts(:standard_error, "chg: " <> Enum.join(line, " "))

    case ChgAdapter.stream(cmd, args, env) do
      0 -> :ok
      status -> Mix.raise("#{cmd} #{Enum.join(args, " ")} exited #{status}")
    end
  end

  @doc "Whether Elixir `version` honours `elixirc_options: [check_cwd: false]`."
  def honours_check_cwd?(version), do: Version.match?(version, ">= 1.19.2")
end
