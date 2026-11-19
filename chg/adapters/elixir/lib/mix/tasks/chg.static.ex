defmodule Mix.Tasks.Chg.Static do
  @shortdoc "Static checks on a change (contract command `static`)"
  @moduledoc """
  Runs the static checks for the difference between `--base` and the working tree:

    * first, `mix deps.get` when `mix.lock` is not the one the deps directory was fetched
      for (`ChgAdapter.sync_deps/0`, which every task runs); a failed fetch is the one
      failure reported;
    * `mix format --check-formatted` on the changed Elixir files among `.formatter.exs`'s
      inputs;
    * `mix credo --strict` on the changed Elixir files among `.credo.exs`'s, when credo is
      a dependency, in an env it is declared for;
    * `mix compile --warnings-as-errors` (through `mix chg.compile`), incremental from the
      snapshot's `_build`;
    * dialyzer, when dialyxir is a dependency: `mix chg.dialyzer`, incremental from the
      snapshot's incremental PLT, or `mix dialyzer` against its classic PLT when there is
      no incremental one or incremental mode cannot run.

      mix chg.static --base <sha>

  Prints `{"ok":bool,"failures":[{"check","file"?,"line"?,"message"}]}` and exits 1 when
  any check failed.
  """
  use Mix.Task

  @impl true
  def run(args) do
    ChgAdapter.in_test_env("chg.static", args, fn -> do_run(args) end)
  end

  defp do_run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [base: :string])
    base = opts[:base] || Mix.raise("mix chg.static needs --base <sha>")

    changed =
      case ChgAdapter.changed_paths(base) do
        {:ok, paths} -> Enum.filter(paths, &(elixir_file?(&1) and File.regular?(&1)))
        {:error, why} -> Mix.raise(why)
      end

    failures =
      case ChgAdapter.deps_result() do
        :ok ->
          format(format_inputs(changed)) ++
            credo(credo_inputs(changed)) ++ compile() ++ dialyzer()

        # Every check would fail on the same missing deps: the fetch is the one failure.
        {:error, out} ->
          [%{check: "deps", message: ChgAdapter.tail(out)}]
      end

    ChgAdapter.emit(%{ok: failures == [], failures: failures})
    ChgAdapter.halt(if failures == [], do: 0, else: 1)
  end

  defp elixir_file?(p), do: Path.extname(p) in [".ex", ".exs", ".heex"]

  # The gate runs `mix format --check-formatted` and `mix credo --strict` without paths, so
  # each checks only the files its config names. A path given on the command line is
  # checked whatever the config says, so the changed files are narrowed to those first.
  # A config that cannot be read, or has a shape this does not know, leaves the files
  # checked as given.

  @doc "The `files` (relative to `dir`) that `mix format` with no paths would check."
  def format_inputs(files, dir \\ ".") do
    case formatter_files(dir) do
      {:ok, inputs} -> Enum.filter(files, &MapSet.member?(inputs, Path.expand(&1, dir)))
      _ -> files
    end
  end

  # Like mix format, a subdirectory without its own .formatter.exs adds no files.
  defp formatter_files(dir) do
    case eval(Path.join(dir, ".formatter.exs")) do
      {:ok, opts} when is_list(opts) ->
        own =
          for glob <- List.wrap(opts[:inputs]),
              f <- Path.wildcard(Path.join(dir, glob), match_dot: true),
              do: Path.expand(f)

        opts[:subdirectories]
        |> List.wrap()
        |> Enum.flat_map(&Path.wildcard(Path.join(dir, &1)))
        |> Enum.reduce_while({:ok, MapSet.new(own)}, fn sub, {:ok, acc} ->
          case formatter_files(sub) do
            {:ok, more} -> {:cont, {:ok, MapSet.union(acc, more)}}
            :missing -> {:cont, {:ok, acc}}
            :error -> {:halt, :error}
          end
        end)

      {:ok, _} ->
        :error

      other ->
        other
    end
  end

  @credo_default %{
    included: [
      "lib/",
      "src/",
      "test/",
      "web/",
      "apps/*/lib/",
      "apps/*/src/",
      "apps/*/test/",
      "apps/*/web/"
    ],
    excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
  }

  @doc "The `files` (relative to `dir`) that `mix credo` with no paths would check."
  def credo_inputs(files, dir \\ ".") do
    with {:ok, %{included: inc, excluded: exc}} <- credo_files(dir),
         {:ok, inc} <- expand_entries(inc, dir),
         {:ok, exc} <- expand_entries(exc, dir) do
      Enum.filter(files, fn f ->
        Enum.any?(inc, &credo_match?(f, &1, dir)) and
          not Enum.any?(exc, &credo_match?(f, &1, dir))
      end)
    else
      _ -> files
    end
  end

  # Credo reads .credo.exs or config/.credo.exs and uses the config named "default", or its
  # built-in one when there is none. Both files present means merged settings, which this
  # does not reproduce, so the files are checked as given.
  defp credo_files(dir) do
    found =
      for name <- [".credo.exs", "config/.credo.exs"],
          (r = eval(Path.join(dir, name))) != :missing,
          do: r

    case found do
      [] ->
        {:ok, @credo_default}

      [{:ok, %{configs: configs}}] when is_list(configs) ->
        files =
          case Enum.find(configs, &(is_map(&1) and &1[:name] == "default")) do
            %{files: %{} = f} -> f
            _ -> %{}
          end

        {:ok, Map.merge(@credo_default, Map.take(files, [:included, :excluded]))}

      _ ->
        :error
    end
  end

  # Each entry as a Regex, or as the expanded paths it names: itself, or a glob's matches.
  defp expand_entries(entries, dir) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      %Regex{} = r, {:ok, acc} ->
        {:cont, {:ok, [r | acc]}}

      e, {:ok, acc} when is_binary(e) ->
        paths =
          if String.contains?(e, ["*", "?", "[", "{"]),
            do: Enum.map(Path.wildcard(Path.join(dir, e)), &Path.expand/1),
            else: [Path.expand(e, dir)]

        {:cont, {:ok, [{:paths, paths} | acc]}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp expand_entries(_, _), do: :error

  # A regex is matched against the path as credo sees it, relative to the project.
  defp credo_match?(f, %Regex{} = r, _dir), do: Regex.match?(r, f)

  defp credo_match?(f, {:paths, paths}, dir),
    do: Enum.any?(paths, &under?(Path.expand(f, dir), &1))

  defp under?(f, path),
    do: f == path or String.starts_with?(f, String.trim_trailing(path, "/") <> "/")

  defp eval(path) do
    if File.regular?(path), do: {:ok, path |> Code.eval_file() |> elem(0)}, else: :missing
  rescue
    e ->
      IO.puts(:standard_error, "chg: #{path} not read: #{Exception.message(e)}")
      :error
  end

  @doc false
  def format([]), do: []

  def format(files) do
    {out, status} = ChgAdapter.capture("mix", ["format", "--check-formatted" | files])

    case {status, unformatted(out, files)} do
      {0, _} -> []
      {_, []} -> [%{check: "format", message: ChgAdapter.tail(out)}]
      {_, files} -> Enum.map(files, &%{check: "format", file: &1, message: "not formatted"})
    end
  end

  @doc """
  Which of `files` mix format reported. Elixir 1.19 and 1.20 print each as an absolute path in
  ANSI colour above its diff, so a line is matched by its suffix once colour is stripped.
  """
  def unformatted(out, files) do
    lines =
      out
      |> String.replace(~r/\e\[[0-9;]*m/, "")
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("* ")))

    Enum.filter(files, fn f -> Enum.any?(lines, &(&1 == f or String.ends_with?(&1, "/" <> f))) end)
  end

  defp credo(files) do
    files = Enum.filter(files, &(Path.extname(&1) in [".ex", ".exs"]))

    env = ChgAdapter.dep_env(:credo)

    if files == [] or env == nil do
      []
    else
      {out, status} =
        ChgAdapter.capture("mix", ["credo", "--strict", "--format", "json" | files],
          merge: false,
          env: [{"MIX_ENV", env}]
        )

      credo_failures(out, status)
    end
  end

  @doc false
  def credo_failures(_out, 0), do: []

  def credo_failures(out, _status) do
    with [_, json] <- Regex.run(~r/^(\{.*)\z/ms, out, capture: :all),
         {:ok, %{"issues" => issues}} <- JSON.decode(json) do
      Enum.map(issues, fn i ->
        %{
          check: "credo",
          file: i["filename"],
          line: i["line_no"],
          message: "#{i["check"]}: #{i["message"]}"
        }
      end)
    else
      _ -> [%{check: "credo", message: ChgAdapter.tail(out)}]
    end
  end

  defp compile do
    {out, status} = ChgAdapter.capture("mix", ["chg.compile", "--warnings-as-errors"])
    if status == 0, do: [], else: compile_failures(out)
  end

  @doc """
  Diagnostics from `mix compile` output: each `warning:`/`error:` line paired with the
  `└─ file:line` location Elixir prints under it.
  """
  def compile_failures(out) do
    {found, _} =
      out
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {acc, msg} ->
        diagnostic = Regex.run(~r/^\s*(?:warning|error): (.*)$/, line)
        location = msg && Regex.run(~r/└─ ([^:\s]+):(\d+)/, line)

        case {diagnostic, location} do
          {[_, text], _} ->
            {acc, text}

          {_, [_, file, n]} ->
            {[%{check: "compile", file: file, line: String.to_integer(n), message: msg} | acc],
             nil}

          _ ->
            {acc, msg}
        end
      end)

    case Enum.reverse(found) do
      [] -> [%{check: "compile", message: ChgAdapter.tail(out)}]
      found -> found
    end
  end

  # In the env the snapshot built the PLTs in (`ChgAdapter.dep_env/1`): incremental from
  # the snapshot's incremental PLT when there is one (`mix chg.dialyzer`), else, or when
  # incremental mode cannot run here (its exit 3), `mix dialyzer` against the classic PLT.
  defp dialyzer do
    case ChgAdapter.dep_env(:dialyxir) do
      nil ->
        []

      env ->
        {out, status} = dialyzer_run(env, File.regular?(Mix.Tasks.Chg.Dialyzer.iplt(env)))
        if status == 0, do: [], else: dialyzer_failures(out)
    end
  end

  defp dialyzer_run(env, true) do
    case ChgAdapter.capture("mix", ["chg.dialyzer"], env: [{"MIX_ENV", env}]) do
      {_out, 3} -> dialyzer_run(env, false)
      result -> result
    end
  end

  defp dialyzer_run(env, false),
    do: ChgAdapter.capture("mix", ["dialyzer", "--format", "short"], env: [{"MIX_ENV", env}])

  @doc "Warnings from `mix dialyzer --format short`: `file:line[:col]:kind message`."
  def dialyzer_failures(out) do
    found =
      for line <- String.split(out, "\n"),
          [_, file, n, msg] <- [Regex.run(~r/^(\S+\.exs?):(\d+)(?::\d+)?:(\S.*)$/, line)],
          do: %{check: "dialyzer", file: file, line: String.to_integer(n), message: msg}

    if found == [], do: [%{check: "dialyzer", message: ChgAdapter.tail(out)}], else: found
  end
end
