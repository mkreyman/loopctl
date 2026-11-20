defmodule Mix.Tasks.Chg.Dialyzer do
  @shortdoc "Dialyzer in incremental mode, judged the way `mix dialyzer` judges"
  @moduledoc """
  Runs dialyzer in OTP's incremental mode against an incremental PLT the snapshot keeps
  warm, and judges the warnings exactly as `mix dialyzer --format short` does: the same
  files, the same warning flags, the project's ignore file applied by dialyxir itself.
  A check then re-analyses only the modules whose beams changed since the snapshot, where
  `mix dialyzer` re-analyses every project module (mkreyman/chg#47: 7 s against 69-143 s
  on a large app with nothing changed, 99 s against 69 s after a hub-module change).

      mix chg.dialyzer           # a check, from `mix chg.static`
      mix chg.dialyzer --build   # the snapshot: create or update the incremental PLT

  The incremental PLT holds what dialyxir's PLTs hold (Erlang's and Elixir's core
  applications, and the dependency applications dialyxir puts in the project PLT) plus
  the project's own beams, which are also the only files warnings are reported for. It
  lives at `_build/chg/dialyzer-<env>.iplt`, so a workspace cloned from the
  snapshot updates its own copy and never the snapshot's.

  Exit status: 0 no warnings; 2 warnings, each printed as `file:line:kind message`; 1 the
  ignore file has unused filters and dialyxir is told to fail on them; 3 incremental mode
  cannot run here (a check with no incremental PLT, an OTP before 26, a dialyxir without
  the functions this uses, a dialyzer error), and `mix chg.static` runs `mix dialyzer`
  instead. A check never builds a PLT: building one takes minutes (12 on a 1,800-module
  app), and the snapshot refresh is where nobody waits for it.
  """
  use Mix.Task

  @unavailable 3
  # The applications dialyxir's core PLTs hold (Dialyxir.Project.plts_list/3).
  @core_apps [:elixir, :erts, :kernel, :stdlib, :crypto]
  # Mix.Tasks.Dialyzer's @default_warnings.
  @default_warnings [:unknown]
  # Called through a variable: dialyxir is the project's dependency, not this archive's.
  @dialyxir_task Mix.Tasks.Dialyzer
  @dialyxir_project Dialyxir.Project
  @dialyxir_formatter Dialyxir.Formatter
  @dialyxir_short Dialyxir.Formatter.Short
  @needed [
    {Mix.Tasks.Dialyzer, :dependency_hash, 0},
    {Dialyxir.Project, :dialyzer_files, 0},
    {Dialyxir.Project, :dialyzer_flags, 0},
    {Dialyxir.Project, :dialyzer_removed_defaults, 0},
    {Dialyxir.Formatter, :format_and_filter, 5}
  ]

  @doc "The incremental PLT of `env`, relative to the project."
  def iplt(env), do: Path.join(ChgAdapter.state_dir(), "dialyzer-#{env}.iplt")

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [build: :boolean])
    build? = opts[:build] || false

    # Compiling prunes the code path to the project's, which drops this archive's ebin.
    ChgAdapter.preload!()
    Mix.Task.run("compile")
    plt = Path.expand(iplt(Mix.env()))

    case unavailable(build?, plt) do
      nil ->
        ChgAdapter.halt(analyse(plt, build?))

      why ->
        IO.puts(:standard_error, "chg: incremental dialyzer cannot run: #{why}")
        ChgAdapter.halt(@unavailable)
    end
  end

  @doc false
  # Why incremental mode cannot run, or nil when it can.
  def unavailable(build?, plt, otp \\ otp_release(), loaded? \\ &needed?/1) do
    cond do
      otp < 26 -> "OTP #{otp} has no incremental mode (it came in OTP 26)"
      not build? and not File.regular?(plt) -> "no incremental PLT at #{plt}"
      missing = Enum.find(@needed, &(not loaded?.(&1))) -> "dialyxir has no #{inspect(missing)}"
      true -> nil
    end
  end

  defp otp_release, do: :erlang.system_info(:otp_release) |> List.to_integer()

  defp needed?({mod, fun, arity}),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)

  defp analyse(plt, build?) do
    {apps, _hash} = apply(@dialyxir_task, :dependency_hash, [])
    project = apply(@dialyxir_project, :dialyzer_files, [])
    File.mkdir_p!(Path.dirname(plt))

    args = [
      analysis_type: :incremental,
      init_plt: String.to_charlist(plt),
      files_rec: plt_dirs(apps ++ @core_apps, &:code.lib_dir/1, Mix.Project.compile_path()),
      files: project,
      warning_files: project,
      warnings:
        warnings(
          apply(@dialyxir_project, :dialyzer_flags, []),
          apply(@dialyxir_project, :dialyzer_removed_defaults, [])
        )
    ]

    started = System.monotonic_time()

    case dialyze(args) do
      {:error, why} ->
        IO.puts(:standard_error, "chg: incremental dialyzer cannot run: #{why}")
        @unavailable

      # The snapshot only wants the PLT; the warnings are the checks' business.
      {:ok, _warnings} when build? ->
        IO.puts(
          :standard_error,
          "chg: incremental PLT ready in #{ChgAdapter.ms_since(started)} ms"
        )

        0

      {:ok, warnings} ->
        judged = judge(warnings)

        IO.puts(
          :standard_error,
          "chg: incremental dialyzer took #{ChgAdapter.ms_since(started)} ms"
        )

        report(judged)
    end
  end

  defp dialyze(args) do
    # Through apply: dialyzer is an OTP application this archive does not declare.
    {:ok, apply(:dialyzer, :run, [args])}
  catch
    # dialyzer:run/1 turns its own {dialyzer_error, Msg} throw into an error (OTP 28,
    # dialyzer.erl); the throw is kept for a release that lets it through.
    kind, {:dialyzer_error, msg} when kind in [:error, :throw] -> {:error, to_string(msg)}
  end

  defp judge(warnings) do
    apply(@dialyxir_formatter, :format_and_filter, [
      warnings,
      @dialyxir_project,
      [],
      [@dialyxir_short],
      false
    ])
  end

  @doc false
  # Prints what `mix dialyzer --format short` prints for a judged result and returns its
  # exit status (Dialyxir.Dialyzer.dialyze/3): unused filters fail only when the ignore
  # file is told to, and fail the run even without a warning.
  def report({:error, formatted, {:unused_filters_present, skips}}) do
    Enum.each(formatted, &IO.puts/1)
    IO.puts(skips)
    IO.puts("unused filters present")
    1
  end

  def report({_ok_or_warn, [], _skips}), do: 0

  def report({_ok_or_warn, formatted, _skips}) do
    Enum.each(formatted, &IO.puts/1)
    2
  end

  @doc false
  # The ebin directory of each application `lib_dir` knows, the project's own left out
  # (its beams are `files`, and a module given twice is an error). An application dialyxir
  # names but this VM cannot find is skipped, as dialyxir skips it.
  def plt_dirs(apps, lib_dir, compile_path) do
    own = Path.expand(compile_path)

    apps
    |> Enum.uniq()
    |> Enum.flat_map(fn app ->
      case lib_dir.(app) do
        dir when is_list(dir) or is_binary(dir) -> [Path.join(to_string(dir), "ebin")]
        _ -> []
      end
    end)
    |> Enum.reject(&(Path.expand(&1) == own))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&String.to_charlist/1)
  end

  @doc false
  # Mix.Tasks.Dialyzer's dialyzer_warnings/1 with no command-line flags.
  def warnings(flags, removed) do
    Enum.map(flags, &flag/1) ++ (@default_warnings -- removed)
  end

  defp flag(f) when is_atom(f), do: f

  defp flag(f) when is_binary(f),
    do: f |> String.replace_leading("-W", "") |> String.replace("--", "") |> String.to_atom()
end
