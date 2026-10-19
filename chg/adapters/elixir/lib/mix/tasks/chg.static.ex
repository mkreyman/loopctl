defmodule Mix.Tasks.Chg.Static do
  @shortdoc "Static checks on a change (contract command `static`)"
  @moduledoc """
  Runs the static checks for the difference between `--base` and the working tree:

    * first, `mix deps.get` when `mix.lock` is not the one the deps directory was fetched
      for (`ChgAdapter.sync_deps/0`, which every task runs); a failed fetch is the one
      failure reported;
    * `mix format --check-formatted` on the changed Elixir files;
    * `mix credo --strict` on the changed Elixir files, when credo is a dependency, in an
      env it is declared for;
    * `mix compile --warnings-as-errors`, incremental from the snapshot's `_build`;
    * `mix dialyzer` against the snapshot's PLT, when dialyxir is a dependency.

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
        :ok -> format(changed) ++ credo(changed) ++ compile() ++ dialyzer()
        # Every check would fail on the same missing deps: the fetch is the one failure.
        {:error, out} -> [%{check: "deps", message: ChgAdapter.tail(out)}]
      end

    ChgAdapter.emit(%{ok: failures == [], failures: failures})
    ChgAdapter.halt(if failures == [], do: 0, else: 1)
  end

  defp elixir_file?(p), do: Path.extname(p) in [".ex", ".exs", ".heex"]

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
    {out, status} = ChgAdapter.capture("mix", ["compile", "--warnings-as-errors"])
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

  # In the env the snapshot built the PLT in (`ChgAdapter.dep_env/1`).
  defp dialyzer do
    case ChgAdapter.dep_env(:dialyxir) do
      nil ->
        []

      env ->
        {out, status} =
          ChgAdapter.capture("mix", ["dialyzer", "--format", "short"], env: [{"MIX_ENV", env}])

        if status == 0, do: [], else: dialyzer_failures(out)
    end
  end

  @doc "Warnings from `mix dialyzer --format short`: `file:line[:col]:kind message`."
  def dialyzer_failures(out) do
    found =
      for line <- String.split(out, "\n"),
          [_, file, n, msg] <- [Regex.run(~r/^(\S+\.exs?):(\d+)(?::\d+)?:(\S.*)$/, line)],
          do: %{check: "dialyzer", file: file, line: String.to_integer(n), message: msg}

    if found == [], do: [%{check: "dialyzer", message: ChgAdapter.tail(out)}], else: found
  end
end
